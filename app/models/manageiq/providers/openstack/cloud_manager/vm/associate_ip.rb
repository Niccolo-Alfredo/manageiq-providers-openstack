module ManageIQ::Providers::Openstack::CloudManager::Vm::AssociateIp
  extend ActiveSupport::Concern

  included do
    supports :associate_floating_ip do
      if cloud_tenant.nil? || cloud_tenant.floating_ips.empty?
        _("There are no %{floating_ips} available to this %{instance}.") % {
          :floating_ips => ui_lookup(:tables => "floating_ips"),
          :instance     => ui_lookup(:table => "vm_cloud")
        }
      end
    end
    supports :disassociate_floating_ip do
      if floating_ips.empty?
        _("This %{instance} does not have any associated %{floating_ips}") % {
          :instance     => ui_lookup(:table => 'vm_cloud'),
          :floating_ips => ui_lookup(:tables => 'floating_ip')
        }
      end
    end
  end

  # Associate a floating IP to this VM via Nova, then queue a targeted
  # refresh so the VM<->floating_ip association is reconciled in MIQ
  # regardless of whether the Ceilometer/Panko event reaches us.
  def raw_associate_floating_ip(floating_ip_id)
    floating_ip_record = cloud_tenant.floating_ips.find(floating_ip_id)
    ext_management_system.with_provider_connection(compute_connection_options) do |connection|
      connection.associate_address(ems_ref, floating_ip_record.address)
    end
    EmsRefresh.queue_refresh(self)
  rescue => err
    _log.error "vm=[#{name}], floating_ip=[#{floating_ip_id}], error: #{err}"
    raise MiqException::MiqOpenstackApiRequestError, parse_error_message_from_fog_response(err), err.backtrace
  end

  # Disassociate a floating IP from this VM via Nova, then queue a targeted
  # refresh so the VM<->floating_ip association is reconciled in MIQ
  # regardless of whether the Ceilometer/Panko event reaches us.
  def raw_disassociate_floating_ip(floating_ip_id)
    floating_ip_record = cloud_tenant.floating_ips.find(floating_ip_id)
    ext_management_system.with_provider_connection(compute_connection_options) do |connection|
      connection.disassociate_address(ems_ref, floating_ip_record.address)
    end
    EmsRefresh.queue_refresh(self)
  rescue => err
    _log.error "vm=[#{name}], floating_ip=[#{floating_ip_id}], error: #{err}"
    raise MiqException::MiqOpenstackApiRequestError, parse_error_message_from_fog_response(err), err.backtrace
  end

  def compute_connection_options
    {:service => 'Compute', :tenant_name => cloud_tenant.name}
  end
end
