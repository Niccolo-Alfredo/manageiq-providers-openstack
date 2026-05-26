module ManageIQ::Providers::Openstack::Inventory::Persister::Definitions::NetworkCollections
  extend ActiveSupport::Concern

  def initialize_network_inventory_collections
    add_network_collection(:cloud_networks)
    add_network_collection(:cloud_subnets)
    add_network_collection(:floating_ips)
    add_network_collection(:network_routers)

    add_network_collection(:cloud_subnet_network_ports) do |builder|
      persister_target = target
      builder.add_properties(:parent_inventory_collections => %i[vms network_ports])
      builder.add_targeted_arel(
        lambda do |inventory_collection|
          # Scope derived from `target.references(...)` instead of the parent
          # IC's `manager_uuids`: the latter is empty when the framework
          # evaluates the lambda before the parser has populated the
          # network_ports IC, which makes the scope `1=0`, hides existing
          # rows from the persister, and causes UniqueViolation on insert.
          if persister_target.try(:tenant_scope_active?)
            tenant_refs = persister_target.try(:references, :cloud_tenants) || []
            tenant_ids  = inventory_collection.parent.cloud_tenants
                                              .where(:ems_ref => tenant_refs).pluck(:id)
            inventory_collection.parent.cloud_subnet_network_ports
                                .joins(:network_port)
                                .where(:network_ports => {:cloud_tenant_id => tenant_ids})
          else
            port_refs = persister_target.try(:references, :network_ports) || []
            inventory_collection.parent.cloud_subnet_network_ports
                                .joins(:network_port)
                                .where(:network_ports => {:ems_ref => port_refs})
          end
        end
      )
    end

    add_network_collection(:firewall_rules) do |builder|
      persister_target = target
      builder.add_properties(:manager_ref => %i[ems_ref])
      builder.add_properties(:parent_inventory_collections => %i[security_groups])
      builder.add_targeted_arel(
        lambda do |inventory_collection|
          # Same rationale as cloud_subnet_network_ports above: scope from
          # `target.references(...)` rather than the parent IC's
          # `manager_uuids`, which would be empty when the lambda is
          # evaluated before the security_groups IC is populated and would
          # cause UniqueViolation on insert. Mirrors the two collector
          # branches in `Collector::TargetCollection#firewall_rules`.
          if persister_target.try(:tenant_scope_active?)
            tenant_refs = persister_target.try(:references, :cloud_tenants) || []
            tenant_ids  = inventory_collection.parent.cloud_tenants
                                              .where(:ems_ref => tenant_refs).pluck(:id)
            sg_ids = inventory_collection.parent.security_groups
                                         .where(:cloud_tenant_id => tenant_ids).pluck(:id)
          else
            sg_refs = persister_target.try(:references, :security_groups) || []
            sg_ids  = inventory_collection.parent.security_groups
                                          .where(:ems_ref => sg_refs).pluck(:id)
          end
          inventory_collection.parent.firewall_rules
                              .where(:resource_type => "SecurityGroup",
                                     :resource_id   => sg_ids)
        end
      )
    end

    add_network_collection(:network_ports) do |builder|
      persister_target = target
      builder.add_properties(:delete_method => :disconnect_port)
      builder.add_properties(:parent_inventory_collections => %i[cloud_tenants])
      builder.add_targeted_arel(
        lambda do |inventory_collection|
          # When the refresh was triggered by a CloudTenant, the collector
          # fetched ALL ports of that tenant from Neutron, so we can safely
          # scope the delete to the tenant. When the trigger is a VM/Volume,
          # the collector only fetched the ports referenced by that VM, so we
          # must restrict deletion to those explicit ems_refs - otherwise
          # every other port of the tenant would be wiped.
          # Tenant refs come from `target.references(:cloud_tenants)` rather
          # than the parent IC's `manager_uuids` for the same reason as
          # cloud_subnet_network_ports above (parent IC may be empty at
          # lambda evaluation time).
          if persister_target.try(:tenant_scope_active?)
            tenant_refs = persister_target.try(:references, :cloud_tenants) || []
            tenant_ids  = inventory_collection.parent.cloud_tenants
                                              .where(:ems_ref => tenant_refs).pluck(:id)
            inventory_collection.parent.network_ports
                                .where(:cloud_tenant_id => tenant_ids)
          else
            port_refs = persister_target.try(:references, :network_ports) || []
            inventory_collection.parent.network_ports
                                .where(:ems_ref => port_refs)
          end
        end
      )
    end

    add_network_collection(:security_groups) do |builder|
      persister_target = target
      builder.add_properties(:parent_inventory_collections => %i[cloud_tenants])
      builder.add_targeted_arel(
        lambda do |inventory_collection|
          # See network_ports above for the rationale: tenant-triggered
          # refreshes can reconcile by tenant, VM/Volume-triggered refreshes
          # must restrict delete scope to the SGs explicitly referenced to
          # avoid wiping the rest of the tenant's security groups.
          if persister_target.try(:tenant_scope_active?)
            tenant_refs = persister_target.try(:references, :cloud_tenants) || []
            tenant_ids  = inventory_collection.parent.cloud_tenants
                                              .where(:ems_ref => tenant_refs).pluck(:id)
            inventory_collection.parent.security_groups
                                .where(:cloud_tenant_id => tenant_ids)
          else
            sg_refs = persister_target.try(:references, :security_groups) || []
            inventory_collection.parent.security_groups
                                .where(:ems_ref => sg_refs)
          end
        end
      )
    end
  end
end
