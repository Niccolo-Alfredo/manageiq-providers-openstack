# Contesto patch: Keystone Token Cache

## Obiettivo

Ridurre le autenticazioni Keystone nel provider OpenStack di ManageIQ.
File principale: `lib/manageiq/providers/openstack/legacy/openstack_handle/handle.rb`

## Branch

`feature/auth-cache` — commit su questo branch (dal più vecchio al più recente):

| Hash | Messaggio |
|---|---|
| `1fa63334` | fix: add keystone auth cache |
| `b72caaa4` | Fix: adjust auth error derived by auth cache patch |
| `4f88ad59` | fix: add missing private methods and remove duplicate build_tenant_token |
| `d4c0802e` | fix: correct Concurrent::Map iteration and auth retry scope |
| `b81bfc6b` | fix: pass project context to fog service in cached connect path |
| `dc5a2257` | fix: pass current_tenant from cached token to fog service opts |
| `755810dd` | fix: guard nil tenant_id in quota delegates and raise ServiceNotAvailable for missing catalog endpoints |
| `df85b773` | fix: normalize cached tenant hash keys to strings |
| `7b9ca054` | fix: accept both string and symbol keys in quota delegate tenant lookup |
| `42b71919` | fix: demote missing-endpoint catalog log from warn to debug |
| `06dbfb92` | fix: invalidate cached token on 401 from API calls in accessor_for_accessible_tenants |

**Stato attuale (2026-05-25)**: patch stabile e verificata su tutti e tre i nodi del cluster. Full refresh completo senza errori bloccanti. Quote compute/network/volume raccolte correttamente. Log operativi puliti. Aggiunto fix per token revocati esternamente: 401 da API call ora invalida la cache e forza re-auth al refresh successivo.

---

## Flusso originale (pre-patch)

```
connect(options)
  └─ @connection_cache[service][tenant] ||= begin
       raw_connect_try_ssl(username, password, address, port, service, opts, security_protocol)
         └─ try_connection(security_protocol) → schema + ssl_verify_peer
              └─ raw_connect(username, password, auth_url, service, opts)
                   └─ Fog::OpenStack::<Service>.new(opts)
                        └─ POST /v3/auth/tokens  ← 1 chiamata per ogni (service, tenant)
     end
```

Caratteristiche del path originale:
- Cache `@connection_cache` è un instance variable sull'oggetto EMS
- Viene azzerata ad ogni refresh task (nuovo oggetto EMS dal DB ad ogni task)
- Ogni `connect("Compute", "tenant_alpha")` e `connect("Network", "tenant_alpha")` → 2 POST Keystone
- Con 20 tenant × 5 servizi → **100 POST per full refresh**
- Eccezioni di rete (Excon::Errors::SocketError, Timeout) → `translate_exception` → `MiqHostError`/`MiqUnreachableError` (errori transienti, ManageIQ può fare retry)

---

## Flusso con la patch

