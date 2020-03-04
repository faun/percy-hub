# Percy::Hub
#
# The master coordinator.
#
# NOTES:
#
# - Redis data is in-memory and expensive, so every variable should be strictly accounted for
#   and cleaned up when no longer needed.
# - Many of the algorithms below rely on Lua scripts, not for convenience, but because
#   Lua scripts are executed serially and block other Redis operations, so we can treat each script
#   as a weak "transaction" (even though it's not technically atomic) for certain uses.
#
# REDIS KEYS:
#
# builds:active [Sorted Set]
#
# - All the currently active build IDs that should be checked for
#   scheduling of their jobs, scored by insertion timestamp. If the build already exists in this
#   set when a next snapshot job is inserted, the insertion time score is re-used and remains
#   the same. This has the side-effect of keeping active builds that send snapshots quickly at
#   the front of the queue. This also means builds are not necessarily executed in order, if a
#   build is slow to send snapshots it may not remain at the front of the priority list.
# - Items added in insert_job.
# - Deleted by remove_active_build which is called when the last job is popped by enqueue_jobs.
#   The last job is simply the last we've received, not necessarily the last ever for the build.
#
# global:locks:limit [Integer]
#
# - The global concurrency limit across all subscriptions.
# - Set dynamically by the API as scaling changes. Defaults to 10000 if not set.
# - Never deleted.
#
# global:locks:claimed [Sorted Set]
#
# - The job IDs that are currently holding locks, scored by insertion timestamp.
#   The size of this is weakly limited by global:locks:limit.
# - Added by enqueue_jobs.
# - Items removed by release_job, or by _reap_expired_locks.
#   Once this key exists, it is never deleted.
#
# subscription:<id>:locks:limit [Integer]
#
# - The concurrency limit of the subscription. Managed by the API app, not Hub.
# - Added by the main app when subscriptions change. Defaults to 2 if not set.
# - Never deleted.
#
# subscription:<id>:locks:claimed [Sorted Set]
#
# - The job IDs that are currently holding locks, scored by insertion timestamp.
#   This is limited to the subscription concurrency_limit.
# - Added by enqueue_jobs.
# - Items removed by release_job, or by _reap_expired_locks.
#   Once this key exists, it is never deleted.
#
# subscription:<id>:usage:<year>:<month>:counter [Integer]
#
# - How many snapshots have been successfully added per year/month tied to a subscription.
#   The enforcement of limits is done by the Percy API, not Hub.
# - Incremented by increment_monthly_usage.
# - Never deleted. TODO: cleanup after some period of time.
#
# build:<id>:subscription_id [Integer]
#
# - Subscription ID so we can get from a build to its subscription limit and active locks.
# - Added on every insert_job call.
# - Deleted by remove_active_build which is called when the last job is popped by enqueue_jobs.
#
# build:<id>:jobs:new [List]
#
# - List of jobs that have not been enqueued or run yet.
# - Added on every insert_job call.
# - Deleted by remove_active_build which is called when the last job is popped by enqueue_jobs.
#
# jobs:created:counter [Integer]
#
# - An all-time counter of jobs created, used as IDs for jobs.
# - Incremented by insert_job.
# - Never deleted. Limited to 9,223,372,036,854,775,807 jobs, hah!
#
# jobs:completed:counter [Integer]
#
# - An all-time counter of jobs completed (without regard to success).
# - Incremented on each release_job call.
# - Never deleted.
#
# jobs:runnable [List]
#
# - A global list of enqueued job IDs that can and should be immediately scheduled on a worker.
#   This list acts as a buffer/interface between enqueuing a job and actually scheduling it to
#   run on a specific worker.
# - Items added by enqueue_jobs.
# - Items popped by schedule_jobs.
#
# jobs:orphaned [List]
#
# - A list of orphaned job IDs to retry. Created if a worker died hard and did not cleanup.
# - Items added by remove_worker.
# - Items popped by reap_workers.
#
# jobs:scheduling [List]
#
# - An intermediate list of job IDs that are currently being scheduled by schedule_jobs.
#   This exists so we can atomically block and pop from jobs:runnable to this list without
#   needing to find an idle worker yet, then we immediately pop the job from this list to the
#   worker's runnable list.
# - Items added by schedule_jobs.
# - Items popped by schedule_jobs.
#
# job:<id>:data [String]
#
# - Arbitrary job data. Right now just "process_comparison:<id>".
# - Added on every insert_job call.
# - Deleted by release_job, which should be called by the worker when successful or giving up.
#
# job:<id>:subscription_id [Integer]
#
# - The subscription ID of the build associated to this job.
# - Added on every insert_job call.
# - Deleted by release_job, which should be called by the worker when successful or giving up.
#
# job:<id>:build_id [Integer]
#
# - The job's build ID.
# - Added on every insert_job call.
# - Deleted by release_job, which should be called by the worker when successful or giving up.
#
# job:<id>:num_retries [Integer]
#
# - The number of times this job has been retried.
# - Set to zero by the first insert_job call, incremented when retry_job calls insert_job.
# - Deleted by release_job, which should be called by the worker when successful or giving up.
#
# workers:created:counter [Integer]
#
# - The all-time count of workers created.
# - Incremented by register_worker.
# - Never deleted.
#
# workers:online [Sorted Set]
#
# - All the currently online workers, scored by machine ID.
# - Items added by register_worker.
# - Items deleted by remove_worker.
#
# worker:<id>:runnable
# - Worker-specific job ID that has been scheduled.
# - Items are added by _schedule_next_job when the worker has been identified as idle.
# - Items are moved from runnable to running by wait_for_job.
#
# worker:<id>:running
# - Worker-specific job ID that is running.
# - Items are moved from worker:<id>:runnable to running by wait_for_job.
# - Items are removed by worker_job_complete or remove_worker.
#
# workers:idle [Sorted Set]
#
# - All the currently idle workers, scored by machine ID. Jobs are scheduled on the lowest
#   ranked worker that is idle.
# - Items added by set_worker_idle (called by the worker).
# - Items deleted by schedule_jobs after job is scheduled, and permanently by remove_worker.
#
# workers:heartbeat [Sorted Set]
#
# - All the currently idle workers, scored by the timestamp of the last heartbeat.
# - Items added by worker_heartbeat (run every second by each worker).
# - Item scores are read by reap_workers. If a score is lagging behind in time, it is a signal
#   that the worker is no longer actually online and was not shutdown properly.
# - Items deleted by remove_worker, called by reap_workers.
#
# machines:created:counter [Integer]
#
# - The all-time count of machines created.
# - Incremented and used by start_machine.
# - Never deleted.
#
# machine:<id>:started_at [Integer]
#
# - The time this machine was started. When a worker starts, it uses this to record a histogram
#   statistic of how long it took from machine allocation to worker ready.
# - Added by start_machine.
# - Deleted by setting to EXPIRE 24 hours after being set.

