
module ManageIQ::Providers::Openstack::EventParserCommon
  def self.event_to_hash(event, ems_id)
    content = message_content(event)
    event_type = content["event_type"]
    payload = content.fetch("payload", {})

    log_header = "ems_id: [#{ems_id}] " unless ems_id.nil?
    _log.debug("(Target Refresh) - #{log_header}event: [#{event_type}]") if $log && $log.debug?

    event_hash = {
      :event_type => event_type,
      :source     => "OPENSTACK",
      :message    => payload,
      :timestamp  => content["timestamp"],
      :username   => content["_context_user_name"],
      :full_data  => event,
      :ems_id     => ems_id
    }

    yield(event_hash, payload) if block_given?

    event_hash
  end

  def self.message_content(event)
    # If this is an EmsEvent record, pull out the full_data
    event = event.full_data if event.respond_to?(:full_data)

    # Extract content - support both Symbol and String keys
    content = event.fetch(:content, nil) || event.fetch('content', {})

    # Look for oslo.message with both Symbol and String keys
    oslo_message = content[:'oslo.message'] || content['oslo.message']
    
    if oslo_message
      begin
        parsed = JSON.parse(oslo_message)
        _log.debug("(Target Refresh) - Oslo message parsed successfully for event: #{parsed['event_type']}") if $log && $log.debug?
        parsed
      rescue JSON::ParserError => e
        _log.warn("(Target Refresh) - Failed to parse Oslo message: #{e.message}") if $log
        {}
      end
    else
      content
    end
  end
end