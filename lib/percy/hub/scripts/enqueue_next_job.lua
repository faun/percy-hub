local build_jobs_new_key = KEYS[1]
local global_locks_claimed_key = KEYS[2]
local global_locks_limit_key = KEYS[3]
local subscription_locks_limit_key = KEYS[4]
local subscription_locks_claimed_key = KEYS[5]
local jobs_runnable_key = KEYS[6]
local workers_idle_key = KEYS[7]

local now = ARGV[1]
local default_subscription_locks_limit = tonumber(ARGV[2])
local min_subscription_locks_limit = tonumber(ARGV[3])

-- Global lock limit.
local global_locks_limit = tonumber(redis.call('GET', global_locks_limit_key))
global_locks_limit = global_locks_limit or 10000

local num_active_global_locks = redis.call('ZCOUNT', global_locks_claimed_key, '-inf', '+inf')
-- If the global concurrency limit has been hit, return.
if num_active_global_locks >= global_locks_limit then
  return 'hit_global_lock_limit'
end

-- Subscription locks limit.
local subscription_locks_limit = tonumber(redis.call('GET', subscription_locks_limit_key))
subscription_locks_limit = subscription_locks_limit or default_subscription_locks_limit
subscription_locks_limit = math.max(subscription_locks_limit, min_subscription_locks_limit)

local num_active_locks = redis.call('ZCARD', subscription_locks_claimed_key)
-- If the subscription's concurrency limit has been hit, return and move to the next build.
if num_active_locks >= subscription_locks_limit then
  return 'hit_lock_limit'
end

-- If there are no idle workers available, we cannot queue any jobs. We compute the number of idle
-- workers as the number of items in workers:idle MINUS the number of items in jobs:runnable, since
-- jobs:runnable is the buffer of jobs that will be immediately scheduled on idle workers.
local num_idle_workers = tonumber(redis.call('ZCARD', workers_idle_key))
local num_jobs_runnable = tonumber(redis.call('LLEN', jobs_runnable_key))
if num_idle_workers - num_jobs_runnable <= 0 then
  return 'no_idle_worker'
end

-- Push a job from build:123:jobs:new to jobs:runnable.
local job_id = redis.call('RPOPLPUSH', build_jobs_new_key, jobs_runnable_key)
if job_id then
  -- Claim a lock. The score is the current time, ie. when the lock was claimed.
  redis.call('ZADD', subscription_locks_claimed_key, now, job_id)
  redis.call('ZADD', global_locks_claimed_key, now, job_id)

  -- There was a job enqueued from this build.
  return 1
else
  -- The build was empty so no jobs were enqueued.
  return 0
end

