module ManageIQ::Providers::Openstack::Inventory::Persister::Definitions::NetworkCollections
  extend ActiveSupport::Concern

  # Collections defined below use a tenant-scoped `targeted_arel`. That arel
  # decides which DB rows are "in scope" for archival when the collector does
  # not return them. We must therefore only register each collection when the
  # collector is actually going to fetch its contents — otherwise the
  # collector returns `[]` while the persister still believes "all rows of
  # the tenant" are in scope, and archives every row.
  #
  # Each gate below mirrors the corresponding branch in
  # `Collector::TargetCollection` (see `network_ports`, `security_groups`,
  # `firewall_rules`). Keeping the two in lock-step is the structural fix
  # for the "VM delete archives all SGs" class of bugs.

  def initialize_network_inventory_collections
    add_network_collection(:cloud_networks)
    add_network_collection(:cloud_subnets)
    add_network_collection(:floating_ips)
    add_network_collection(:network_routers)

    # network_ports: collector fetches by explicit port/router refs, or
    # tenant-wide when the refresh is tenant-triggered.
    #
    # cloud_subnet_network_ports declares `network_ports` as a parent
    # inventory collection, so it MUST be registered together with
    # `network_ports` — the scanner raises if a declared parent is missing.
    if register_network_ports?
      add_network_collection(:network_ports) do |builder|
        builder.add_properties(:delete_method => :disconnect_port)
        builder.add_properties(:parent_inventory_collections => %i[cloud_tenants])
        builder.add_targeted_arel(
          lambda do |inventory_collection|
            tenant_refs = inventory_collection.parent_inventory_collections
                                              .collect(&:manager_uuids)
                                              .map(&:to_a)
                                              .flatten
            tenant_ids = inventory_collection.parent
                                             .cloud_tenants
                                             .where(:ems_ref => tenant_refs)
                                             .pluck(:id)
            inventory_collection.parent.network_ports
                                .where(:cloud_tenant_id => tenant_ids)
          end
        )
      end

      add_network_collection(:cloud_subnet_network_ports) do |builder|
        builder.add_properties(:parent_inventory_collections => %i[vms network_ports])
        builder.add_targeted_arel(
          lambda do |inventory_collection|
            np_refs = inventory_collection.parent_inventory_collections
                                          .select { |c| c.name == :network_ports }
                                          .flat_map { |c| c.manager_uuids.to_a }
            np_ids = inventory_collection.parent.network_ports
                                         .where(:ems_ref => np_refs)
                                         .pluck(:id)
            inventory_collection.parent.cloud_subnet_network_ports
                                .where(:network_port_id => np_ids)
          end
        )
      end
    end

    # firewall_rules: collector fetches them either tenant-wide (when the
    # refresh is tenant-triggered) or via explicit SG/firewall_rule refs.
    if register_firewall_rules?
      add_network_collection(:firewall_rules) do |builder|
        builder.add_properties(:manager_ref => %i[ems_ref])
        builder.add_properties(:parent_inventory_collections => %i[security_groups])
        builder.add_targeted_arel(
          lambda do |inventory_collection|
            sg_refs = inventory_collection.parent_inventory_collections
                                          .collect(&:manager_uuids)
                                          .map(&:to_a)
                                          .flatten
            sg_ids = inventory_collection.parent
                                         .security_groups
                                         .where(:ems_ref => sg_refs)
                                         .pluck(:id)
            inventory_collection.parent.firewall_rules
                                .where(:resource_type => "SecurityGroup",
                                       :resource_id   => sg_ids)
          end
        )
      end
    end

    # security_groups: collector fetches by explicit SG refs, or tenant-wide
    # when the refresh is tenant-triggered. For VM/Volume/Stack-only
    # triggers neither condition holds and the collection must stay
    # un-registered to prevent the tenant-scoped arel from archiving the
    # whole tenant.
    if register_security_groups?
      add_network_collection(:security_groups) do |builder|
        builder.add_properties(:parent_inventory_collections => %i[cloud_tenants])
        builder.add_targeted_arel(
          lambda do |inventory_collection|
            tenant_refs = inventory_collection.parent_inventory_collections
                                              .collect(&:manager_uuids)
                                              .map(&:to_a)
                                              .flatten
            tenant_ids = inventory_collection.parent
                                             .cloud_tenants
                                             .where(:ems_ref => tenant_refs)
                                             .pluck(:id)
            inventory_collection.parent.security_groups
                                .where(:cloud_tenant_id => tenant_ids)
          end
        )
        # targeted refresh workaround-- always refresh the whole security group collection
        # regardless of whether this is a TargetCollection or not
        # because OpenStack doesn't give us UUIDs of new or changed security groups,
        # we just get an event that one of them changed
        builder.add_properties(:targeted => false) if references(:security_groups).present?
      end
    end
  end

  private

  # Match the collector branches in
  # `Collector::TargetCollection#security_groups`: register when the
  # refresh carries explicit SG refs OR is tenant-triggered.
  def register_security_groups?
    references(:security_groups).present? || tenant_scope_active?
  end

  # Match the collector branches in
  # `Collector::TargetCollection#network_ports`: explicit port/router refs
  # OR tenant-triggered.
  def register_network_ports?
    references(:network_ports).present? ||
      references(:network_routers).present? ||
      tenant_scope_active?
  end

  # Match the collector branches in
  # `Collector::TargetCollection#firewall_rules`: explicit firewall_rule
  # refs, SG refs (used by the fallback full-list path), OR
  # tenant-triggered.
  def register_firewall_rules?
    references(:firewall_rules).present? ||
      references(:security_groups).present? ||
      tenant_scope_active?
  end
end