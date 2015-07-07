local build_jobs_new_key = KEYS[1]
local subscription_locks_limit_key = KEYS[2]
local subscription_locks_active_key = KEYS[3]
local jobs_runnable_key = KEYS[4]
local workers_idle_key = KEYS[5]

-- If there are no idle workers available, we cannot queue any jobs. We compute the number of idle
-- workers as the number of items in workers:idle MINUS the number of items in jobs:runnable, since
-- jobs:runnable is the buffer of jobs that will be immediately scheduled on idle workers.
local num_idle_workers = tonumber(redis.call('ZCARD', workers_idle_key))
local num_jobs_runnable = tonumber(redis.call('LLEN', jobs_runnable_key))
if num_idle_workers - num_jobs_runnable <= 0 then
  return 'no_idle_worker'
end

-- Grab the subscription info.
local default_locks_limit = 2
local subscription_locks_limit = tonumber(redis.call('GET', subscription_locks_limit_key))
subscription_locks_limit = subscription_locks_limit or default_locks_limit

local default_locks_active = 0
local subscription_locks_active = tonumber(redis.call('GET', subscription_locks_active_key))
subscription_locks_active = subscription_locks_active or default_locks_active

-- If the subscription's concurrency limit has been hit, return and move to the next build.
if subscription_locks_active >= subscription_locks_limit then
  return 'hit_lock_limit'
end

-- Push the job to jobs:runnable and activate one of the subscription locks.
local job_pushed = redis.call('RPOPLPUSH', build_jobs_new_key, jobs_runnable_key)
if job_pushed then
  redis.call('INCR', subscription_locks_active_key)
else
  -- The build was empty so no jobs were enqueued.
  return 0
end

-- There was a job enqueued from this build.
return 1
