require 'percy/hub'

module Percy
  class Hub
    class Worker
      HEARTBEAT_SLEEP_SECONDS = 1

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
          run_heartbeat_thread(worker_id: worker_id)

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
                  Percy.logger.error("[JOB_ERROR] #{e.class.name}: #{e.message}")
                  Percy.logger.error(e.backtrace.join("\n"))
                  failed = true
                end
              end
            else
              raise NotImplementedError.new("Unhandled job type: #{action}")
            end

            hub.worker_job_complete(worker_id: worker_id)
            if failed
              retried_job_id = hub.retry_job(job_id: job_id)
              Percy.logger.warn do
                "[worker:#{worker_id}] Job #{job_id} failed, retried as job #{retried_job_id}"
              end
            end
            hub.cleanup_job(job_id: job_id)

            Percy.logger.info do
              "[worker:#{worker_id}] Finished with job #{job_id} " +
              "(#{failed && 'failed' || 'success'})"
            end
          end
        rescue Exception => e
          # Fail! Probably a RedisTimeout. Don't do any cleanup/retry here, let hub cleanup after
          # this worker stops heartbeating. We do this so we can use the same cleanup/retry logic
          # for this soft failure as we do for hard failures, such as this process being SIGKILLd.
          Percy.logger.error("[WORKER_ERROR] #{e.class.name}: #{e.message}")
          Percy.logger.error(e.backtrace.join("\n"))
          raise e
        end
        # We do not cleanup the worker here, it is cleaned up by the hub itself. It is safe to leave
        # the worker "online" here because it is not idle, so no work will be scheduled to it.
      end
    end
  end
end


