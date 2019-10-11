require 'percy/hub'

module Percy
  class Hub
    class Worker
      HEARTBEAT_SLEEP_SECONDS = 2

      def hub
        @hub ||= Percy::Hub.new
      end

      def reset_hub
        @hub = nil
      end

      def run_heartbeat_thread(worker_id:)
        Thread.new do
          begin
            # Grab our own hub instance here, do not re-use the main hub instance so we can have our
            # own Redis connection.
            heartbeat_hub = Percy::Hub.new
            loop do
              heartbeat_hub.worker_heartbeat(worker_id: worker_id)
              sleep HEARTBEAT_SLEEP_SECONDS
            end
          rescue
            # Slightly dumb, but catch all exceptions (possibly Redis timeouts) and spawn a new
            # thread, then exit. Also sleep first, in case we are caught in a failure loop.
            sleep HEARTBEAT_SLEEP_SECONDS
            run_heartbeat_thread
          end
        end
      end

      def run(times: nil, &block)
        raise ArgumentError.new('block must be given') if !block_given?

        begin
          # Catch SIGINT and SIGTERM and trigger graceful shutdown after the job completes.
          heard_interrupt = false
          Signal.trap(:INT) do
            puts 'Quitting...'
            heard_interrupt = true
          end
          Signal.trap(:TERM) { heard_interrupt = true }

          Percy.logger.info("[worker] Registering...")
          worker_id = hub.register_worker(machine_id: ENV['PERCY_WORKER_MACHINE_ID'] || 1)
          heartbeat_thread = run_heartbeat_thread(worker_id: worker_id)

          Percy.logger.info("[worker:#{worker_id}] Ready! Waiting for jobs.")

          count = 0
          loop do
            # Exit if we heard a SIGTERM.
            break if heard_interrupt

            # Exit if we've exceeded times, but only if times is set (infinite loop otherwise).
            count += 1
            break if times && count > times

            hub.set_worker_idle(worker_id: worker_id)

            # If no job is scheduled, this will block for DEFAULT_WAIT_TIME seconds then return nil.
            # We handle these regular timeouts, clear our idle status, and then start over.
            job_id = hub.wait_for_job(worker_id: worker_id)
            if !job_id
              hub.clear_worker_idle(worker_id: worker_id)
              next
            end

            job_data = hub.get_job_data(job_id: job_id)
            Percy.logger.info("[worker:#{worker_id}] Running job:#{job_id} (#{job_data})")

            # Assumes a particular format for job_data, might need to be adapted for other jobs.
            action, action_id = job_data.split(':')
            action = action.to_sym

            options = {
              num_retries: hub.get_job_num_retries(job_id: job_id),
              hub_job_id: job_id,

              # Jobs can mutate this option to true to manually handle job lock releases.
              takeover_job_release: false,
            }
            case action
            when :process_comparison
              options[:comparison_id] = Integer(action_id)
              hub.stats.time('hub.jobs.completed.process_comparison') do
                yield(action, options)
              end
            else
              raise NotImplementedError.new("Unhandled job type: #{action}")
            end

            # Success!
            hub.worker_job_complete(worker_id: worker_id)
            hub.release_job(job_id: job_id) unless options[:takeover_job_release]

            Percy.logger.info do
              "[worker:#{worker_id}] Finished job:#{job_id} successfully (#{job_data})."
            end
          end
        rescue Exception => e
          hub.stats.increment('hub.jobs.failed')

          # Fail! Don't do any cleanup/retry here, let hub cleanup after this worker stops
          # heartbeating. We do this so we can use the same exact cleanup/retry logic for all
          # failures, soft or hard (such as being SIGKILLed).
          raise e
        ensure
          heartbeat_thread && heartbeat_thread.kill
        end
      end
    end
  end
end


