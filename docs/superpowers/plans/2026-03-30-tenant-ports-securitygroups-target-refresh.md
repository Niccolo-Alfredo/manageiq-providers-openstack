# Tenant-Scoped Ports & Security Groups Target Refresh — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a tenant is targeted for refresh, sync its ports, security groups, and firewall rules from OpenStack — same pattern as the existing quota sync.

**Architecture:** Extend the `TargetCollection` collector to fetch ports/SGs/firewall rules by `tenant_id` when `references(:cloud_tenants)` is present. Update the persister's network collection definitions to add `parent_inventory_collections` and `targeted_arel` so the inventory framework knows how to scope deletions/updates to the targeted tenants. No parser changes needed — existing parsers already handle these resources.

**Tech Stack:** Ruby, ManageIQ InventoryRefresh framework, Fog::OpenStack (Neutron API)

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `app/models/manageiq/providers/openstack/inventory/collector/target_collection.rb` | Fetch ports, SGs, firewall rules by tenant_id |
| Modify | `app/models/manageiq/providers/openstack/inventory/persister/definitions/network_collections.rb` | Register tenant-scoped targeted_arel for ports, SGs, firewall rules |

---

### Task 1: Extend `network_ports` collector to fetch by tenant

**Files:**
- Modify: `app/models/manageiq/providers/openstack/inventory/collector/target_collection.rb:50-59`

- [ ] **Step 1: Update the `network_ports` method**

Replace lines 50-59 with:

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

- [ ] **Step 2: Commit**

```bash
git add app/models/manageiq/providers/openstack/inventory/collector/target_collection.rb
git commit -m "feat: fetch network ports by tenant during target refresh"
```

---

### Task 2: Extend `security_groups` collector to fetch by tenant

**Files:**
- Modify: `app/models/manageiq/providers/openstack/inventory/collector/target_collection.rb:70-75`

- [ ] **Step 1: Update the `security_groups` method**

Replace lines 70-75 with:

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

- [ ] **Step 2: Commit**

```bash
git add app/models/manageiq/providers/openstack/inventory/collector/target_collection.rb
git commit -m "feat: fetch security groups by tenant during target refresh"
```

---

### Task 3: Extend `firewall_rules` collector to fetch when tenants are targeted

**Files:**
- Modify: `app/models/manageiq/providers/openstack/inventory/collector/target_collection.rb:77-83`

- [ ] **Step 1: Update the `firewall_rules` method**

Replace lines 77-83 with:

```ruby
def firewall_rules
  return [] unless network_service
  return @firewall_rules if @firewall_rules&.any?

  if references(:firewall_rules).present? || references(:security_groups).present? || references(:cloud_tenants).present?
    @firewall_rules = network_service.handled_list(:security_group_rules, {}, openstack_network_admin?)
  else
    @firewall_rules = []
  end

  @firewall_rules
end
```

- [ ] **Step 2: Commit**

```bash
git add app/models/manageiq/providers/openstack/inventory/collector/target_collection.rb
git commit -m "feat: fetch firewall rules when tenants are targeted for refresh"
```

---

### Task 4: Update persister `network_ports` collection with tenant-scoped `targeted_arel`

**Files:**
- Modify: `app/models/manageiq/providers/openstack/inventory/persister/definitions/network_collections.rb:18-20`

- [ ] **Step 1: Update the `network_ports` collection registration**

Replace lines 18-20:

```ruby
    add_network_collection(:network_ports) do |builder|
      builder.add_properties(:delete_method => :disconnect_port)
    end
```

With:

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
```

- [ ] **Step 2: Commit**

```bash
git add app/models/manageiq/providers/openstack/inventory/persister/definitions/network_collections.rb
git commit -m "feat: add tenant-scoped targeted_arel for network_ports"
```

---

### Task 5: Update persister `security_groups` collection with tenant-scoped `targeted_arel`

**Files:**
- Modify: `app/models/manageiq/providers/openstack/inventory/persister/definitions/network_collections.rb:22-28`

- [ ] **Step 1: Update the `security_groups` collection registration**

Replace lines 22-28:

```ruby
    add_network_collection(:security_groups) do |builder|
      # targeted refresh workaround-- always refresh the whole security group collection
      # regardless of whether this is a TargetCollection or not
      # because OpenStack doesn't give us UUIDs of new or changed security groups,
      # we just get an event that one of them changed
      builder.add_properties(:targeted => false) if references(:security_groups).present?
    end
```

With:

```ruby
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
      # targeted refresh workaround-- always refresh the whole security group collection
      # regardless of whether this is a TargetCollection or not
      # because OpenStack doesn't give us UUIDs of new or changed security groups,
      # we just get an event that one of them changed
      builder.add_properties(:targeted => false) if references(:security_groups).present?
    end
```

- [ ] **Step 2: Commit**

```bash
git add app/models/manageiq/providers/openstack/inventory/persister/definitions/network_collections.rb
git commit -m "feat: add tenant-scoped targeted_arel for security_groups"
```

---

### Task 6: Update persister `firewall_rules` collection with SG-scoped `targeted_arel`

**Files:**
- Modify: `app/models/manageiq/providers/openstack/inventory/persister/definitions/network_collections.rb:14-16`

- [ ] **Step 1: Update the `firewall_rules` collection registration**

Replace lines 14-16:

```ruby
    add_network_collection(:firewall_rules) do |builder|
      builder.add_properties(:manager_ref => %i[ems_ref])
    end
```

With:

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

- [ ] **Step 2: Commit**

```bash
git add app/models/manageiq/providers/openstack/inventory/persister/definitions/network_collections.rb
git commit -m "feat: add SG-scoped targeted_arel for firewall_rules"
```

---

### Task 7: End-to-end verification

- [ ] **Step 1: Verify the code loads without errors**

Start a ManageIQ Rails console and load the modified classes:

```bash
bin/rails console
```

```ruby
# Verify classes load
ManageIQ::Providers::Openstack::Inventory::Collector::TargetCollection
ManageIQ::Providers::Openstack::Inventory::Persister::Definitions::NetworkCollections
puts "Classes loaded successfully"
```

- [ ] **Step 2: Trigger a tenant target refresh against a test OpenStack environment**

In ManageIQ UI or console, trigger a targeted refresh for a known tenant and verify:
- Ports for the tenant appear/update in the ManageIQ DB
- Security groups for the tenant appear/update
- Firewall rules for those SGs appear/update
- No errors in `evm.log`

- [ ] **Step 3: Verify event-based refresh still works**

Create/update a port or security group directly in OpenStack and confirm the event-driven refresh still processes correctly (existing functionality not broken).

- [ ] **Step 4: Check logs for tenant-scoped fetches**

```bash
grep -E "(handled_list.*tenant_id|network_ports|security_groups)" log/evm.log | tail -20
```
