module ManageIQ::Providers::Openstack::CloudManager::Vm::Resize
  extend ActiveSupport::Concern

  included do
    supports :resize do
      if !ext_management_system
        _('The VM is not connected to a provider')
      elsif %w[ACTIVE SHUTOFF].exclude?(raw_power_state)
        _("The Instance cannot be resized, current state has to be active or shutoff.")
      else
        unsupported_reason(:control)
      end
    end
  end

  def raw_resize(options)
    _log.info("Reconfiguring VM [#{name}] with options: #{options.inspect}")
    
    # Detach port if requested
    detach_port_interface(options["detach_port_id"]) if options["detach_port_id"].present?

    # Attach network if requested
    attach_mode = options["attach_mode"]
    if attach_mode == "by_network" && options["attach_network_id"].present?
      attach_by_network(options["attach_network_id"])
    elsif attach_mode == "by_port" && options["port_network_id"].present?
      attach_by_port(options["port_network_id"], options["port_name"], options["port_fixed_ip"])
    end

    # Resize flavor if requested
    if options["flavor"].present?
      ext_management_system.with_provider_connection(compute_connection_options) do |service|
        service.resize_server(ems_ref, options["flavor"])
      end
      
      MiqQueue.put(:class_name  => self.class.name,
                   :expires_on  => Time.now.utc + 2.hours,
                   :instance_id => id,
                   :method_name => "raw_resize_finish")
    end
    
    _log.info("Reconfiguration completed successfully for VM [#{name}]")
  rescue => err
    _log.error("Reconfiguration failed for VM [#{name}]: #{err.message}")
    raise MiqException::MiqOpenstackApiRequestError, parse_error_message_from_fog_response(err), err.backtrace
  end

  # ============================================================================
  # DETACH BY PORT
  # ============================================================================
  
  def detach_port_interface(port_id)
    _log.info("Detaching port [#{port_id}] from VM [#{name}]")
    
    # Security check: verify port belongs to this VM
    port = network_ports.find_by(:ems_ref => port_id)
    raise "Port #{port_id} not found or not attached to this VM" unless port
    
    # Detach from VM
    ext_management_system.with_provider_connection(compute_connection_options) do |nova|
      nova.delete_os_interface(ems_ref, port_id)
    end
    
    # Delete port from Neutron
    ext_management_system.with_provider_connection(network_connection_options) do |neutron|
      neutron_port = neutron.ports.get(port_id)
      neutron_port.destroy if neutron_port
    end
    
    _log.info("Port [#{port_id}] detached and deleted successfully")
  rescue => err
    _log.error("Failed to detach port [#{port_id}]: #{err.message}")
    raise MiqException::MiqOpenstackApiRequestError, parse_error_message_from_fog_response(err), err.backtrace
  end

  # ============================================================================
  # ATTACH BY NETWORK (Auto-assign)
  # ============================================================================
  
  def attach_by_network(network_id)
    # Security check: verify network is accessible to VM's tenant
    network = find_network_for_tenant(network_id)
    raise "Network #{network_id} not found or not accessible to this tenant" unless network
    
    _log.info("Attaching VM [#{name}] to network [#{network.name}] with auto-assign IP")
    
    ext_management_system.with_provider_connection(compute_connection_options) do |nova|
      response = nova.create_os_interface(ems_ref, {:net_id => network_id})
      
      if response.body && response.body['interfaceAttachment']
        port_id = response.body['interfaceAttachment']['port_id']
        assigned_ips = response.body['interfaceAttachment']['fixed_ips']&.map { |ip| ip['ip_address'] }&.join(', ')
        _log.info("Interface attached successfully - Port: #{port_id}, IP: #{assigned_ips}")
      end
    end
  rescue => err
    _log.error("Failed to attach network [#{network_id}]: #{err.message}")
    raise MiqException::MiqOpenstackApiRequestError, parse_error_message_from_fog_response(err), err.backtrace
  end

  # ============================================================================
  # ATTACH BY PORT (Fixed IP)
  # ============================================================================
  
  def attach_by_port(network_id, port_name, fixed_ip)
    # Security check: verify network is accessible to VM's tenant
    network = find_network_for_tenant(network_id)
    raise "Network #{network_id} not found or not accessible to this tenant" unless network
    
    subnets = network.cloud_subnets.to_a
    subnet = find_subnet_for_ip(subnets, fixed_ip)
    
    _log.info("Creating port [#{port_name}] on network [#{network.name}] with IP [#{fixed_ip}]")
    
    port_id = nil
    port_obj = nil
    
    begin
      # Create port in Neutron
      ext_management_system.with_provider_connection(network_connection_options) do |neutron|
        port_obj = neutron.ports.create(
          :name => port_name,
          :network_id => network_id,
          :fixed_ips => [{
            'subnet_id' => subnet&.ems_ref,
            'ip_address' => fixed_ip
          }]
        )
        
        port_id = port_obj.id
      end
      
      # Attach port to VM
      ext_management_system.with_provider_connection(compute_connection_options) do |nova|
        nova.create_os_interface(ems_ref, {:port_id => port_id})
      end
      
      _log.info("Port [#{port_name}] created and attached successfully - ID: #{port_id}, IP: #{fixed_ip}")
      
    rescue => err
      # Cleanup: delete port if attach fails
      if port_obj
        begin
          port_obj.destroy
          _log.warn("Port [#{port_id}] cleaned up after failure")
        rescue => cleanup_err
          _log.error("Failed to cleanup port [#{port_id}]: #{cleanup_err.message}")
        end
      end
      _log.error("Failed to create/attach port [#{port_name}]: #{err.message}")
      raise MiqException::MiqOpenstackApiRequestError, parse_error_message_from_fog_response(err), err.backtrace
    end
  end

  # ============================================================================
  # SECURITY HELPERS
  # ============================================================================

  def find_network_for_tenant(network_id)
    # Find network that is accessible to the VM's tenant
    # This includes both private networks and shared networks
    networks = ext_management_system.cloud_networks.where(:ems_ref => network_id)
    networks = networks.where(cloud_tenant_id: cloud_tenant.id) if cloud_tenant
    networks.first
  end

  def find_subnet_for_ip(subnets, ip_address)
    require 'ipaddr'
    
    return nil if subnets.nil? || subnets.empty? || ip_address.blank?
    
    begin
      ip = IPAddr.new(ip_address)
      subnets.find { |subnet| IPAddr.new(subnet.cidr).include?(ip) }
    rescue IPAddr::InvalidAddressError
      nil
    end
  end
  
  # ============================================================================
  # UI FORM
  # ============================================================================
  
  def params_for_resize
    {
      :fields => [
        # Instance Type Section
        {
          :component => 'plain-text',
          :name      => 'instance_type_title',
          :label     => _('Instance Type'),
          :style     => {:fontWeight => 'bold', :fontSize => '16px', :marginBottom => '8px'}
        },
        {
          :component  => 'text-field',
          :name       => 'current_flavor',
          :id         => 'current_flavor',
          :label      => _('Current Flavor'),
          :isDisabled => true,
          :value      => flavor&.name_with_details || _('N/A')
        },
        {
          :component    => 'select',
          :name         => 'flavor',
          :id           => 'flavor',
          :label        => _('New Flavor'),
          :isRequired   => false,
          :includeEmpty => true,
          :options      => resize_form_options,
          :helperText   => _('Select a new flavor to resize the instance')
        },
        
        # Network Interfaces Section
        {
          :component => 'plain-text',
          :name      => 'network_interfaces_title',
          :label     => _('Network Interfaces'),
          :style     => {:fontWeight => 'bold', :fontSize => '16px', :marginTop => '20px', :marginBottom => '2px'}
        },
        
        # Attach Interface Subsection
        {
          :component => 'sub-form',
          :name      => 'attach_subsection',
          :title     => _('Attach Interface'),
          :fields    => [
            {
              :component => 'radio',
              :name      => 'attach_mode',
              :id        => 'attach_mode',
              :label     => _('Mode'),
              :options   => [
                {:label => _('By Network (auto-assign IP)'), :value => 'by_network'},
                {:label => _('By Port (specify IP)'), :value => 'by_port'}
              ]
            },
            
            # By Network Fields
            {
              :component    => 'select',
              :name         => 'attach_network_id',
              :id           => 'attach_network_id',
              :label        => _('Network'),
              :isRequired   => true,
              :includeEmpty => true,
              :options      => networks_available_for_attach,
              :helperText   => _('Auto-assign an IP from available pools'),
              :condition    => {
                :when => 'attach_mode',
                :is   => 'by_network'
              }
            },
            
            # By Port Fields
            {
              :component    => 'select',
              :name         => 'port_network_id',
              :id           => 'port_network_id',
              :label        => _('Network'),
              :isRequired   => true,
              :includeEmpty => true,
              :options      => networks_available_for_attach,
              :condition    => {
                :when => 'attach_mode',
                :is   => 'by_port'
              }
            },
            {
              :component  => 'text-field',
              :name       => 'port_name',
              :id         => 'port_name',
              :label      => _('Port Name'),
              :isRequired => true,
              :helperText => _('e.g., vm-port-1'),
              :condition  => {
                :when => 'attach_mode',
                :is   => 'by_port'
              }
            },
            {
              :component  => 'text-field',
              :name       => 'port_fixed_ip',
              :id         => 'port_fixed_ip',
              :label      => _('Fixed IP'),
              :isRequired => true,
              :helperText => _('IP within subnet range'),
              :condition  => {
                :when => 'attach_mode',
                :is   => 'by_port'
              }
            }
          ]
        },
        
        # Detach Interface Subsection
        {
          :component => 'sub-form',
          :name      => 'detach_subsection',
          :title     => _('Detach Interface'),
          :fields    => [
            {
              :component    => 'select',
              :name         => 'detach_port_id',
              :id           => 'detach_port_id',
              :label        => _('Port'),
              :isRequired   => false,
              :includeEmpty => true,
              :options      => ports_available_for_detach,
              :helperText   => _('Port will be detached and deleted')
            }
          ]
        }
      ]
    }
  end

  def networks_available_for_attach
    available = ext_management_system.cloud_networks
    # RBAC: Filter by VM's tenant (includes private + shared networks accessible to tenant)
    available = available.where(cloud_tenant_id: cloud_tenant.id) if cloud_tenant
    
    # Only show networks with allocation pools (required for auto-assign)
    available.select do |net|
      net.cloud_subnets.exists? && 
      net.cloud_subnets.any? { |s| s.allocation_pools.present? && s.allocation_pools.any? }
    end.map do |network|
      subnets = network.cloud_subnets
      cidrs = subnets.map(&:cidr).join(', ')
      
      {
        :label => "#{network.name} (#{cidrs})",
        :value => network.ems_ref
      }
    end
  end

  def ports_available_for_detach
    options = []
    
    # RBAC: Only show ports attached to this specific VM
    network_ports.each do |port|
      network = port.cloud_subnets.first&.cloud_network
      network_name = network ? network.name : 'Unknown'
      port_name = port.name.presence || port.ems_ref[0..7]
      
      # Get IP from CloudSubnetNetworkPort join table
      ip_address = if port.cloud_subnet_network_ports.any?
                     join_record = port.cloud_subnet_network_ports.first
                     join_record.respond_to?(:address) ? join_record.address : 'N/A'
                   else
                     'N/A'
                   end
      
      options << {
        :label => "#{port_name} - #{network_name} - #{ip_address}",
        :value => port.ems_ref
      }
    end
    
    options
  rescue => err
    _log.error("Failed to retrieve ports for detach: #{err.message}")
    []
  end

  def resize_form_options
    ext_management_system.flavors.map do |ems_flavor|
      # include only flavors with root disks at least as big as the instance's current root disk.
      next if flavor && (ems_flavor == flavor || ems_flavor.root_disk_size < flavor.root_disk_size)

      {:label => ems_flavor.name_with_details, :value => ems_flavor.ems_ref}
    end.compact
  end

  # ============================================================================
  # HELPERS
  # ============================================================================

  def network_connection_options
    {:service => 'Network', :tenant_name => cloud_tenant.name}
  end

  def compute_connection_options
    {:service => 'Compute', :tenant_name => cloud_tenant.name}
  end

  def validate_resize_confirm
    raw_power_state == 'VERIFY_RESIZE'
  end

  def raw_resize_confirm
    ext_management_system.with_provider_connection(compute_connection_options) do |service|
      service.confirm_resize_server(ems_ref)
    end
  rescue => err
    _log.error("vm=[#{name}], error: #{err}")
    raise MiqException::MiqOpenstackApiRequestError, parse_error_message_from_fog_response(err), err.backtrace
  end

  def raw_resize_finish
    refresh_ems
    raise MiqException::MiqQueueRetryLater.new(:deliver_on => Time.now.utc + 1.minute) unless validate_resize_confirm
    raw_resize_confirm
  end

  def validate_resize_revert
    raw_power_state == 'VERIFY_RESIZE'
  end

  def raw_resize_revert
    ext_management_system.with_provider_connection(compute_connection_options) do |service|
      service.revert_resize_server(ems_ref)
    end
  rescue => err
    _log.error("vm=[#{name}], error: #{err}")
    raise MiqException::MiqOpenstackApiRequestError, parse_error_message_from_fog_response(err), err.backtrace
  end
end
