module ManageIQ::Providers
  module Openstack
    module RefreshParserCommon
      module HelperMethods
        def uniques(collection)
          unique_objs = []
          # caling uniq on a fog collection makes it lose
          # properties from fog that it will attempt to use
          # during iteration, resulting in an exeption.
          # to avoid that, turn it into an array first.
          unique_objs.concat(collection)
          # uniquify via identity if these are fog objects
          unique_objs.uniq!(&:identity) if (unique_objs.size > 0 && unique_objs[0].respond_to?(:identity))
          unique_objs
        end

        def openstack_admin?
          ::Settings.ems_refresh.openstack.try(:is_admin)
        end

        def cinder_admin?
          ::Settings.ems_refresh.cinder.try(:is_admin)
        end

        def openstack_network_admin?
          ::Settings.ems_refresh.openstack_network.try(:is_admin)
        end

        def openstack_heat_global_admin?
          ::Settings.ems_refresh.openstack.try(:heat).try(:is_global_admin)
        end

        def process_collection(collection, key, &block)
          @data[key] ||= []
          return if @options && @options[:inventory_ignore] && @options[:inventory_ignore].include?(key)
          # safe_call catches and ignores all Fog relation calls inside processing, causing allowed excon errors
          collection.each { |item| safe_call { process_collection_item(item, key, &block) } }
        end

        def process_collection_item(item, key)
          @data[key] ||= []

          uid, new_result = yield(item)

          @data[key] << new_result
          @data_index.store_path(key, uid, new_result)
          new_result
        end

        def safe_call
          # Safe call wrapper for any Fog call not going through handled_list
          yield
        rescue Excon::Errors::Forbidden => err
          # It can happen user doesn't have rights to read some tenant, in that case log warning but continue refresh
          _log.warn "Forbidden response code returned in provider: #{@manager&.hostname}. Message=#{err.message}"
          _log.warn err.backtrace.join("\n")
          nil
        rescue Excon::Errors::Unauthorized => err
          # It can happen user doesn't have rights to read some tenant, in that case log warning but continue refresh
          _log.warn "Unauthorized response code returned in provider: #{@manager&.hostname}. Message=#{err.message}"
          _log.warn err.backtrace.join("\n")
          nil
        rescue Excon::Errors::NotFound, Fog::Errors::NotFound => err
          # It can happen that some data do not exist anymore,, in that case log warning but continue refresh
          _log.warn "Not Found response code returned in provider: #{@manager&.hostname}. Message=#{err.message}"
          _log.warn err.backtrace.join("\n")
          nil
        rescue Excon::Errors::BadRequest => err
          # This can happen if stack resources are missing, among other reasons. In such a case log a warning but continue the refresh.
          _log.warn "Bad Request response code returned in provider: #{@manager&.hostname}. Message=#{err.message}"
          _log.warn err.backtrace.join("\n")
          nil
        end

        alias safe_get safe_call

        def safe_list(&block)
          safe_call(&block) || []
        end

        # TCOS troubleshooting: enable/disable via Settings flag.
        # Default: disabled. Only an explicit `true` activates the log.
        def self.tcos_debug_log_enabled?
          ::Settings.try(:ems_refresh).try(:openstack).try(:tcos_debug_log) == true
        end

        # TCOS troubleshooting: dedicated logger writing to its own file so the
        # analysis log stays clean. Path is overridable via env TCOS_REFRESH_LOG.
        # Default: <Rails.root>/log/tcos_refresh.log (or /tmp fallback).
        # Returns a null logger when Settings.ems_refresh.openstack.tcos_debug_log is false.
        def self.tcos_refresh_logger
          @tcos_refresh_logger ||= if tcos_debug_log_enabled?
                                     build_tcos_refresh_logger
                                   else
                                     Logger.new(File::NULL)
                                   end
        end

        def self.build_tcos_refresh_logger
          path = ENV['TCOS_REFRESH_LOG'].presence ||
                 (defined?(Rails) && Rails.root ? Rails.root.join('log', 'tcos_refresh.log').to_s : '/tmp/tcos_refresh.log')
          FileUtils.mkdir_p(File.dirname(path))
          # 50MB x 5 rotated files
          logger = Logger.new(path, 5, 50 * 1024 * 1024)
          logger.formatter = proc do |sev, time, _prog, msg|
            "#{time.utc.iso8601(3)} #{sev} pid=#{Process.pid} #{msg}\n"
          end
          logger.level = Logger::INFO
          logger
        end

        # Timing/structured log for refresh hot paths. Writes ONLY to the
        # dedicated TCOS refresh log (not evm.log). Grep `[TCOS-REFRESH]`.
        # Detect refresh kind: "target" if running inside a TargetCollection
        # (or a parser whose collector is a TargetCollection), otherwise "full".
        def tcos_refresh_kind
          probe = if respond_to?(:collector) && collector
                    collector
                  else
                    self
                  end
          probe.class.name.to_s.include?("TargetCollection") ? "target" : "full"
        end

        def tcos_time(label, desc: nil, **ctx, &block)
          ems_id = if respond_to?(:manager) && manager
                     manager.id
                   elsif respond_to?(:persister) && persister.respond_to?(:manager) && persister.manager
                     persister.manager.id
                   else
                     instance_variable_get(:@manager)&.id
                   end
          kind = tcos_refresh_kind
          ManageIQ::Providers::Openstack::RefreshParserCommon::HelperMethods.tcos_time(label, ems_id: ems_id, kind: kind, desc: desc, **ctx, &block)
        end

        # Module-level variant: callable from any class (provision, event
        # catcher, event target parser). Pass ems_id/kind explicitly.
        def self.tcos_time(label, ems_id: nil, kind: "provision", desc: nil, **ctx)
          return yield unless tcos_debug_log_enabled?
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          ctx_str = ctx.map { |k, v| "#{k}=#{v}" }.join(' ')
          desc_str = desc ? %( desc="#{desc}") : ''
          logger = tcos_refresh_logger
          logger.info("[TCOS-REFRESH] ems=#{ems_id} kind=#{kind} #{label} start#{desc_str} #{ctx_str}".rstrip)
          result = yield
          elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)
          size = result.respond_to?(:size) ? result.size : nil
          logger.info("[TCOS-REFRESH] ems=#{ems_id} kind=#{kind} #{label} end elapsed_ms=#{elapsed_ms}#{size ? " size=#{size}" : ''}#{desc_str} #{ctx_str}".rstrip)
          result
        rescue => err
          elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)
          tcos_refresh_logger.warn(
            "[TCOS-REFRESH] ems=#{ems_id} kind=#{kind} #{label} error elapsed_ms=#{elapsed_ms} err=#{err.class}: #{err.message}#{desc_str} #{ctx_str}".rstrip
          )
          raise
        end

        # Module-level fire-and-forget marker (no timing). For one-shot events
        # like event_received / target_built.
        def self.tcos_event(label, ems_id: nil, kind: "event", desc: nil, **ctx)
          return unless tcos_debug_log_enabled?
          ctx_str = ctx.map { |k, v| "#{k}=#{v}" }.join(' ')
          desc_str = desc ? %( desc="#{desc}") : ''
          tcos_refresh_logger.info("[TCOS-REFRESH] ems=#{ems_id} kind=#{kind} #{label}#{desc_str} #{ctx_str}".rstrip)
        end
      end
    end
  end
end
