require 'pry'

require 'percy/async'
require 'percy/logger'
require 'percy/stats'
require 'percy/hub/version'
require 'percy/hub/redis_service'

module Percy
  class Hub
    include Percy::Hub::RedisService

    # NOTE: many of the algorithms below rely on Lua scripts, not for convenience, but because
    # Lua scripts are executed atomically and serially block all Redis operations, so we can treat
    # each script as being its own "transaction".

    def run(command:)
      case command.to_sym
      when :queuer
        Percy.logger.info('[hub] Waiting for jobs to enqueue...')
        enqueue_jobs
      when :scheduler
        schedule_jobs
      when :insert_test_job
        subscription_id = Random.rand(1..2)
        case subscription_id
        when 1
          snapshot_id = Random.rand(1..1000)
          build_id = Random.rand(1..3)
        when 2
          build_id = Random.rand(10..13)
          snapshot_id = Random.rand(1001..2000)
        end
        insert_snapshot_job(
          snapshot_id: snapshot_id,
          build_id: build_id,
          subscription_id: subscription_id,
        )
      end
    end

    def stats
      @stats ||= Percy::Stats.new
    end

    # Inserts a new process_snapshot job.
    def insert_snapshot_job(snapshot_id:, build_id:, subscription_id:, inserted_at: nil)
      stats.time('hub.methods.insert_snapshot_job') do
        # Increment the global jobs counter.
        job_id = redis.incr('jobs:counter')

        keys = [
          'jobs:counter',
          'builds:active',
          "build:#{build_id}:subscription_id",
          "build:#{build_id}:jobs:new",
          "job:#{job_id}:data",
          "job:#{job_id}:subscription_id",
        ]
        job_data = "process_snapshot:#{snapshot_id}"
        args = [
          job_id,
          snapshot_id,
          build_id,
          subscription_id,
          inserted_at || Time.now.to_i,
          job_data,
        ]

        _run_script('insert_snapshot_job.lua', keys: keys, args: args)
        stats.gauge('hub.jobs.created.alltime', job_id)
        Percy.logger.info(
          "[hub] Inserted job #{job_id}, snapshot #{snapshot_id}, build #{build_id}, subscription #{subscription_id}")
        job_id
      end
    end

    # An infinite loop that continuously enqueues jobs and enforces subscription concurrency limits.
    def enqueue_jobs
      while true do
        sleeptime = _enqueue_jobs
        stats.count('hub.jobs.enqueuing.sleeptime', sleeptime)
        sleep sleeptime
      end
    end

    # A single iteration of the enqueue_jobs algorithm which returns the amount of time to sleep
    # until it should be run again. After running this method, as many jobs as can be enqueued from
    # all active builds will be enqueued.
    #
    # Overall algorithm: grab the first builds:active ID and pop as many jobs from the build
    # in to the global jobs:runnable list as we can, limited by the concurrency limit of the
    # build's subscription AND by the number of idle workers available. If the concurrency limit for
    # the subscription is hit, iterate to the next builds:active ID. If there are no idle workers,
    # sleep and restart the algorithm at the beginning.
    #
    # If no workers are idle, jobs are not enqueued and we sleep and restart scheduling from the
    # beginning. This gives us three properties we want:
    # 1. Job scheduling is decoupled from machine allocation/deallocation, so that we can uniformly
    #    distribute load to the current online capacity. If more capacity comes up, it will be
    #    immediately utilized (whereas if we queued a bunch of jobs onto particular workers, new
    #    capacity would remain idle because jobs would not balance over to new workers).
    # 2. Builds at the front of the queue are always given scheduling preference when capacity
    #    becomes available, since we restart the algorithm from the beginning if no workers are
    #    available. In a resource-constrained environment when concurrency demands have exceeded
    #    supply and new capacity is still spinning up, this scheduling preference has the desirable
    #    side-effect of delaying the start of newer builds and giving capacity to each build
    #    once started. We would rather starve builds and have slow-to-start but fast-to-run builds,
    #    instead of uniformly making all builds slower to run. This also helps with the UI, because
    #    we can say something like “Hold on, the build hasn’t started yet.”
    # 3. We can modify scheduling priorities on the fly later.
    #
    # This algorithm needs to be as fast as possible because it is the core algorithm used to
    # allocate jobs to available capacity while enforcing subscription concurrency limits.
    def _enqueue_jobs
      stats.time('hub.methods._enqueue_jobs') do
        num_active_builds = redis.zcard('builds:active')

        # Sleep and check again if there are no active builds.
        if num_active_builds == 0
          return 2
        end

        index = 0
        while true do
          build_id = redis.zrange('builds:active', index, index).first

          # We've iterated through all the active builds and successfully checked and/or enqueued
          # all potential jobs for all idle workers. Sleep for a small amount of time before
          # checking again to see if locks have been released or idle capacity is available.
          return 0.5 if !build_id

          # Grab the subscription associated to this build.
          subscription_id = redis.get("build:#{build_id}:subscription_id")

          # Enqueue as many jobs from this build as we can, until one of the exit conditions is met.
          while true do
            job_result = _enqueue_next_job(build_id: build_id, subscription_id: subscription_id)
            case job_result
            when 1
              # A job was successfully enqueued from this build, there may be more.
              # Immediately move to the next iteration and do not sleep.
              stats.increment('hub.jobs.enqueued')
              Percy.logger.info("[hub] Enqueued job from build #{build_id}")
              next
            when 0
              # No jobs were available, move on to the next build and trigger cleanup of this build.
              stats.increment('hub.jobs.enqueuing.skipped.build_empty')
              index += 1
              remove_active_build(build_id: build_id)
              break
            when 'hit_lock_limit'
              # Concurrency limit hit, move on to the next build.
              stats.increment('hub.jobs.enqueuing.skipped.hit_lock_limit')
              Percy.logger.info("[hub] Concurrency limit hit, skipping jobs from #{build_id}.")
              index += 1
              break
            when 'no_idle_worker'
              # No idle workers, sleep and restart this algorithm from the beginning. See above.
              stats.increment('hub.jobs.enqueuing.skipped.no_idle_worker')
              Percy.logger.info("[hub] Could not enqueue jobs, no idle workers available.")

              # Sleep for this amount of time waiting for a worker before checking again.
              return 1
            end
          end
        end
      end
    end

    # One step of the above algorithm. Enqueue jobs from a build, constrained by the above limits.
    def _enqueue_next_job(build_id:, subscription_id:)
      stats.time('hub.methods._enqueue_next_job') do
        keys = [
          "build:#{build_id}:jobs:new",
          "subscription:#{subscription_id}:locks:limit",
          "subscription:#{subscription_id}:locks:active",
          'jobs:runnable',
          'workers:idle',
        ]
        _run_script('enqueue_next_job.lua', keys: keys)
      end
    end

    def remove_active_build(build_id:)
      stats.time('hub.methods.remove_active_build') do
        Percy.logger.info("[hub] Removing build #{build_id}.")
        keys = [
          'builds:active',
          "build:#{build_id}:subscription_id",
          "build:#{build_id}:jobs:new"
        ]
        args = [
          build_id,
        ]
        _run_script('remove_active_build.lua', keys: keys, args: args) > 0
      end
    end

    def start_machine
      stats.time('hub.methods.start_machine') do
        machine_id = redis.incr('machines:counter')
        stats.gauge('hub.machines.started', machine_id)

        # TODO: actually start machine.

        redis.set("machine:#{machine_id}:started_at", Time.now.to_i)
        redis.expire("machine:#{machine_id}:started_at", 86400)
        machine_id
      end
    end

    def register_worker(machine_id:)
      stats.time('hub.methods.register_worker') do
        worker_id = redis.incr('workers:counter')
        redis.zadd('workers:online', machine_id, worker_id)
        _record_worker_stats

        # Record the time between machine creation and worker registration.
        started_at = redis.get("machine:#{machine_id}:started_at")
        if started_at
          stats.histogram('hub.workers.startup_time', Time.now.to_i - started_at.to_i)
        end

        worker_id
      end
    end

    # Removes a worker and associated keys, and pushes any orphaned jobs into jobs:orphaned.
    # Should be called when worker is shutdown.
    def remove_worker(worker_id:)
      stats.time('hub.methods.remove_worker') do
        Percy.logger.info("[hub] Removing worker #{worker_id}.")
        keys = [
          'workers:online',
          'workers:idle',
          "worker:#{worker_id}:runnable",
          "worker:#{worker_id}:running",
          'jobs:orphaned',
        ]
        args = [
          worker_id,
        ]
        result = _run_script('remove_worker.lua', keys: keys, args: args)
        _record_worker_stats
        result
      end
    end

    # Schedules jobs from jobs:runnable onto idle workers.
    #
    def schedule_jobs
      while true do
        sleep _schedule_next_job
      end
    end

    # A single iteration of the schedule_jobs algorithm which blocks and waits for a job in
    # jobs:runnable, then schedules it on an idle worker.
    #
    # Preference is given to idle workers with lower machine IDs. The machine-number score ensures
    # that we preference scheduling to idle workers on the oldest machines, so when demand lessens
    # newer machines will become more uniformly idle and be able to be shutdown. If we simply picked
    # a random available worker from any machine, we could easily keep triggering many machines to
    # stay up for a limited demand.
    #
    # This preference will not have adverse effects on utilization since workers can only have one
    # job at a time, so load will evenly spread over all the workers and then block. If there are
    # enough jobs being pumped into jobs:runnable, all workers on all machines will be utilized
    # at maximum, but when load slows workers will become idle from newest to oldest.
    #
    # @return [Integer] The amount of time to sleep until the next iteration, usually 0.
    def _schedule_next_job
      # Block and wait to pop a job from runnable to scheduling.
      Percy.logger.info('[hub] Waiting for jobs to schedule...')
      job_id = redis.brpoplpush("jobs:runnable", "jobs:scheduling")

      # Find an idle worker to schedule the job on.
      worker_id = redis.zrange('workers:idle', 0, 0).first
      if !worker_id
        # There are no idle workers. This should not happen because enqueue_jobs should ensure
        # that jobs are only pushed into jobs:runnable if there are idle workers, but we can handle
        # the case here by sleeping for 1 second and retrying.
        #
        # Push the job back into jobs:runnable. Unfortunately this goes to the end of the
        # jobs:runnable list and there is no alternative lpoprush, but that's ok here.
        redis.rpoplpush("jobs:scheduling", "jobs:runnable")
        return 1
      end

      # Immediately remove the worker from the idle list.
      _clear_worker_idle(worker_id: worker_id)

      # Non-blocking push the job from jobs:scheduling to the selected worker's runnable queue.
      redis.rpoplpush('jobs:scheduling', "worker:#{worker_id}:runnable")

      Percy.logger.info("[hub] Scheduled job #{job_id} on worker #{worker_id}")

      return 0
    end

    # Block and wait for the next runnable job for a specific worker.
    #
    # @return [nil, String]
    #   - `nil` when the operation timed out
    #   - the job data otherwise
    def wait_for_job(worker_id:)
      result = redis.brpoplpush("worker:#{worker_id}:runnable", "worker:#{worker_id}:running")
      return if !result
      # redis.set("worker:#{worker_id}:last")

      result
    end

    def get_job_data(job_id:)
      redis.get("job:#{job_id}:data")
    end

    # Marks the worker's current job as complete and releases the subscription lock.
    #
    # @return [Integer]
    #   - `-1` when there was no job to mark complete
    #   - the job ID otherwise
    def worker_job_complete(worker_id:)
      job_id = redis.rpop("worker:#{worker_id}:running")
      if !job_id
        return -1
      end

      # Release the subscription lock that was added by enqueue_jobs.
      subscription_id = redis.get("job:#{job_id}:subscription_id")
      redis.decr("subscription:#{subscription_id}:locks:active")

      stats.increment('hub.jobs.completed')
      job_id
    end

    def cleanup_job(job_id:)
      stats.time('hub.methods.cleanup_job') do
        redis.del("job:#{job_id}:data")
        redis.del("job:#{job_id}:subscription_id")
      end
    end

    def set_worker_idle(worker_id:)
      machine_id = redis.zscore('workers:online', worker_id)
      redis.zadd('workers:idle', machine_id, worker_id)
      _record_worker_stats
    end

    def _clear_worker_idle(worker_id:)
      redis.zrem('workers:idle', worker_id)
      _record_worker_stats
    end

    def _record_worker_stats
      # Record an exact count of how many workers are online and idle.
      stats.gauge('hub.workers.online', redis.zcard('workers:online'))
      stats.gauge('hub.workers.idle', redis.zcard('workers:idle'))
      true
    end

    def _run_script(name, keys:, args: nil)
      script = File.read(File.expand_path("../hub/scripts/#{name}", __FILE__))
      redis.eval(script, keys: keys, argv: args)
    end
  end
end