```
connect(options)
  │
  ├─ token_cache_enabled? → false → connect_without_cache(options)  [rollback path]
  │
  └─ token_cache_enabled? → true  [default]
       │
       ├─ default_tenant_name  (se tenant non specificato)
       │    └─ detect_default_tenant_name → tenant_accessible?("admin") → connect("Compute","admin")
       │         [ricorsione: rientra in connect() con tenant esplicito]
       │
       └─ with_auth_retry(tenant, opts)
            │  ← fetch_or_build_tenant_token(tenant, opts) chiamato qui, fuori dal rescue
            │    └─ TENANT_TOKEN_CACHE.compute(key) do |existing|
            │         se existing && tenant_token_valid?(existing)
            │           → ritorna existing  [CACHE HIT: zero network]
            │         altrimenti
            │           → build_tenant_token(tenant, opts)
            │                └─ keystone_auth_opts(tenant)  [username, password, project, domain]
            │                └─ try_connection(security_protocol, ssl_options)
            │                     → ssl_conn_opts con ssl_verify_peer: false per ssl-no-validation
            │                └─ Fog::OpenStack::Auth::Token.build(auth_opts, conn_opts)
            │                     └─ POST /v3/auth/tokens  ← unica chiamata per tenant
            │                     → CachedToken { token_str, catalog, expires_at, tenant }
            │       end
            │  ← 401 da build_tenant_token: propaga direttamente (NO retry)
            │
            do |cached|
              management_url = endpoint_url_from_catalog(cached.catalog, service, opts)
                └─ fog_service_type(service) → ["compute"], ["network"], ecc.
                └─ catalog.get_endpoint_url([type], 'public', region)  [in memoria, zero network]
                └─ itera service types uno alla volta (evita EndpointError "Multiple endpoints")

              fog_opts = base_fog_opts(opts).merge(
                openstack_auth_token:     cached.token_str,
                openstack_management_url: management_url,
                current_tenant:           cached.tenant   ← Hash {'id','name'} da Keystone v3
              )
              + openstack_project_name / openstack_tenant (v2/v3)
              + openstack_project_domain_id / openstack_user_domain_id

              raw_connect_with_token(service, fog_opts, security_protocol)
                └─ try_connection → aggiunge ssl_verify_peer agli opts
                └─ raw_connect_direct(service, opts)
                     └─ Fog::OpenStack::<Service>.new(opts)
                          [fog vede openstack_auth_token → salta POST /v3/auth/tokens]
                          [fog legge :current_tenant dalle opts → compute_delegate.quotas_for_current_tenant ok]
            end
            │
            └─ 401 da raw_connect_with_token (token revocato mid-use):
                 invalida cache → re-fetch token → retry una volta
       │
       └─ wrap_in_service_delegate(raw_service, service)
            → <Service>Delegate.new(raw_service, self, SERVICE_NAME_MAP[service])
```

Caratteristiche del path con patch:
- Cache `TENANT_TOKEN_CACHE` è una costante di classe (`Concurrent::Map`), vive per tutta la durata del processo worker
- Sopravvive ai reload dell'oggetto EMS dal DB tra refresh task successivi
- Ogni tenant autentica **1 volta ogni ~55 minuti** (TOKEN_EXPIRY_MARGIN = 60s prima della scadenza reale)
- Con 20 tenant → **20 POST al primo refresh**, poi **0 POST** fino a scadenza
- `Concurrent::Map#compute` è atomico per chiave: nessun thundering-herd se più thread mancano lo stesso tenant
- Eccezioni di rete in `build_tenant_token` → log + re-raise → stessa tipologia di `translate_exception` del path legacy (Excon errors → `MiqHostError`/`MiqUnreachableError`)
- 401 da Keystone durante autenticazione iniziale → propaga a `detect_service` → tenant skippato silenziosamente (comportamento legacy)
- 401 da API fog con token già in uso → `with_auth_retry` invalida e riautentica una volta

---

## Struttura della cache

```
Chiave : "username@address:port||tenant_name"
          es: "miqstagmilano@10.94.0.100:5000||SA-ZUZAJTYPAW"

Valore : CachedToken {
           token_str:  "gAAAAA..."              # x-subject-token da Keystone
           catalog:    Catalog::V3              # service catalog completo (in memoria)
           expires_at: 2026-05-23 22:42:00 UTC
           tenant:     {'id'=>'...','name'=>'SA-ZUZAJTYPAW','domain'=>{...}}  # token.tenant da Keystone v3
         }
```

---

## Bug risolti nel primo full refresh reale (2026-05-24)

