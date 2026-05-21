class ManageIQ::Providers::Openstack::Inventory::Persister::TargetCollection < ManageIQ::Providers::Openstack::Inventory::Persister
  include ManageIQ::Providers::Openstack::Inventory::Persister::Definitions::CloudCollections
  include ManageIQ::Providers::Openstack::Inventory::Persister::Definitions::NetworkCollections
  include ManageIQ::Providers::Openstack::Inventory::Persister::Definitions::StorageCollections

  def targeted?
    true
  end

  def initialize_inventory_collections
    initialize_tag_mapper
    initialize_cloud_inventory_collections
    initialize_network_inventory_collections
    initialize_cinder_inventory_collections
  end

  # True only when the refresh was originally triggered by a CloudTenant target.
  #
  # Mirrors {Collector::TargetCollection#tenant_scope_active?} so collector
  # and persister agree on when a tenant-wide refresh is in effect. The
  # collector uses this flag to decide whether to do tenant-wide Neutron/
  # Cinder fetches; the persister uses it to decide whether tenant-scoped
  # `targeted_arel` (which would archive all rows in the tenant on a
  # mismatch) is a safe deletion scope. The two MUST stay in sync — if
  # they diverge, the persister archives records the collector never
  # re-fetched.
  #
  # @return [Boolean] true if any of the original target objects is a
  #   `CloudTenant` (or subclass), false otherwise.
  def tenant_scope_active?
    return @tenant_scope_active unless @tenant_scope_active.nil?
    classes = target.respond_to?(:targets) ? target.targets.map(&:class).to_set : Set.new
    @tenant_scope_active = classes.any? { |c| c <= CloudTenant }
  end
end