require 'percy/logger'
require 'percy/stats'
require 'percy/hub/version'
require 'percy/hub/redis_service'

module Percy
  class Hub
    include Percy::Hub::RedisService

    # The default blocking time for certain "hot" loops that wait on BRPOPLPUSH calls.
    DEFAULT_TIMEOUT_SECONDS = 5

    # The number of seconds since a worker last sent a heartbeat before we reap it.
    # This is also effectively the amount of time before a dead job will be rescheduled,
    # since dead workers do not cleanup their jobs.
    DEFAULT_WORKER_REAP_SECONDS = 25 # allow 2 workers heartbeat failures before reaping

    # The amount of time a build will remain in builds:active before being allowed to time out
    # and being cleaned up. Default: 5 hours
    DEFAULT_ACTIVE_BUILD_TIMEOUT_SECONDS = 18000

    # The amount of time an orphaned lock will remain claimed before being released.
    # Default: 1 hour.
    DEFAULT_EXPIRED_LOCK_TIMEOUT_SECONDS = 3600

    # The default subscription locks limit if unset.
    DEFAULT_SUBSCRIPTION_LOCKS_LIMIT = 2

    # The number of seconds between lock reaping passes.
    DEFAULT_LOCK_REAP_SECONDS = 10

    attr_accessor :_heard_interrupt

    class Error < Exception; end
    class DeadWorkerError < Percy::Hub::Error; end

    def run(command:)
      case command.to_sym
      when :enqueue_jobs
        enqueue_jobs
      when :schedule_jobs
        schedule_jobs
      when :reap_workers
        reap_workers
      when :reap_locks
        reap_locks
      end
    end

    private def script_shas
      @script_shas ||= {}
    end

    def stats
      @stats ||= Percy::Stats.new
    end

    def get_global_locks_limit
      Integer(redis.get("global:locks:limit") || 10000)
    end

    def set_global_locks_limit(limit:)
      limit = Integer(limit)  # Sanity check.
      redis.set("global:locks:limit", limit)
    end

    def get_subscription_locks_limit(subscription_id:)
      Integer(redis.get("subscription:#{subscription_id}:locks:limit") || 2)
    end

    def get_subscription_locks_claimed(subscription_id:)
      Integer(redis.zcard("subscription:#{subscription_id}:locks:claimed") || 0)
    end

    def set_subscription_locks_limit(subscription_id:, limit:)
      limit = Integer(limit)  # Sanity check.
      redis.set("subscription:#{subscription_id}:locks:limit", limit)
    end

    # Inserts a new job.
    def insert_job(job_data:, build_id:, subscription_id:, inserted_at: nil, num_retries: nil)
      # Sanity checks to make sure we don't silently inject nils somewhere.
      raise ArgumentError.new('job_data is required') if !job_data
      raise ArgumentError.new('build_id is required') if !build_id
      raise ArgumentError.new('subscription_id is required') if !subscription_id

      # Right now, enforce a single format for job_data because the worker also enforces it.
      raise ArgumentError.new(
        'job_data must match process_\w+:\d+') if !job_data.match(/\Aprocess_\w+:\d+\Z/)

      num_retries ||= 0

      stats.time('hub.methods.insert_job') do
        job_id = redis.incr('jobs:created:counter')
        keys = [
          'builds:active',
          "build:#{build_id}:subscription_id",
          "build:#{build_id}:jobs:new",
          "job:#{job_id}:data",
          "job:#{job_id}:build_id",
          "job:#{job_id}:subscription_id",
          "job:#{job_id}:num_retries",
        ]
        args = [
          job_id,
          build_id,
          subscription_id,
          num_retries,
          inserted_at || Time.now.to_i,
          job_data,
        ]

        _run_script('insert_job.lua', keys: keys, args: args)
        stats.gauge('hub.jobs.created.alltime', job_id)
        Percy.logger.debug do
          "[hub] Inserted job #{job_id}, build #{build_id}, " +
          "subscription #{subscription_id}: #{job_data}"
        end

        # Disconnect now (instead of timeout) to avoid hitting our DB connection limit.
        # A spike in insert_job calls can quickly consume our connection limits.
        disconnect_redis

        job_id
      end
    end

    # An infinite loop that continuously enqueues jobs and enforces subscription concurrency limits.
    def enqueue_jobs
      Percy.logger.info { '[hub:enqueue_jobs] Waiting for jobs to enqueue...' }
      infinite_loop_with_graceful_shutdown do
        sleeptime = _enqueue_jobs
        stats.count('hub.jobs.enqueuing.sleeptime', sleeptime)
        sleep(sleeptime)
      end
      Percy.logger.info { '[hub:enqueue_jobs] Quit' }
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
        loop do
          # ZRANGE returns items ordered by score. This ensures priority for older builds.
          build_id = redis.zrange('builds:active', index, index).first
          build_inserted_at = redis.zscore('builds:active', build_id)

          # We've iterated through all the active builds and successfully checked and/or enqueued
          # all potential jobs for all idle workers. Sleep for a small amount of time before
          # checking again to see if locks have been released or idle capacity is available.
          return 0.5 if !build_id

          # Grab the subscription associated to this build.
          subscription_id = redis.get("build:#{build_id}:subscription_id")

          # Enqueue as many jobs from this build as we can, until one of the exit conditions is met.
          loop do
            # Optimization: don't run the full LUA script if there are no possible jobs to enqueue.
            # We also handle returning 0 inside the script if no jobs exist in case there is a race.
            has_new_jobs = redis.llen("build:#{build_id}:jobs:new") > 0
            if has_new_jobs
              job_result = _enqueue_next_job(build_id: build_id, subscription_id: subscription_id)
            else
              job_result = 0
            end

            case job_result
            when 1
              # A job was successfully enqueued from this build, there may be more.
              # Immediately move to the next iteration and do not sleep.
              stats.increment('hub.jobs.enqueued')
              Percy.logger.debug { "[hub:enqueue_jobs] Enqueued job from build #{build_id}" }
              next
            when 0
              # No jobs were available, move on to the next build and trigger cleanup of this build.
              stats.increment('hub.jobs.enqueuing.skipped.build_empty')

              build_timeout_threshold = Time.now.to_i - DEFAULT_ACTIVE_BUILD_TIMEOUT_SECONDS
              remove_active_build(build_id: build_id) if build_inserted_at < build_timeout_threshold

              index += 1
              break
            when 'hit_global_lock_limit'
              # Global concurrency limit hit. Don't attempt to schedule more work.
              # Sleep for this amount of time waiting for a worker before checking again.
              stats.increment('hub.jobs.enqueuing.skipped.hit_global_lock_limit')
              return 1
            when 'hit_lock_limit'
              # Subscription concurrency limit hit, move on to the next build.
              stats.increment(
                'hub.jobs.enqueuing.skipped.hit_lock_limit',
                tags: [subscription_id],
              )
              index += 1
              break
            when 'no_idle_worker'
              # No idle workers, sleep and restart this algorithm from the beginning. See above.
              stats.increment('hub.jobs.enqueuing.skipped.no_idle_worker')

              # Sleep for this amount of time waiting for a worker before checking again.
              return 0.1
            end
          end
        end
      end
    end

    # One step of the above algorithm. Enqueue jobs from a build, constrained by the above limits.
    def _enqueue_next_job(build_id:, subscription_id:, enqueued_at: nil)
      stats.time('hub.methods._enqueue_next_job') do
        keys = [
          "build:#{build_id}:jobs:new",
          "global:locks:claimed",
          "subscription:#{subscription_id}:locks:limit",
          "subscription:#{subscription_id}:locks:claimed",
          'jobs:runnable',
          'workers:idle',
        ]
        args = [
          enqueued_at || Time.now.to_i,
          get_global_locks_limit,
          # Default for unset subscription lock limits.
          DEFAULT_SUBSCRIPTION_LOCKS_LIMIT,
          # Global minimum for all subscription lock limits.
          ENV.fetch('MIN_SUBSCRIPTION_LOCKS_LIMIT', DEFAULT_SUBSCRIPTION_LOCKS_LIMIT),
        ]
        _run_script('enqueue_next_job.lua', keys: keys, args: args)
      end
    end

    def remove_active_build(build_id:)
      stats.time('hub.methods.remove_active_build') do
        Percy.logger.debug { "[hub] Removing build #{build_id}, no more jobs." }
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
        machine_id = redis.incr('machines:created:counter')
        stats.gauge('hub.machines.created.alltime', machine_id)

        redis.set("machine:#{machine_id}:started_at", Time.now.to_i)
        redis.expire("machine:#{machine_id}:started_at", 86400)
        machine_id
      end
    end

    def register_worker(machine_id:)
      raise ArgumentError.new('machine_id is required') if !machine_id
      stats.time('hub.methods.register_worker') do
        worker_id = redis.incr('workers:created:counter')
        redis.zadd('workers:online', machine_id, worker_id)
        worker_heartbeat(worker_id: worker_id)
        _record_worker_stats

        # Record the time between machine creation and worker registration.
        started_at = redis.get("machine:#{machine_id}:started_at")
        if started_at
          stats.histogram('hub.workers.startup_time', Time.now.to_i - started_at.to_i)
        end

        worker_id
      end
    end

    def worker_heartbeat(worker_id:, offset_seconds: nil)
      stats.increment('hub.workers.heartbeat')

      # Fail if worker is no longer online. This shouldn't be possible, but we want to avoid
      # a race where a heartbeat is added after the worker is removed and we never cleanup the key.
      machine_id = redis.zscore('workers:online', worker_id)
      raise Percy::Hub::DeadWorkerError if !machine_id

      redis.zadd('workers:heartbeat', Time.now.to_i + (offset_seconds || 0), worker_id)
    end

    # Finds workers who have not sent a heartbeat in older_than_seconds number of seconds.
    def list_workers_by_heartbeat(older_than_seconds:)
      time_ago = Time.now.to_i - older_than_seconds
      redis.zrangebyscore('workers:heartbeat', '-inf', time_ago)
    end

    # Removes a worker and associated keys, and pushes any orphaned jobs into jobs:orphaned.
    # Should be called when worker is reaped.
    def remove_worker(worker_id:)
      stats.time('hub.methods.remove_worker') do
        Percy.logger.info("[hub] Removing worker #{worker_id}")
        keys = [
          'workers:online',
          'workers:idle',
          'workers:heartbeat',
          "worker:#{worker_id}:runnable",
          "worker:#{worker_id}:running",
          'jobs:orphaned',
        ]
        args = [
          worker_id,
        ]
        result = _run_script('remove_worker.lua', keys: keys, args: args)
        Percy.logger.info { "[hub] Removed worker #{worker_id}." }
        _record_worker_stats
        result
      end
    end

    def reap_workers
      Percy.logger.info { '[hub:reap_workers] Watching workers...' }
      infinite_loop_with_graceful_shutdown do
        sleep(_reap_workers)
      end
      Percy.logger.info { '[hub:reap_workers] Quit' }
    end

    def _reap_workers(older_than_seconds: DEFAULT_WORKER_REAP_SECONDS)
      dead_worker_ids = list_workers_by_heartbeat(older_than_seconds: older_than_seconds)
      dead_worker_ids.each do |dead_worker_id|
        remove_worker(worker_id: dead_worker_id)
      end

      # Dead workers may have had jobs on them. Retry the jobs (plus 10 extra buffer so we
      # work through the orphaned jobs if any exist).
      max_orphaned_jobs = dead_worker_ids.length + 10
      max_orphaned_jobs.times do
        orphaned_job_id = redis.lpop('jobs:orphaned')
        break if !orphaned_job_id

        retry_job(job_id: orphaned_job_id)
        release_job(job_id: orphaned_job_id)
      end

      return 5  # Sleep.
    end

    def reap_locks
      Percy.logger.info { '[hub:reap_locks] Starting lock reaper...' }
      infinite_loop_with_graceful_shutdown do
        _reap_expired_locks
        sleep(DEFAULT_LOCK_REAP_SECONDS)
      end
      Percy.logger.info { '[hub:reap_locks] Quit' }
    end

    # Releases locks older than the timeout, which are considered expired.
    def _reap_expired_locks(
      older_than_seconds: DEFAULT_EXPIRED_LOCK_TIMEOUT_SECONDS
    )
      time_ago = Time.now.to_i - older_than_seconds
      jobs_with_expired_locks = redis.zrangebyscore('global:locks:claimed', '-inf', time_ago)
      return 0 unless jobs_with_expired_locks

      # Release expired locks.
      #
      # NOTE: we intentionally do not cleanup job data here, leaving that to workers when
      # jobs finish or workers are reaped. Locks are decoupled and behave independently, and in
      # rare cases will need to be released when they expire, whether or not job data exists.
      jobs_with_expired_locks.each do |job_id|
        subscription_id = redis.get("job:#{job_id}:subscription_id")

        # Handle race where job finishes and the lock is already released.
        next if !subscription_id

        _release_locks_only(subscription_id: subscription_id, job_id: job_id)
      end

      _record_global_locks_stats
      stats.count('hub.jobs.enqueuing.locks.expired', jobs_with_expired_locks.length)

      jobs_with_expired_locks.length
    end

    def _release_locks_only(subscription_id:, job_id:)
      stats.time('hub.methods.release_locks') do
        keys = [
          "global:locks:claimed",
          "subscription:#{subscription_id}:locks:claimed",
        ]
        args = [
          job_id,
        ]
        _run_script('release_locks.lua', keys: keys, args: args)
      end
      true
    end

    # Schedules jobs from jobs:runnable onto idle workers.
    def schedule_jobs
      Percy.logger.info { '[hub:schedule_jobs] Waiting for jobs to schedule...' }
      infinite_loop_with_graceful_shutdown do
        sleep(_schedule_next_job)
      end
      Percy.logger.info { '[hub:schedule_jobs] Quit' }
    end

    # A single iteration of the schedule_jobs algorithm which blocks and waits for a job in
    # jobs:runnable, then schedules it on an idle worker. Load is distributed randomly.
    #
    # @return [Integer] The amount of time to sleep until the next iteration, usually 0.
    def _schedule_next_job(timeout: nil)
      stats.time('hub.methods._schedule_next_job') do
        # Handle orphaned jobs that might be stuck in jobs:scheduling. We assume that we are a single,
        # non-concurrent task to schedule jobs, so there should be nothing in jobs:scheduling here
        # and we can safely push them back into jobs:runnable if they exist.
        max_handled_orphaned_jobs = 10
        max_handled_orphaned_jobs.times do
          orphaned_job = redis.rpoplpush('jobs:scheduling', 'jobs:runnable')
          break if !orphaned_job
        end

        # Block and wait to pop a job from runnable to scheduling.
        timeout = timeout || DEFAULT_TIMEOUT_SECONDS
        job_id = redis.brpoplpush('jobs:runnable', 'jobs:scheduling', timeout)

        # Hit timeout and did not schedule any jobs, return 0 sleeptime and start again. This timeout
        # makes the BRPOPLPUSH not block forever and give us a chance to check for process signals.
        return 0 if !job_id

        stats.time('hub.methods._schedule_next_job.without_timeout') do
          # Find a random idle worker to schedule the job on.
          worker_id = stats.time('hub.methods._schedule_next_job.find_random_idle_worker') do
            redis.zrange('workers:idle', 0, -1).sample
          end
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
          clear_worker_idle(worker_id: worker_id)

          # Non-blocking push the job from jobs:scheduling to the selected worker's runnable queue.
          scheduled_job_id = redis.rpoplpush('jobs:scheduling', "worker:#{worker_id}:runnable")

          Percy.logger.debug do
            job_data = get_job_data(job_id: job_id)
            "[hub:schedule_jobs] Scheduled job #{job_id} (#{job_data}) on worker #{worker_id}"
          end
          if scheduled_job_id != job_id
            scheduled_job_data = get_job_data(job_id: scheduled_job_id)
            Percy.logger.warn do
              "[hub:schedule_jobs] Mismatch: expected to schedule job #{job_id} (#{job_data}) " +
              "but scheduled #{scheduled_job_id} (#{scheduled_job_data}) instead"
            end
          end

          return 0
        end
      end
    end

    # Block and wait until the timeout for the next runnable job for a specific worker.
    #
    # @return [nil, Integer]
    #   - `nil` when the operation timed out
    #   - the job ID otherwise
    def wait_for_job(worker_id:, timeout: nil)
      timeout = timeout || DEFAULT_TIMEOUT_SECONDS
      begin
        # Race condition handling: this worker thinks it is idle and is asking for another job, but
        # it was previously given a job to handle. Pop all the running jobs back into runnable so
        # they are picked up again. This happens in a real-world race condition: the BRPOPLPUSH
        # is successful, but the timeout is reached at the same time and a job is moved into the
        # :running queue but is not actually returned.
        redis.llen("worker:#{worker_id}:running").times do
          redis.rpoplpush("worker:#{worker_id}:running", "worker:#{worker_id}:runnable")
        end

        result = redis.brpoplpush(
          "worker:#{worker_id}:runnable", "worker:#{worker_id}:running", timeout)
        return unless result

        runnable_jobs = redis.lrange("worker:#{worker_id}:runnable", 0, 100)
        running_jobs = redis.lrange("worker:#{worker_id}:running", 0, 100)
        Percy.logger.debug do
          "[worker:#{worker_id}] Popped #{result} job into running queue " +
          "(runnable: #{runnable_jobs}, running: #{running_jobs})"
        end
      rescue Redis::TimeoutError
        Percy.logger.warn("[worker:#{worker_id}] Handling Redis::TimeoutError")
        disconnect_redis
        return
      end
      Integer(result)
    end

    def get_job_data(job_id:)
      redis.get("job:#{job_id}:data")
    end

    def get_job_num_retries(job_id:)
      # TODO: this is backwards compatible with no num_retries key, eventually we can clean this up.
      Integer(redis.get("job:#{job_id}:num_retries") || 0)
    end

    # Marks the worker's current job as complete.
    #
    # @return [nil, Integer]
    #   - `nil` when there was no job to mark complete
    #   - the job ID otherwise
    def worker_job_complete(worker_id:)
      result = redis.rpop("worker:#{worker_id}:running")
      Percy.logger.debug { "[worker:#{worker_id}] Popped #{result} from running queue" }
      result
    end

    def retry_job(job_id:)
      stats.increment('hub.jobs.retried')
      job_data = redis.get("job:#{job_id}:data")
      build_id = redis.get("job:#{job_id}:build_id")
      subscription_id = redis.get("job:#{job_id}:subscription_id")
      num_retries = get_job_num_retries(job_id: job_id)
      insert_job(
        job_data: job_data,
        build_id: build_id,
        subscription_id: subscription_id,
        num_retries: num_retries + 1,
      )
    end

    # Full job cleanup, including releasing locks, deleting job data, and recording stats.
    # It is assumed that the job is complete (regardless of status) and that retries have
    # already been handled by this point.
    def release_job(job_id:)
      stats.time('hub.methods.release_job') do
        subscription_id = redis.get("job:#{job_id}:subscription_id")
        return false if !subscription_id
        keys = [
          "global:locks:claimed",
          "subscription:#{subscription_id}:locks:claimed",
          "job:#{job_id}:data",
          "job:#{job_id}:build_id",
          "job:#{job_id}:subscription_id",
          "job:#{job_id}:num_retries",
        ]
        args = [
          job_id,
        ]
        _run_script('release_job.lua', keys: keys, args: args)

        # Record completed alltime jobs stats and that we just completed a job.
        stats.gauge('hub.jobs.completed.alltime', job_id)
        stats.increment('hub.jobs.completed')
        _record_global_locks_stats
      end
      true
    end

    def get_monthly_usage(subscription_id:)
      stats.time('hub.methods.get_monthly_usage') do
        year = Time.now.strftime('%Y')
        month = Time.now.strftime('%m')

        usage = redis.get("subscription:#{subscription_id}:usage:#{year}:#{month}:counter")
        usage = Integer(usage || 0)

        # Disconnect now (instead of timeout) to avoid hitting our DB connection limit.
        disconnect_redis

        usage
      end
    end

    def increment_monthly_usage(subscription_id:, count: nil)
      stats.time('hub.methods.increment_monthly_usage') do
        now = Time.now
        year = now.strftime('%Y')
        month = now.strftime('%m')
        result = redis.incrby(
          "subscription:#{subscription_id}:usage:#{year}:#{month}:counter", count || 1)

        # Disconnect now (instead of timeout) to avoid hitting our DB connection limit.
        disconnect_redis

        result
      end
    end

    def set_worker_idle(worker_id:)
      machine_id = redis.zscore('workers:online', worker_id)
      raise Percy::Hub::DeadWorkerError if !machine_id
      redis.zadd('workers:idle', machine_id, worker_id)
      _record_worker_stats
    end

    def clear_worker_idle(worker_id:)
      redis.zrem('workers:idle', worker_id)
      _record_worker_stats
    end

    def get_all_subscription_data(year: nil, month: nil)
      now = Time.now
      year ||= now.strftime('%Y')
      month ||= now.strftime('%m')

      keys = redis.keys("subscription:*:usage:#{year}:#{month}:counter")
      return {} if keys.empty?  # Stupid MGET doesn't support empty arrays.

      subscription_data = redis.mapped_mget(*keys)
      Hash[subscription_data.map { |k, v| [/subscription:(.*):usage:/.match(k)[1], v] }]
    end

    def _record_global_locks_stats
      stats.gauge('hub.global.locks.limit', get_global_locks_limit)
      stats.gauge('hub.global.locks.claimed', redis.zcount('global:locks:claimed', '-inf', '+inf'))
    end

    def _record_worker_stats
      # Record an exact count of how many workers are online and idle.
      workers_online_count = redis.zcard('workers:online')
      workers_idle_count = redis.zcard('workers:idle')
      stats.gauge('hub.workers.online', workers_online_count)
      stats.gauge('hub.workers.idle', workers_idle_count)
      stats.gauge('hub.workers.processing', workers_online_count - workers_idle_count)
      true
    end

    def _load_script_sha(name)
      return script_shas[name] if script_shas[name]

      script = File.read(File.expand_path("../hub/scripts/#{name}", __FILE__))
      script_shas[name] = redis.script(:load, script)
    end

    def _run_script(name, keys:, args: nil)
      redis.evalsha(_load_script_sha(name), keys: keys, argv: args)
    end

    def infinite_loop_with_graceful_shutdown(&block)
      # Catch SIGINT and SIGTERM and trigger gracefully shutdown on the next loop iteration.
      self._heard_interrupt = false
      Signal.trap(:INT) do
        puts 'Quitting...'
        self._heard_interrupt = true
      end
      Signal.trap(:TERM) { self._heard_interrupt = true }

      loop do
        break if _heard_interrupt
        yield
      end
    end
  end
end