| Bug | Causa | Fix | Commit |
|---|---|---|---|
| `delete_if` su `Concurrent::Map` | `Concurrent::Map` non implementa `delete_if` (è di Hash) | `each_pair` + raccolta chiavi + `delete` | `d4c0802e` |
| Retry su 401 da `build_tenant_token` | `with_auth_retry` catturava anche 401 Keystone dell'auth iniziale, causando retry inutile + crash | Spostato `fetch_or_build_tenant_token` fuori dal `rescue` scope in `with_auth_retry` | `d4c0802e` |
| `NoMethodError: undefined method 'id' for nil` in `compute_delegate.rb:22` | Fog non setta `@current_tenant` quando salta il POST (path cached). Legge `options[:current_tenant]`, non `openstack_project_name`. `detect` ritornava nil. | Aggiunto campo `tenant` in `CachedToken` (il Hash v3 da Keystone), passato come `:current_tenant` in fog_opts | `dc5a2257` |
| 404 su `quotas_for_current_tenant` (Compute e Volume) | Con `@tenant_id = nil`, `get_quota(nil)` produceva path `/os-quota-sets/` (nil interpolato come `""`) → 404. Nel branch `else`: `.id` su nil da `detect` → NoMethodError. | `&.id` safe navigation + `return nil unless @tenant_id` (pattern già in `network_delegate`) | `755810dd` |
| `EOFError` su servizi non in catalog (es. NFV) | `endpoint_url_from_catalog` ritornava nil → `management_url: nil` → fog tentava connessione → EOFError | `raise MiqException::ServiceNotAvailable unless management_url` in `connect()` — stesso comportamento del path legacy | `755810dd` |
| **Quote compute/network/volume non raccolte** (regressione) | `Fog::JSON.decode` sul sistema deployato symbolizza i nomi JSON → `token.tenant` ha chiavi simbolo (`:id`, `:name`). I delegate leggono `current_tenant['id']` con chiave stringa → nil → `@tenant_id` nil → `return nil unless @tenant_id` → quota saltata silenziosamente. Il path originale funzionava per accident (`get_quota(nil)` → Nova/Cinder rispondevano con quota del progetto dal token scope). | `token.tenant&.transform_keys(&:to_s)` in `build_tenant_token` normalizza le chiavi prima del caching | `df85b773` |
| **Quote ancora nil dopo df85b773** (stale cache) | Il fix `transform_keys` si applica solo ai token nuovi. I worker in esecuzione avevano in cache entry con chiavi simbolo valide per ~55 min e le restituivano as-is senza passare per `build_tenant_token`. Riavviare il processo avrebbe svuotato la cache ma era indesiderato. | `current_tenant['id'] \|\| current_tenant[:id]` nei tre delegate: robusto a entrambi i tipi senza richiedere restart | `7b9ca054` |
| **WARN NFV/Storage ad ogni refresh** | `endpoint_url_from_catalog` loggava WARN per servizi non presenti nel catalog (NFV/Tacker, Swift non deployati). Log rumorosi per operatori. | `$fog_log.warn` → `$fog_log.debug` in `endpoint_url_from_catalog` | `42b71919` |
| **Token revocato esternamente non invalidava la cache** | Quando un token veniva revocato su Keystone prima della scadenza naturale, la 401 arrivava durante le API call successive (`svc.servers.to_a`), non durante `raw_connect_with_token`. `with_auth_retry` cattura solo il blocco di creazione fog: la 401 da API call propagava uncaught fuori dal thread `Parallel.each` e `TENANT_TOKEN_CACHE` manteneva il token revocato fino a `expires_at` — ogni refresh successivo riusava il token revocato e falliva nuovamente. | `rescue Excon::Errors::Unauthorized, Excon::Error::Unauthorized` in `accessor_for_accessible_tenants`: log WARN + `invalidate_tenant_token` + `nil`. Al refresh successivo il cache miss forza un nuovo POST `/v3/auth/tokens`. | `06dbfb92` |

### Note sui 401 residui nei log
I tenant inaccessibili generano 401 perché `service_for_each_accessible_tenant` itera su TUTTI i tenant visibili a Keystone e tenta `detect_service` per ogni service type. Non sono bug: `detect_service` li cattura e ritorna nil. Risoluzione: aggiungere `miqstagmilano` come membro dei tenant inaccessibili in OpenStack (es. tenant `service` — è il tenant OpenStack interno per i servizi di sistema; dopo averlo fatto i 401 sono scomparsi).

### Stato log operativi post-patch
Log puliti al termine del ciclo di fix. Per ogni full refresh rimangono solo:
- 401 per tenant genuinamente inaccessibili (nessuno con utente correttamente configurato)
- Nessun WARN per NFV/Storage (abbassati a debug in `42b71919`)
- Nessun WARN per quote saltate (risolto in `7b9ca054`)

---

## Differenze di comportamento eccezioni: patch vs originale

