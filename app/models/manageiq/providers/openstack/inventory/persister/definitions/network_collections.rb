module ManageIQ::Providers::Openstack::Inventory::Persister::Definitions::NetworkCollections
  extend ActiveSupport::Concern

  def initialize_network_inventory_collections
    add_network_collection(:cloud_networks)
    add_network_collection(:cloud_subnets)
    add_network_collection(:floating_ips)
    add_network_collection(:network_routers)

    add_network_collection(:cloud_subnet_network_ports) do |builder|
      builder.add_properties(:parent_inventory_collections => %i[vms network_ports])
    end

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
