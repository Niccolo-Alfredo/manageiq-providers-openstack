class ManageIQ::Providers::Openstack::StorageManager::CinderManager::EventTargetParser
  attr_reader :ems_event

  # @param ems_event [EmsEvent] EmsEvent object to be parsed to derive an object to be refreshed
  def initialize(ems_event)
    @ems_event = ems_event
  end

  # Parses all targets present in the EmsEvent given in the initializer
  # @return [Array] Array of InventoryRefresh::Target objects
  def parse
    parse_ems_event_targets(ems_event)
  end

  private

  # Parses list of InventoryRefresh::Target(s) out of the given EmsEvent
  #
  # @param ems_event [EmsEvent] EmsEvent object
  # @return [Array] Array of InventoryRefresh::Target objects
  def parse_ems_event_targets(ems_event)
    $log.info("(Target Refresh) - MIQ(#{self.class.name}) Processing storage event: #{ems_event.event_type}") if $log

    target_collection = InventoryRefresh::TargetCollection.new(
      :manager => ems_event.ext_management_system.parent_manager,
      :event   => ems_event
    )

    # Extract tenant_id once and make it available to all methods
    @tenant_id = event_payload['tenant_id'] || 
                 event_payload['project_id'] || 
                 event_payload.dig('initiator', 'project_id')

    if ems_event.event_type.start_with?("volume.")
      collect_volume_references!(target_collection)
    elsif ems_event.event_type.start_with?("snapshot.")
      collect_snapshot_references!(target_collection)
    elsif ems_event.event_type.start_with?("backup.")
      collect_backup_references!(target_collection)
    end

    $log.info("(Target Refresh) - MIQ(#{self.class.name}) Collected #{target_collection.targets.count} target(s) for #{ems_event.event_type}") if $log
    target_collection.targets
  end

  def collect_volume_references!(target_collection)
    return unless @tenant_id
    
    volume_id = event_payload['volume_id']
    return unless volume_id
    
    is_start_event = ems_event.event_type.include?('.start')
    
    # Always add cloud_volumes target
    add_target(target_collection, :cloud_volumes, volume_id, :tenant_id => @tenant_id)
    
    # Add volume_templates target for all events except .start
    # This includes: create.end, delete.end, update.end, attach.end, detach.end, etc.
    # Skip .start events as volume is not ready yet
    add_target(target_collection, :volume_templates, volume_id, :tenant_id => @tenant_id) unless is_start_event
  end

  def collect_snapshot_references!(target_collection)
    return unless @tenant_id
    
    snapshot_id = event_payload['snapshot_id']
    volume_id = event_payload['volume_id']
    
    return unless snapshot_id
    
    # Always add cloud_volume_snapshots target
    add_target(target_collection, :cloud_volume_snapshots, snapshot_id, :tenant_id => @tenant_id)
    
    # Add parent volume target if available
    add_target(target_collection, :cloud_volumes, volume_id, :tenant_id => @tenant_id) if volume_id
    
    # Add volume_snapshot_templates target for all snapshot events
    # This includes: create.start, create.end, delete.start, delete.end, update.end
    add_target(target_collection, :volume_snapshot_templates, snapshot_id, :tenant_id => @tenant_id) if volume_id
  end

  def collect_backup_references!(target_collection)
    return unless @tenant_id
    
    backup_id = event_payload['backup_id']
    
    if backup_id
      # Prefer specific backup targeting when ID is available
      add_target(target_collection, :cloud_volume_backups, backup_id, :tenant_id => @tenant_id)
    else
      # Fallback for older Panko notifications without backup_id
      add_target(target_collection, :cloud_volume_backups, nil, :tenant_id => @tenant_id)
    end
    
    # Backups are always related to a parent volume
    volume_id = event_payload['volume_id']
    add_target(target_collection, :cloud_volumes, volume_id, :tenant_id => @tenant_id) if volume_id
  end

  def parsed_targets(target_collection = {})
    target_collection.select { |_target_class, references| references[:manager_ref].present? }
  end

  def add_target(target_collection, association, ref, options = {})
    target_collection.add_target(:association => association, :manager_ref => {:ems_ref => ref}, :options => options)
  end

  def event_payload
    @event_payload ||= ManageIQ::Providers::Openstack::EventParserCommon.message_content(ems_event).fetch('payload', {})
  end
end