local build_jobs_new_key = KEYS[1]
local subscription_locks_limit_key = KEYS[2]
local subscription_locks_active_key = KEYS[3]
local jobs_runnable_key = KEYS[4]

-- Grab the subscription info.
local default_locks_limit = 5
local subscription_locks_limit = tonumber(redis.call('GET', subscription_locks_limit_key))
subscription_locks_limit = subscription_locks_limit or default_locks_limit

local default_locks_active = 0
local subscription_locks_active = tonumber(redis.call('GET', subscription_locks_active_key))
subscription_locks_active = subscription_locks_active or default_locks_active

-- If the subscription's concurrency limit has been hit, return and move to the next build.
if subscription_locks_active >= subscription_locks_limit then
  return 'hit_lock_limit'
end

-- If there are no idle workers available, we cannot queue the job.
-- return 'no_idle_workers'

redis.call('RPOPLPUSH', build_jobs_new_key, jobs_runnable_key)

-- If not, all jobs are complete, delete the build ID from builds:active.

-- ZRANGE key start stop

-- return 'foo'
