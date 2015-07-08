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

    def run
      Percy.logger.warn('WARN test')

      binding.pry

      Percy::Async.run_periodically(1) do
      end
    end

    def stats
      @stats ||= Percy::Stats.new
    end

    # Inserts a new process_snapshot job.
    def insert_snapshot_job(snapshot_id:, build_id:, subscription_id:, inserted_at: nil)
      stats.time('hub.methods.insert_snapshot_job') do
        keys = [
          'jobs:created:counter',
          'builds:active',
          "build:#{build_id}:subscription_id",
          "build:#{build_id}:jobs:new",
        ]
        job_data = "process_snapshot:#{snapshot_id}"
        args = [
          snapshot_id,
          build_id,
          subscription_id,
          inserted_at || Time.now.to_i,
          job_data,
        ]

        num_total_jobs = _run_script('insert_snapshot_job.lua', keys: keys, args: args)
        stats.gauge('hub.jobs.created.alltime', num_total_jobs)
        num_total_jobs
      end
    end

    # An infinite loop that continuously enqueues jobs in jobs:runnable when workers are idle.
    # This algorithm enforces subscription concurrency limits.
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
          build_id = redis.zrange('builds:active', index, index)[0]

          # We've iterated through all the active builds and successfully checked and/or enqueued
          # all potential jobs on all idle workers. Sleep for a small amount of time before checking
          # again to see if more locks or idle capacity is available.
          return 0.5 if !build_id

          # Grab the subscription associated to this build.
          subscription_id = redis.get("build:#{build_id}:subscription_id")

          # Enqueue as many jobs from this build as we can, until one of the exit conditions is met.
          while true do
            case _enqueue_next_job(build_id: build_id, subscription_id: subscription_id)
            when 1
              # A job was successfully enqueued from this build, there may be more.
              stats.increment('hub.jobs.enqueued')
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
              index += 1
              break
            when 'no_idle_worker'
              # No idle workers, sleep and restart this algorithm from the beginning. See above.
              stats.increment('hub.jobs.enqueuing.skipped.no_idle_worker')

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

        redis.set("machine:#{machine_id}:started_at", Time.now.to_i)
        redis.expire("machine:#{machine_id}:started_at", 86400)
        machine_id
      end
    end

    def register_worker(machine_id:)
      stats.time('hub.methods.register_worker') do
        worker_id = redis.incr('workers:counter')
        redis.zadd('workers:online', machine_id, worker_id)

        # Record the time between machine creation and worker registration.
        started_at = redis.get("machine:#{machine_id}:started_at")
        if started_at
          stats.histogram('hub.worker.startup_time', Time.now.to_i - started_at.to_i)
        end

        worker_id
      end
    end

    def _set_worker_idle(worker_id:)
      machine_id = redis.zscore('workers:online', worker_id)
      redis.zadd('workers:idle', machine_id, worker_id)
    end

    def _remove_worker_idle(worker_id:)
      redis.zrem('workers:idle', worker_id)
    end

    def _run_script(name, keys:, args: nil)
      script = File.read(File.expand_path("../hub/scripts/#{name}", __FILE__))
      redis.eval(script, keys: keys, argv: args)
    end
  end
end
