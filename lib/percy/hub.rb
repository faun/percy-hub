require 'pry'

require 'percy/async'
require 'percy/logger'
require 'percy/stats'
require 'percy/hub/version'
require 'percy/hub/redis_service'

module Percy
  class Hub
    include Percy::Hub::RedisService

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

        num_total_jobs = _run_script('insert_snapshot_job.lua', keys: keys, argv: args)
        stats.gauge('hub.jobs.created', num_total_jobs)
        num_total_jobs
      end
    end

    # An infinite loop that continuously enqueues jobs in jobs:runnable when workers are idle.
    # This algorithm enforces subscription concurrency limits.
    #
    # Overall algorithm: look at the first builds:active ID and enqueue as many jobs from the build
    # in to the global jobs:runnable list  as we can, limited by the concurrency limit of the
    # build's subscription and the number of idle workers available. If the concurrency limit for
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
    #    side-effect of delaying the start of newer builds and giving full capacity to each build
    #    once started. We would rather starve builds and have slow-to-start but fast-to-run builds,
    #    instead of uniformly making all builds slower to run. This also helps with the UI, because
    #    we can say something like “Hold on, the build hasn’t started yet.”
    # 3. We can modify scheduling priorities on the fly later.
    #
    # This algorithm is run as a hot loop and needs to be as fast as possible, because even if a
    # worker is available jobs won’t be run until this algorithm pushes them into jobs:runnable.
    def enqueue_jobs
      while true do
        num_active_builds = redis.zcard('builds:active')
        # Sleep and check again if there are no active builds.
        if num_active_builds == 0
          sleep 1
          next
        end

        # If not, all jobs are complete, delete the build ID from builds:active.
        _enqueue_next_job(build_id: build_id, subscription_id: subscription_id)
      end
    end

    # One step of the above algorithm. Enqueue jobs from a build, constrained by the above limits.
    def _enqueue_next_job(build_id:, subscription_id:)
      stats.time('hub.methods.enqueue_next_job') do
        keys = [
          "build:#{build_id}:jobs:new",
          "subscription:#{subscription_id}:locks:limit",
          "subscription:#{subscription_id}:locks:active",
          "jobs:runnable",
          "workers:idle",
        ]
        _run_script('enqueue_next_job.lua', keys: keys)
      end
    end

    def start_machine
      stats.time('hub.methods.start_machine') do
        machine_id = redis.incr('machines:count')
        stats.gauge('hub.machines.started', machine_id)

        redis.set("machine:#{machine_id}:started_at", Time.now.to_i)
        redis.expire("machine:#{machine_id}:started_at", 86400)
        machine_id
      end
    end

    def register_worker(machine_id:)
      stats.time('hub.methods.register_worker') do
        worker_id = redis.incr('workers:count')
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

    def _set_worker_running(worker_id:)
      redis.zrem('workers:idle', worker_id)
    end

    def _run_script(name, keys:, argv: nil)
      script = File.read(File.expand_path("../hub/scripts/#{name}", __FILE__))
      redis.eval(script, keys: keys, argv: argv)
    end
  end
end
