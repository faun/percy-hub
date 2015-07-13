require 'percy/hub'

module Percy
  class Hub
    class Worker
      def run(times: nil, &block)
        raise ArgumentError.new('block must be given') if !block_given?

        hub = Percy::Hub.new

        # Catch SIGINT and SIGTERM and trigger gracefully shutdown after the job completes.
        heard_interrupt = false
        Signal.trap(:INT) do
          puts 'Quitting...'
          heard_interrupt = true
        end
        Signal.trap(:TERM) { heard_interrupt = true }

        Percy.logger.info("[worker] Registering...")
        worker_id = hub.register_worker(machine_id: ENV['PERCY_WORKER_MACHINE_ID'] || 1)

        Percy.logger.info("[worker:#{worker_id}] Ready! Waiting for jobs.")

        count = 0
        loop do
          # Every time a job completes or wait_for_job times out (regularly), check if we should stop.
          break if heard_interrupt

          # Exit if we've exceeded times, but only if times is set (infinite loop otherwise).
          count += 1
          break if times && count > times

          hub.set_worker_idle(worker_id: worker_id)
          job_id = hub.wait_for_job(worker_id: worker_id)

          # Handle regular timeouts from wait_for_job and restart.
          next if !job_id

          Percy.logger.info("[worker:#{worker_id}] Running job #{job_id}")
          job_data = hub.get_job_data(job_id: job_id)

          # Assumes a particular format for job_data, might need to be adapted for other jobs.
          action, action_id = job_data.split(':')
          action = action.to_sym
          action_id = Integer(action_id)

          failed = false
          case action
          when :process_snapshot
            options = {snapshot_id: action_id}
            hub.stats.time('hub.jobs.completed.process_snapshot') do
              begin
                yield(action, options)
              rescue Exception => e
                # Capture and ignore all errors.
                Percy.logger.error("[WORKER_ERROR] #{e.class.name}: #{e.message}")
                Percy.logger.debug(e.backtrace.join("\n"))
                failed = true
              end
            end
          else
            raise NotImplementedError.new("Unhandled job type: #{action}")
          end

          hub.worker_job_complete(worker_id: worker_id)
          if failed
            # Insert the job to be retried immediately if failed.
            # TODO(fotinakis): this is slightly dangerous and might cause infinite failure loops,
            # though they'd still be subscription rate limited. Consider adding counts and delays.
            hub.retry_job(job_id: job_id)
          end
          hub.cleanup_job(job_id: job_id)
          Percy.logger.info("[worker:#{worker_id}] Finished job #{job_id}")
        end

        # Shutdown gracefully.
        Percy.logger.info("[worker:#{worker_id}] Shutting down worker...")
        hub.remove_worker(worker_id: worker_id)
      end
    end
  end
end


