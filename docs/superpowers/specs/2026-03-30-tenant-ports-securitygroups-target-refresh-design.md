# Sync Ports and Security Groups During Tenant Target Refresh

## Context

When a tenant is the target of a targeted refresh in ManageIQ, the system already syncs quotas (added in commits `fb18c929` and `058ecf63`). However, ports and security groups belonging to that tenant are not refreshed unless triggered by a direct event (e.g., `port.update`, `security_group.create`).

This means that after a tenant refresh, the ManageIQ database may have stale port and security group data for that tenant. The goal is to apply the same pattern used for quotas: when a tenant is targeted for refresh, also fetch and sync its ports, security groups, and firewall rules.

## Design

### Files to Modify

1. **`app/models/manageiq/providers/openstack/inventory/collector/target_collection.rb`**
2. **`app/models/manageiq/providers/openstack/inventory/persister/definitions/network_collections.rb`**

### 1. Collector Changes (`target_collection.rb`)

#### `network_ports`

Extend the existing method to also fetch ports by tenant when `references(:cloud_tenants)` is present:

```ruby
def network_ports
  return [] unless network_service
  return @network_ports if @network_ports&.any?

  @network_ports = []

  # Existing: fetch by specific port refs and router refs
  if references(:network_ports).present?
    @network_ports += references(:network_ports).collect do |port_id|
      safe_get { network_service.ports.get(port_id) }
    end
    @network_ports += references(:network_routers).collect do |router_id|
      network_service.handled_list(:ports, :device_id => router_id)
    end.flatten
  end

  # New: fetch all ports for targeted tenants
  if references(:cloud_tenants).present?
    references(:cloud_tenants).each do |tenant_id|
      @network_ports += network_service.handled_list(:ports, :tenant_id => tenant_id)
    end
  end

  @network_ports = @network_ports.compact.uniq { |p| p.respond_to?(:id) ? p.id : p['id'] }
end
```

#### `security_groups`

Extend to also fetch by tenant:

```ruby
def security_groups
  return [] unless network_service
  return @security_groups if @security_groups&.any?

  @security_groups = []

  # Existing: fetch all SGs when any SG event arrives
  if references(:security_groups).present?
    @security_groups = network_service.handled_list(:security_groups, {}, openstack_network_admin?)
  end

  # New: fetch SGs for targeted tenants
  if references(:cloud_tenants).present?
    references(:cloud_tenants).each do |tenant_id|
      @security_groups += network_service.handled_list(:security_groups, :tenant_id => tenant_id)
    end
  end

  @security_groups = @security_groups.compact.uniq { |sg| sg.respond_to?(:id) ? sg.id : sg['id'] }
end
```

#### `firewall_rules`

Extend to also fetch when tenants are present (security group rules are needed when SGs are fetched):

```ruby
def firewall_rules
  return [] unless network_service
  return @firewall_rules if @firewall_rules&.any?

  # Fetch if SG refs or tenant refs are present
  if references(:firewall_rules).present? || references(:security_groups).present? || references(:cloud_tenants).present?
    @firewall_rules = network_service.handled_list(:security_group_rules, {}, openstack_network_admin?)
  else
    @firewall_rules = []
  end

  @firewall_rules
end
```

### 2. Persister Changes (`network_collections.rb`)

Add `parent_inventory_collections` and `targeted_arel` to `network_ports` and `security_groups`, following the same pattern as `cloud_resource_quotas`:

```ruby
add_network_collection(:network_ports) do |builder|
  builder.add_properties(:delete_method => :disconnect_port)
  builder.add_properties(:parent_inventory_collections => %i[cloud_tenants])
  builder.add_targeted_arel(
    lambda do |inventory_collection|
      tenant_refs = inventory_collection.parent_inventory_collections
                                        .collect(&:manager_uuids)
                                        .map(&:to_a)
                                        .flatten
      inventory_collection.parent.network_ports
                          .joins(:cloud_tenant)
                          .where('cloud_tenants.ems_ref' => tenant_refs)
    end
  )
end

add_network_collection(:security_groups) do |builder|
  builder.add_properties(:parent_inventory_collections => %i[cloud_tenants])
  builder.add_targeted_arel(
    lambda do |inventory_collection|
      tenant_refs = inventory_collection.parent_inventory_collections
                                        .collect(&:manager_uuids)
                                        .map(&:to_a)
                                        .flatten
      inventory_collection.parent.security_groups
                          .joins(:cloud_tenant)
                          .where('cloud_tenants.ems_ref' => tenant_refs)
    end
  )
  # Existing workaround: full refresh when SG event arrives
  builder.add_properties(:targeted => false) if references(:security_groups).present?
end
```

Similarly for `firewall_rules`:

```ruby
add_network_collection(:firewall_rules) do |builder|
  builder.add_properties(:manager_ref => %i[ems_ref])
  builder.add_properties(:parent_inventory_collections => %i[security_groups])
  builder.add_targeted_arel(
    lambda do |inventory_collection|
      sg_refs = inventory_collection.parent_inventory_collections
                                    .collect(&:manager_uuids)
                                    .map(&:to_a)
                                    .flatten
      inventory_collection.parent.firewall_rules
                          .joins(:resource)
                          .where('security_groups.ems_ref' => sg_refs)
    end
  )
end
```

### No Changes Needed

- **`infer_related_ems_refs!`**: Already handles tenant inference correctly.
- **Parser (`parser/network_manager.rb`)**: Already parses ports, SGs, and firewall rules from collector data — no changes needed.
- **Event target parser**: No changes — events still route to existing targets.

## Considerations

- **Data volume**: Ports can be numerous. Filtering by `tenant_id` in the OpenStack API call limits the result set.
- **Deduplication**: Using `uniq` by ID prevents duplicates when the same port/SG comes from both a direct event and a tenant refresh.
- **Existing SG workaround**: The `targeted => false` workaround for SG events remains in place alongside the new tenant-based logic.
- **Firewall rules**: When SGs are fetched for a tenant, their rules must also be fetched to keep the data consistent.

## Verification

1. Trigger a tenant target refresh (e.g., via an OpenStack event that resolves to a cloud_tenant target)
2. Verify in ManageIQ DB that the tenant's ports are updated (`NetworkPort` records)
3. Verify that the tenant's security groups are updated (`SecurityGroup` records)
4. Verify that firewall rules for those SGs are updated (`FirewallRule` records)
5. Verify that existing event-based refresh (port.update, security_group.create) still works correctly
6. Check logs for correct collector behavior (no errors, proper tenant filtering)
