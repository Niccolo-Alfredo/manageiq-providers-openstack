module ManageIQ::Providers::Openstack::CloudManager::Provision::Cloning
  def find_destination_in_vmdb(ems_ref)
    found = super
    if found
      ManageIQ::Providers::Openstack::RefreshParserCommon::HelperMethods.tcos_event(
        "provision.vm_visible_in_vmdb",
        :ems_id => source.try(:ems_id),
        :kind   => "provision",
        :desc   => "VM finalmente presente nel DB MiQ dopo il refresh",
        :vm_ems_ref => ems_ref,
        :vm_id      => found.id
      )
    end
    found
  rescue NoMethodError => ex
    # TODO: this should not be needed after we update refresh to not disconnect VmOrTemplate from EMS
    _log.debug("Unable to find Provison Source ExtmanagementSystem: #{ex}")
    _log.debug("Trying use attribute src_ems_id=#{options[:src_ems_id].try(:first)} instead.")
    vm_model_class.find_by(:ems_id => options[:src_ems_id].try(:first), :ems_ref => ems_ref)
  end

  def do_clone_task_check(clone_task_ref)
    connection_options = {:tenant_name => cloud_tenant.try(:name)}
    ManageIQ::Providers::Openstack::RefreshParserCommon::HelperMethods.tcos_time(
      "provision.do_clone_task_check",
      :ems_id => source.try(:ems_id),
      :kind   => "provision",
      :desc   => "Nova: polling stato VM in fase di creazione",
      :vm_ems_ref  => clone_task_ref,
      :tenant_name => cloud_tenant.try(:name)
    ) do
      source.with_provider_connection(connection_options) do |openstack|
        instance = if connection_options
                     openstack.servers.get(clone_task_ref)
                   else
                     openstack.handled_list(:servers).detect { |s| s.id == clone_task_ref }
                   end
        status   = instance.state.downcase.to_sym if instance.present?

        ManageIQ::Providers::Openstack::RefreshParserCommon::HelperMethods.tcos_event(
          "provision.status_poll",
          :ems_id => source.try(:ems_id),
          :kind   => "provision",
          :desc   => "stato corrente della VM dal polling Nova",
          :vm_ems_ref => clone_task_ref,
          :status     => status
        )

        if status == :error
          error_message = instance.fault["message"]
          raise MiqException::MiqProvisionError, "An error occurred while provisioning Instance #{instance.name}: #{error_message}"
        end
        return true if status == :active
        return false, status
      end
    end
  end

  def prepare_for_clone_task
    clone_options = super

    clone_options[:name]              = dest_name
    clone_options[:image_ref]         = source.ems_ref
    clone_options[:flavor_ref]        = instance_type.ems_ref
    clone_options[:availability_zone] = nil if dest_availability_zone.kind_of?(ManageIQ::Providers::Openstack::CloudManager::AvailabilityZoneNull)
    clone_options[:security_groups]   = security_groups.collect(&:ems_ref)
    clone_options[:nics]              = configure_network_adapters if configure_network_adapters.present?

    clone_options[:block_device_mapping_v2] = configure_volumes if configure_volumes.present?

    clone_options
  end

  def log_clone_options(clone_options)
    _log.info("Provisioning [#{source.name}] to [#{clone_options[:name]}]")
    _log.info("Source Image:                    [#{clone_options[:image_ref]}]")
    _log.info("Destination Availability Zone:   [#{clone_options[:availability_zone]}]")
    _log.info("Flavor:                          [#{clone_options[:flavor_ref]}]")
    _log.info("Guest Access Key Pair:           [#{clone_options[:key_name]}]")
    _log.info("Security Group:                  [#{clone_options[:security_groups]}]")
    _log.info("Network:                         [#{clone_options[:nics]}]")

    dump_obj(clone_options, "#{_log.prefix} Clone Options: ", $log, :info)
    dump_obj(options, "#{_log.prefix} Prov Options:  ", $log, :info, :protected => {:path => workflow_class.encrypted_options_field_regs})
  end

  def start_clone(clone_options)
    connection_options = {:tenant_name => cloud_tenant.try(:name)}
    
    if source.kind_of?(ManageIQ::Providers::Openstack::CloudManager::VolumeTemplate)
      # Boot from existing bootable volume
      clone_options.delete(:image_ref)
      clone_options[:block_device_mapping_v2] = [{
        :uuid => source.ems_ref,
        :source_type => "volume",
        :destination_type => "volume",
        :boot_index => 0,
        :delete_on_termination => false
      }]
      
      # Append additional volumes if configured
      if configure_volumes.present?
        additional_volumes = configure_volumes.map do |vol|
          vol.merge(:boot_index => vol[:boot_index] || -1)
        end
        clone_options[:block_device_mapping_v2].concat(additional_volumes)
      end
      
    elsif source.kind_of?(ManageIQ::Providers::Openstack::CloudManager::VolumeSnapshotTemplate)
      # Boot from volume snapshot, creating a new volume from the snapshot
      clone_options.delete(:image_ref)
      clone_options[:block_device_mapping_v2] = [{
        :uuid => source.ems_ref,
        :source_type => "snapshot",
        :destination_type => "volume",
        :boot_index => 0,
        :delete_on_termination => false
      }]
      
      # Append additional volumes if configured
      if configure_volumes.present?
        additional_volumes = configure_volumes.map do |vol|
          vol.merge(:boot_index => vol[:boot_index] || -1)
        end
        clone_options[:block_device_mapping_v2].concat(additional_volumes)
      end
    end
    
    ManageIQ::Providers::Openstack::RefreshParserCommon::HelperMethods.tcos_time(
      "provision.start_clone.nova_create_server",
      :ems_id => source.try(:ems_id),
      :kind   => "provision",
      :desc   => "Nova: chiamata POST /servers per creare la VM",
      :vm_name     => clone_options[:name],
      :flavor_ref  => clone_options[:flavor_ref],
      :image_ref   => clone_options[:image_ref],
      :tenant_name => cloud_tenant.try(:name)
    ) do
      source.with_provider_connection(connection_options) do |openstack|
        instance = openstack.servers.create(clone_options)
        ManageIQ::Providers::Openstack::RefreshParserCommon::HelperMethods.tcos_event(
          "provision.start_clone.created",
          :ems_id => source.try(:ems_id),
          :kind   => "provision",
          :desc   => "Nova ha restituito l'id della nuova VM",
          :vm_name    => clone_options[:name],
          :vm_ems_ref => instance.id
        )
        return instance.id
      end
    end
  rescue => e
    error_message = parse_error_message_from_fog_response(e)
    raise MiqException::MiqProvisionError, "An error occurred while provisioning Instance #{clone_options[:name]}: #{error_message}", e.backtrace
  end
end