| Scenario | Path originale | Path con patch |
|---|---|---|
| Keystone irraggiungibile (SocketError) | `Excon::Errors::SocketError` → `MiqHostError` (transiente) | stesso: `build_tenant_token` re-raise → `MiqHostError` |
| Timeout Keystone | `Excon::Errors::Timeout` → `MiqUnreachableError` | stesso |
| Credenziali errate / tenant inaccessibile (401 auth) | `Excon::Errors::Unauthorized` → rescuato da `detect_service` → tenant skippato | stesso: 401 in `build_tenant_token` propaga direttamente a `detect_service` |
| Token scaduto (401 mid-refresh, durante `raw_connect_with_token`) | non applicabile (auth fresca ogni call) | `with_auth_retry` invalida e riautentica |
| Token revocato esternamente (401 durante API call dopo `connect()`) | non applicabile | `accessor_for_accessible_tenants` rescua, invalida cache, ritorna nil → re-auth al refresh successivo |
| Service non nel catalog | `Fog::Service::NotFound` → `ServiceNotAvailable` | `endpoint_url_from_catalog` ritorna nil → Fog salta auth e usa management_url nil |

---

## Metodi privati introdotti dalla patch

| Metodo | Scopo |
|---|---|
| `token_cache_enabled?` | Feature flag: legge `Settings.ems_refresh.openstack.auth_token_cache_enabled`, default `true` |
| `fetch_or_build_tenant_token(tenant, opts)` | Lookup atomico in cache o build nuovo token |
| `build_tenant_token(tenant, _opts)` | Unico POST /v3/auth/tokens, con SSL corretto via `try_connection` |
| `tenant_token_valid?(entry)` | Controlla che `expires_at - TOKEN_EXPIRY_MARGIN > Time.now.utc` |
| `tenant_cache_key(tenant)` | Genera chiave cache `"user@host:port\|\|tenant"` |
| `keystone_auth_opts(tenant)` | Opzioni per `Fog::OpenStack::Auth::Token.build` (v2/v3, domain, project) |
| `base_fog_opts(opts)` | Opzioni base per istanziare fog service senza credenziali |
| `endpoint_url_from_catalog(catalog, service, opts)` | Risolve management URL dal catalog in memoria |
| `fog_service_type(service, opts)` | Mappa nomi ManageIQ → service type OpenStack catalog |
| `with_auth_retry(tenant, opts)` | Chiama `fetch_or_build_tenant_token`, poi single-shot retry su 401 da API fog (non da auth iniziale) |
| `wrap_in_service_delegate(raw_service, service)` | Wrappa fog service nel Delegate corrispondente |
| `self.raw_connect_with_token(service, opts, security_protocol)` | Istanzia fog con token pre-ottenuto |
| `self.raw_connect_direct(service, opts)` | Tail di raw_connect senza la parte di auth |
| `self.invalidate_tenant_token(address:, username:, tenant:)` | Invalida selettivamente la cache (utile dopo rotazione credenziali) |

---

## Rollback

Disabilitare il path cached senza deploy:

```ruby
# In ManageIQ console o via Settings YAML
Settings.ems_refresh.openstack.auth_token_cache_enabled = false
```

Oppure invalidare manualmente tutta la cache di un EMS:

```ruby
OpenstackHandle::Handle.invalidate_tenant_token(address: "10.94.0.100")
```

---

## Dipendenze chiave

- fog-openstack 1.1.5 (sorgente in `/Users/niccolo.alfredosourcesense.com/fog-openstack`)
- concurrent-ruby (`Concurrent::Map`)
- Keystone v3, token Fernet durata 3600s
- Security protocol: ssl-no-validation (`ssl_verify_peer: false`)
- Region: Milano (case-sensitive nel catalog lookup)

## Note fog-openstack rilevanti

- `Fog::OpenStack::Core#initialize` (core.rb:203): `@current_tenant = options[:current_tenant]` — letto **prima** di `authenticate()`
- `Fog::OpenStack::Core#authenticate` (core.rb:236): quando `openstack_management_url` è già settato, salta il POST e NON aggiorna `@current_tenant`
- `token.tenant` per v3 (auth/token/v3.rb:67): `@data['token']['project']` — Hash con `id`, `name`, `domain`
- **Chiavi simbolo**: sul sistema deployato `Fog::JSON.decode` usa `symbolize_names`, quindi `token.tenant` ha chiavi `:id`, `:name`, `:domain`. `build_tenant_token` chiama `transform_keys(&:to_s)` prima di cachare per garantire accesso con chiave stringa nei delegate.
