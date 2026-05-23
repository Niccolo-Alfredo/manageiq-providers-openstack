require 'active_support/inflector'
require 'util/miq-exception'
require 'parallel'
require 'concurrent'

module OpenstackHandle
  class Handle
    attr_accessor :username, :password, :address, :port, :api_version, :security_protocol, :connection_options
    attr_reader :project_name
    attr_writer   :default_tenant_name

    # Class-level Keystone token cache shared across every Handle instance
    # living in the same process. Survives EMS reloads from the DB
    # between refresh tasks, so the same worker authenticates once per
    # tenant per token lifetime instead of once per task.
    #
    # Key   : "username@address:port||tenant_name"
    # Value : {@link CachedToken}
    # Concurrency: `Concurrent::Map#compute` makes the read-or-write
    # critical section atomic per-key, preventing thundering-herd on
    # Keystone when several threads miss the same tenant at once.
    TENANT_TOKEN_CACHE = Concurrent::Map.new

    # Safety margin (seconds) subtracted from the real Keystone token
    # expiry before considering an entry stale. With the default 3600s
    # Keystone token, this triggers re-auth roughly every 55 minutes.
    TOKEN_EXPIRY_MARGIN = 60

    CachedToken = Struct.new(:token_str, :catalog, :expires_at, keyword_init: true)

    SERVICE_NAME_MAP = {
      "Compute"       => :nova,
      "Network"       => :neutron,
      "NFV"           => :nfv,
      "Image"         => :glance,
      "Volume"        => :cinder,
      "Storage"       => :swift,
      "Metering"      => :ceilometer,
      "Baremetal"     => :baremetal,
      "Orchestration" => :orchestration,
      "Planning"      => :planning,
      "Introspection" => :introspection,
      "Workflow"      => :workflow,
      "Metric"        => :metric,
      "Event"         => :event,
    }

    def self.try_connection(security_protocol, ssl_options = {})
      # For backwards compatibility take blank security_protocol as SSL
      if security_protocol.blank? || security_protocol == 'ssl' || security_protocol == 'ssl-no-validation'
        yield "https", {:ssl_verify_peer => false}
      elsif security_protocol == 'ssl-with-validation'
        excon_ssl_options = {:ssl_verify_peer => true}.merge(ssl_options)
        yield "https", excon_ssl_options
      else
        yield "http", {}
      end
    end

    def self.raw_connect_try_ssl(username, password, address, port, service = "Compute", options = nil,
                                 security_protocol = nil)
      opts = options.dup
      ssl_options = opts.delete(:ssl_options) || {}
      try_connection(security_protocol, ssl_options) do |scheme, connection_options|
        auth_url = auth_url(address, port, scheme)
        opts[:connection_options] = (opts[:connection_options] || {}).merge(connection_options)
        raw_connect(username, password, auth_url, service, opts)
      end
    end

    def self.raw_connect(username, password, auth_url, service = "Compute", extra_opts = nil)
      opts = {
        :openstack_auth_url      => auth_url,
        :openstack_username      => username,
        :openstack_api_key       => password,
        :openstack_endpoint_type => 'publicURL',
      }
      opts.merge!(extra_opts) if extra_opts

      opts[:openstack_service_type] = ["nfv-orchestration"] if service == "NFV"
      opts[:openstack_service_type] = ["workflowv2"] if service == "Workflow"

      if service == "Planning"
        Fog::OpenStack::Planning.new(opts)
      elsif service == "Workflow"
        Fog::OpenStack::Workflow.new(opts)
      elsif service == "Metric"
        Fog::OpenStack::Metric.new(opts)
      elsif service == "Event"
        Fog::OpenStack::Event.new(opts)
      else
        Fog::OpenStack.const_get(service).new(opts)
      end
    rescue Fog::OpenStack::Auth::Catalog::ServiceTypeError, Fog::Service::NotFound
      $fog_log.warn("MIQ(#{self.class.name}##{__method__}) "\
                    "Service #{service} not available for openstack provider #{auth_url}")
      raise MiqException::ServiceNotAvailable
    end

    def self.auth_url(address, port = 5000, scheme = "http", path = '')
      URI::Generic.build(:scheme => scheme, :host => address, :port => port.to_i, :path => path).to_s
    end

    class << self
      attr_writer :connection_options
    end

    class << self
      attr_reader :connection_options
    end

    def initialize(username, password, address, port = nil, api_version = nil, security_protocol = nil,
                   extra_options = {})
      @username          = username
      @password          = password
      @address           = address
      @port              = port || 5000
      @api_version       = api_version || 'v2'
      @security_protocol = security_protocol || 'ssl'
      @extra_options     = extra_options
      @thread_limit      = Settings.ems_refresh.openstack.parallel_thread_limit || 0

      @connection_cache   = {}
      @connection_options = self.class.connection_options
    end

    def thread_limit
      Rails.env.test? ? 0 : @thread_limit
    end

    def ssl_options
      @ssl_options ||= {}
      return @ssl_options unless @ssl_options.blank?

      @ssl_options[:ssl_ca_file]    = @extra_options[:ssl_ca_file] unless @extra_options[:ssl_ca_file].blank?
      @ssl_options[:ssl_ca_path]    = @extra_options[:ssl_ca_path] unless @extra_options[:ssl_ca_path].blank?
      # ssl_cert_store is dependent on the presence of ssl_ca_file
      @ssl_options[:ssl_cert_store] = @extra_options[:ssl_cert_store] unless @extra_options[:ssl_ca_file].blank?
      @ssl_options
    end

    def excon_options
      @excon_options ||= {}
      return @excon_options unless @excon_options.blank?

      @excon_options[:omit_default_port] = @extra_options[:omit_default_port] unless
                                           @extra_options[:omit_default_port].blank?
      @excon_options[:read_timeout]      = @extra_options[:read_timeout] unless @extra_options[:read_timeout].blank?

      # Beware of proxies that lie about gzip encoding and content length.
      if @extra_options[:proxy].present?
        @excon_options[:proxy] = @extra_options[:proxy]
        @excon_options[:headers] = {'Accept-Encoding' => 'identity,deflate'}
      end

      @excon_options
    end

    def domain_id
      @extra_options[:domain_id]
    end

    def region
      @extra_options[:region]
    end

    def browser_url
      "http://#{address}/dashboard"
    end

    # Public entry point for obtaining a Fog OpenStack service handle.
    #
    # Two execution paths exist:
    #
    # * **token-cache path** (default): authenticate once per tenant via
    #   {TENANT_TOKEN_CACHE}, then build every Fog service for that
    #   tenant by passing the cached `auth_token` + `management_url` so
    #   Fog skips its internal `POST /v3/auth/tokens`.
    # * **legacy path**: enabled by setting
    #   `Settings.ems_refresh.openstack.auth_token_cache_enabled = false`.
    #   Falls back to the original implementation kept in
    #   {#connect_without_cache}, useful as an emergency rollback.
    #
    # Signature and return value are unchanged. The wrapping in the
    # per-service Delegate class is preserved across both paths.
    def connect(options = {})
      return connect_without_cache(options) unless token_cache_enabled?

      opts    = options.dup
      service = (opts.delete(:service) || "Compute").to_s.camelize
      tenant  = opts.delete(:tenant_name)
      discover_tenants = opts.fetch(:discover_tenants, true)
      opts.delete(:discover_tenants)
      opts.delete(:auth_type)

      if discover_tenants && tenant.blank?
        tenant = default_tenant_name
      end

      raw_service = with_auth_retry(tenant) do
        cached = fetch_or_build_tenant_token(tenant, opts)

        management_url = endpoint_url_from_catalog(cached.catalog, service, opts)

        fog_opts = base_fog_opts(opts).merge(
          :openstack_auth_token     => cached.token_str,
          :openstack_management_url => management_url
        )

        self.class.raw_connect_with_token(service, fog_opts, security_protocol)
      end

      wrap_in_service_delegate(raw_service, service)
    end

    # Original `connect` implementation, retained verbatim as a rollback
    # path behind the `auth_token_cache_enabled` feature flag. Do not
    # edit unless you are also editing the cached path above.
    def connect_without_cache(options = {})
      opts     = options.dup
      service  = (opts.delete(:service) || "Compute").to_s.camelize
      tenant   = opts.delete(:tenant_name)
      discover_tenants = opts.fetch(:discover_tenants, true)
      opts.delete(:discover_tenants)
      domain   = domain_id

      # Do not send auth_type to fog, it throws warning
      opts.delete(:auth_type)

      if discover_tenants && tenant.blank?
        tenant = default_tenant_name
      end

      if api_version == 'v2'
        opts[:openstack_tenant] = tenant if tenant
        opts[:openstack_identity_api_version] = 'v2.0'
      else # "v3"
        opts[:openstack_project_name] = @project_name = tenant if tenant
        opts[:openstack_project_domain_id] = domain
        opts[:openstack_user_domain_id]    = domain
      end

      opts[:openstack_region] = region

      svc_cache = (@connection_cache[service] ||= {})
      svc_cache[tenant] ||= begin
        opts[:connection_options] = (connection_options || {}).merge(excon_options)
        opts[:ssl_options]        = ssl_options

        raw_service = self.class.raw_connect_try_ssl(username, password, address, port, service, opts,
                                                     security_protocol)

        wrap_in_service_delegate(raw_service, service)
      end
    end

    # Invalidate one or more cached tenant tokens. Useful from console
    # after rotating EMS credentials, or programmatically when a 401 is
    # observed before the recorded expiry.
    #
    # Filters compose by AND. With no filters the whole cache is wiped.
    #
    # @example invalidate everything
    #   OpenstackHandle::Handle.invalidate_tenant_token
    # @example invalidate every tenant of a given EMS host
    #   OpenstackHandle::Handle.invalidate_tenant_token(:address => "10.0.0.1")
    def self.invalidate_tenant_token(address: nil, username: nil, tenant: nil)
      if address.nil? && username.nil? && tenant.nil?
        TENANT_TOKEN_CACHE.clear
        return
      end

      TENANT_TOKEN_CACHE.delete_if do |key, _|
        id_part, t = key.split("||", 2)
        user_host = id_part || ""
        (address.nil?  || user_host.end_with?("@#{address}")) &&
          (username.nil? || user_host.start_with?("#{username}@")) &&
          (tenant.nil?   || t == tenant)
      end
    end

    def baremetal_service(tenant_name = nil)
      connect(:service => "Baremetal", :tenant_name => tenant_name)
    end

    def detect_baremetal_service(tenant_name = nil)
      detect_service("Baremetal", tenant_name)
    end

    def orchestration_service(tenant_name = nil)
      connect(:service => "Orchestration", :tenant_name => tenant_name)
    end

    def detect_orchestration_service(tenant_name = nil)
      detect_service("Orchestration", tenant_name)
    end

    def planning_service(tenant_name = nil)
      connect(:service => "Planning", :tenant_name => tenant_name)
    end

    def detect_planning_service(tenant_name = nil)
      detect_service("Planning", tenant_name)
    end

    def compute_service(tenant_name = nil)
      connect(:service => "Compute", :tenant_name => tenant_name)
    end
    alias_method :connect_compute, :compute_service

    def identity_service(discover_tenants = true)
      connect(:service => "Identity", :discover_tenants => discover_tenants)
    end
    alias_method :connect_identity, :identity_service

    def network_service(tenant_name = nil)
      connect(:service => "Network", :tenant_name => tenant_name)
    end
    alias_method :connect_network, :network_service

    def detect_network_service(tenant_name = nil)
      detect_service("Network", tenant_name)
    end

    def nfv_service(tenant_name = nil)
      connect(:service => "NFV", :tenant_name => tenant_name)
    end
    alias_method :connect_nfv, :nfv_service

    def detect_nfv_service(tenant_name = nil)
      detect_service("NFV", tenant_name)
    end

    def image_service(tenant_name = nil)
      connect(:service => "Image", :tenant_name => tenant_name)
    end
    alias_method :connect_image, :image_service

    def detect_image_service(tenant_name = nil)
      detect_service("Image", tenant_name)
    end

    def volume_service(tenant_name = nil)
      connect(:service => "Volume", :tenant_name => tenant_name)
    end
    alias_method :connect_volume, :volume_service
    alias_method :cinder_service, :volume_service

    def detect_volume_service(tenant_name = nil)
      detect_service("Volume", tenant_name)
    end

    def storage_service(tenant_name = nil)
      connect(:service => "Storage", :tenant_name => tenant_name)
    end
    alias_method :connect_storage, :storage_service
    alias_method :swift_service,   :storage_service

    def detect_storage_service(tenant_name = nil)
      detect_service("Storage", tenant_name)
    end

    def metering_service(tenant_name = nil)
      connect(:service => "Metering", :tenant_name => tenant_name)
    end
    alias_method :connect_metering, :metering_service

    def detect_metering_service(tenant_name = nil)
      detect_service("Metering", tenant_name)
    end

    def introspection_service(tenant_name = nil)
      connect(:service => "Introspection", :tenant_name => tenant_name)
    end
    alias_method :connect_introspection, :introspection_service

    def detect_introspection_service(tenant_name = nil)
      detect_service("Introspection", tenant_name)
    end

    def workflow_service(tenant_name = nil)
      connect(:service => "Workflow", :tenant_name => tenant_name)
    end
    alias_method :connect_workflow, :workflow_service

    def metric_service(tenant_name = nil)
      connect(:service => "Metric", :tenant_name => tenant_name)
    end
    alias_method :connect_metric, :metric_service

    def event_service(tenant_name = nil)
      connect(:service => "Event", :tenant_name => tenant_name)
    end
    alias_method :connect_event, :event_service

    def detect_metric_service(tenant_name = nil)
      detect_service("Metric", tenant_name)
    end

    def detect_event_service(tenant_name = nil)
      detect_service("Event", tenant_name)
    end

    def detect_workflow_service(tenant_name = nil)
      detect_service("Workflow", tenant_name)
    end

    def detect_service(service, tenant_name = nil)
      connect(:service => service, :tenant_name => tenant_name)
    rescue => err
      $fog_log.warn("MIQ(#{self.class.name}.#{__method__}) detect service error: #{err}")
      return nil
    end

    def tenants
      @tenants ||= identity_service(false).visible_tenants
    end

    def tenant_names
      @tenant_names ||= tenants.collect(&:name)
    end

    def tenant_accessible?(name)
      begin
        compute_service(name)
        true
      rescue Excon::Errors::Unauthorized
        false
      end
    end

    def default_tenant_name
      @default_tenant_name ||= detect_default_tenant_name
    end

    def detect_default_tenant_name
      return "admin" if tenant_accessible?("admin")

      tenant_names.each do |name|
        next if name == "services"
        return name if tenant_accessible?(name)
      end

      nil
    end

    def service_for_each_accessible_tenant(service_name)
      services = []
      all_tenants = tenants
      all_tenants.delete("services")
      ::Parallel.each(all_tenants, :in_threads => thread_limit) do |tenant|
        service = detect_service(service_name, tenant.name)
        if service
          services << [service, tenant]
        else
          $fog_log.warn("MIQ(#{self.class.name}##{__method__}) "\
                        "Could not access service #{service_name} for tenant #{tenant.name} on OpenStack #{@address}")
        end
      end
      services
    end

    def accessor_for_accessible_tenants(service, accessor, unique_id, array_accessor = true)
      results = []
      not_found_error = Fog::OpenStack.const_get(service)::NotFound
      ::Parallel.each(service_for_each_accessible_tenant(service), :in_threads => thread_limit) do |svc, project|

        response = begin
          if accessor.kind_of?(Proc)
            accessor.call(svc)
          else
            array_accessor ? svc.send(accessor).to_a : svc.send(accessor)
          end
        rescue not_found_error, Excon::Errors::NotFound => err
          $fog_log.warn("MIQ(#{self.class.name}.#{__method__}) HTTP 404 Error during OpenStack request. " \
                        "Skipping inventory item #{service} #{accessor}\n#{err}")
          nil
        rescue Excon::Error::Timeout, Fog::Errors::TimeoutError => err
          info = OpenstackHandle::HandledList.tcos_endpoint_info(svc) rescue {}
          kv = info.map { |k, v| "#{k}=#{v}" }.join(' ')
          tcos_msg = "[TCOS-ENDPOINT] event=timeout service=#{service} accessor=#{accessor} project=#{project&.name} #{kv} err=#{err.class}: #{err.message}"
          $fog_log.warn("MIQ(#{self.class.name}.#{__method__}) timeout during OpenStack request. #{tcos_msg} Skipping inventory item #{service} #{accessor}")
          (ManageIQ::Providers::Openstack::RefreshParserCommon::HelperMethods.tcos_refresh_logger.warn(tcos_msg) rescue nil)
          nil
        rescue Excon::Error::Socket, Fog::Errors::Error => err
          info = OpenstackHandle::HandledList.tcos_endpoint_info(svc) rescue {}
          kv = info.map { |k, v| "#{k}=#{v}" }.join(' ')
          tcos_msg = "[TCOS-ENDPOINT] event=socket service=#{service} accessor=#{accessor} project=#{project&.name} #{kv} err=#{err.class}: #{err.message}"
          $fog_log.warn("MIQ(#{self.class.name}.#{__method__}) failed to connect during OpenStack request. #{tcos_msg} Skipping inventory item #{service} #{accessor}")
          (ManageIQ::Providers::Openstack::RefreshParserCommon::HelperMethods.tcos_refresh_logger.warn(tcos_msg) rescue nil)
          nil
        end

        if !response.nil? && array_accessor && response.last.kind_of?(Fog::Model)
          response.map { |item| item.project = project }
        end

        if response
          array_accessor ? results.concat(response) : results << response
        end
      end

      if unique_id.blank? && array_accessor && !results.nil?
        last_object = results.last
        unique_id = last_object.identity_name if last_object.kind_of?(Fog::Model)
      end

      if unique_id
        results.uniq! { |item| item.kind_of?(Hash) ? item[unique_id] : item.send(unique_id) }
      end
      results
    end

    private

    # Wraps a freshly built Fog service into the matching Delegate class
    # so the rest of the codebase keeps using the same wrapper API
    # regardless of the connect path that produced it.
    def wrap_in_service_delegate(raw_service, service)
      service_wrapper_name = "#{service}Delegate"
      if OpenstackHandle.const_defined?(service_wrapper_name)
        OpenstackHandle.const_get(service_wrapper_name).new(raw_service, self, SERVICE_NAME_MAP[service])
      else
        raw_service
      end
    end

    # Feature flag gate. Defaults to true; flip to false in Settings to
    # fall back to the legacy auth-per-service flow without redeploying.
    def token_cache_enabled?
      ::Settings.dig(:ems_refresh, :openstack, :auth_token_cache_enabled) != false
    end

    # Reads a valid token from TENANT_TOKEN_CACHE, or builds a fresh one.
    # Failures propagate to the caller and do NOT poison the cache:
    # Concurrent::Map#compute leaves any existing entry untouched when the
    # block raises, so a transient Keystone error does not evict a valid token.
    def fetch_or_build_tenant_token(tenant, opts)
      key = tenant_cache_key(tenant)
      TENANT_TOKEN_CACHE.compute(key) do |existing|
        if existing && tenant_token_valid?(existing)
          existing
        else
          build_tenant_token(tenant, opts)
        end
      end
    end

    # Runs the only Keystone POST in the cached path. Failures propagate
    # to the caller (and crucially do NOT poison the cache, since
    # `compute` writes only the block's return value — an exception
    # leaves the previous entry, if any, untouched).
    def build_tenant_token(tenant, _opts)
      auth_opts = keystone_auth_opts(tenant)

      # Derive ssl_verify_peer via try_connection so ssl-no-validation
      # correctly sets ssl_verify_peer: false, matching the legacy path.
      ssl_conn_opts = {}
      self.class.try_connection(security_protocol, ssl_options) do |_scheme, connection_options|
        ssl_conn_opts = connection_options
      end

      conn_opts = (connection_options || {})
                  .merge(excon_options)
                  .merge(ssl_conn_opts)

      token = Fog::OpenStack::Auth::Token.build(auth_opts, conn_opts)

      CachedToken.new(
        :token_str  => token.token,
        :catalog    => token.catalog,
        :expires_at => Time.parse(token.expires).utc
      )
    rescue => err
      $fog_log.error("TenantTokenCache: authentication failed tenant=#{tenant} address=#{address}: #{err.class}: #{err.message}")
      raise
    end

    def tenant_token_valid?(entry)
      return false unless entry.expires_at.is_a?(Time)
      Time.now.utc < (entry.expires_at - TOKEN_EXPIRY_MARGIN)
    end

    def tenant_cache_key(tenant)
      "#{username}@#{address}:#{port}||#{tenant}"
    end

    # Options consumed by `Fog::OpenStack::Auth::Token.build` — mirrors
    # the identity/scope subset that `raw_connect` used to pass when
    # delegating auth to each Fog service.
    def keystone_auth_opts(tenant)
      scheme   = security_protocol.to_s =~ /ssl/i ? "https" : "http"
      auth_url = self.class.auth_url(address, port, scheme)

      opts = {
        :openstack_auth_url => auth_url,
        :openstack_username => username,
        :openstack_api_key  => password,
      }

      if api_version == 'v2'
        opts[:openstack_tenant]               = tenant if tenant
        opts[:openstack_identity_api_version] = 'v2.0'
      else
        opts[:openstack_project_name]      = tenant if tenant
        opts[:openstack_project_domain_id] = domain_id
        opts[:openstack_user_domain_id]    = domain_id
      end

      opts
    end

    # Options used when instantiating the Fog service object itself.
    # Credentials are intentionally absent: the cached `auth_token` and
    # `management_url` (added by the caller) make Fog skip its own auth.
    def base_fog_opts(opts)
      # Le ssl_options (ca_file, cert_store) vengono mergiate dentro
      # connection_options — non come chiave top-level :ssl_options che
      # fog non riconosce nel path raw_connect_direct e causerebbe
      # "Unrecognized arguments: ssl_options". ssl_verify_peer viene
      # aggiunto separatamente da raw_connect_with_token via try_connection.
      conn_opts = (connection_options || {}).merge(excon_options).merge(ssl_options)

      {
        :openstack_auth_url      => self.class.auth_url(address, port),
        :openstack_region        => region,
        :openstack_endpoint_type => 'publicURL',
        :connection_options      => conn_opts,
      }.merge(opts.slice(:openstack_service_type))
    end

    # Resolve the management URL for a service against the cached
    # catalog. A nil return is a safe signal: Fog falls back to its
    # normal auth flow for that single service instead of crashing.
    def endpoint_url_from_catalog(catalog, service, opts)
      return nil if catalog.nil? || catalog.payload.empty?

      # Itera i service type uno alla volta in ordine di priorità, fermandosi
      # al primo match. Necessario perché alcuni ambienti pubblicano alias
      # multipli nello stesso catalog (es. volumev3 + block-storage per Cinder):
      # passarli tutti insieme a get_endpoint_url causerebbe EndpointError
      # "Multiple endpoints found". Questo rispecchia il comportamento del
      # dispatcher Fog::OpenStack::Volume.new che prova V3 → V2 → V1.
      service_types = Array(opts[:openstack_service_type].presence || fog_service_type(service, opts))
      endpoint_type = 'public'

      service_types.each do |type|
        begin
          url = catalog.get_endpoint_url([type], endpoint_type, region)
          return url if url
        rescue Fog::OpenStack::Auth::Catalog::ServiceTypeError,
              Fog::OpenStack::Auth::Catalog::EndpointError
          next
        end
      end

      $fog_log.warn("TenantTokenCache: no endpoint found service=#{service} region=#{region} tried=#{service_types.inspect}")
      nil
    rescue => err
      $fog_log.error("TenantTokenCache: unexpected catalog lookup error service=#{service}: #{err.class} #{err.message}")
      nil
    end

    # Map ManageIQ service names to the OpenStack `service_type` values
    # actually published in the Keystone catalog. Multi-valued entries
    # cover historical aliases (e.g. Cinder v3 vs the older `volume`).
    def fog_service_type(service, opts)
      return opts[:openstack_service_type] if opts[:openstack_service_type]

      {
        "Compute"       => ["compute"],
        "Network"       => ["network"],
        "Image"         => ["image"],
        "Volume"        => ["volumev3", "block-storage", "volumev2", "volume"],
        "Storage"       => ["object-store", "swift"],
        "Metering"      => ["metering", "cloudmetering"],
        "Identity"      => ["identity"],
        "Orchestration" => ["orchestration"],
        "Baremetal"     => ["baremetal"],
        "Introspection" => ["baremetal-introspection"],
        "Workflow"      => ["workflowv2"],
        "Metric"        => ["metric"],
        "Event"         => ["event", "panko"],
        "NFV"           => ["nfv-orchestration"],
      }.fetch(service, [service.downcase])
    end

    # Single-shot retry around a Fog call that may surface a stale token
    # (revoked early on Keystone). On 401 the tenant entry is purged and
    # the block is run again, so the next attempt re-authenticates.
    def with_auth_retry(tenant)
      attempts = 0
      begin
        attempts += 1
        yield
      rescue Excon::Errors::Unauthorized => err
        raise if attempts > 1

        $fog_log.warn("TenantTokenCache: 401 on tenant=#{tenant}, invalidating and retrying once: #{err.class}: #{err.message}")
        self.class.invalidate_tenant_token(:address => address, :username => username, :tenant => tenant)
        retry
      end
    end

    public

    # Variant of {raw_connect_try_ssl} that uses a pre-fetched token
    # instead of credentials. Skips the SSL fallback because the scheme
    # has already been resolved during `build_tenant_token`.
    def self.raw_connect_with_token(service, opts, security_protocol)
      try_connection(security_protocol) do |_scheme, ssl_connection_options|
        merged_opts = opts.dup
        merged_opts[:connection_options] = (merged_opts[:connection_options] || {}).merge(ssl_connection_options)
        raw_connect_direct(service, merged_opts)
      end
    end

    # Tail half of the legacy {raw_connect}, extracted so the
    # token-cache path can reuse it without re-running the credential
    # handling that is no longer relevant when a token is already known.
    def self.raw_connect_direct(service, opts)
      opts[:openstack_service_type] = ["nfv-orchestration"] if service == "NFV"
      opts[:openstack_service_type] = ["workflowv2"]        if service == "Workflow"

      if service == "Planning"
        Fog::OpenStack::Planning.new(opts)
      elsif service == "Workflow"
        Fog::OpenStack::Workflow.new(opts)
      elsif service == "Metric"
        Fog::OpenStack::Metric.new(opts)
      elsif service == "Event"
        Fog::OpenStack::Event.new(opts)
      else
        Fog::OpenStack.const_get(service).new(opts)
      end
    rescue Fog::OpenStack::Auth::Catalog::ServiceTypeError, Fog::Service::NotFound
      $fog_log.warn("MIQ(#{self.class.name}##{__method__}) Service #{service} not available for openstack provider #{opts[:openstack_auth_url]}")
      raise MiqException::ServiceNotAvailable
    end
  end
end
