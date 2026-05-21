class ManageIQ::Providers::Openstack::Inventory::Persister < ManageIQ::Providers::Inventory::Persister
  # TODO(lsmola) figure out a way to pass collector info, probably via target, then remove the below
  attr_reader :collector

  # @param manager [ManageIQ::Providers::BaseManager] A manager object
  # @param target [Object] A refresh Target object
  # @param collector [ManageIQ::Providers::Inventory::Collector] A Collector object
  def initialize(manager, target = nil, collector = nil)
    @manager   = manager
    @target    = target
    @collector = collector

    @collections = {}

    initialize_inventory_collections
  end

  def cinder_manager
    manager.kind_of?(ManageIQ::Providers::Openstack::StorageManager::CinderManager) ? manager : manager.cinder_manager
  end

  def swift_manager
    manager.kind_of?(ManageIQ::Providers::Openstack::StorageManager::SwiftManager) ? manager : manager.swift_manager
  end

  # Whether the current refresh has tenant-wide scope.
  #
  # Default for full-refresh persisters: true — full refresh always fetches
  # tenant-wide and must register every collection so the tenant-scoped
  # `targeted_arel` archival scope matches what the collector returns.
  #
  # {Persister::TargetCollection} overrides this with the real check
  # (true only when one of the original targets is a `CloudTenant`).
  # Collector and persister MUST agree on this flag — see
  # {Collector::TargetCollection#tenant_scope_active?}.
  #
  # @return [Boolean]
  def tenant_scope_active?
    true
  end
end
