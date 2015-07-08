local builds_active_key = KEYS[1]
local build_subscription_id_key = KEYS[2]
local build_jobs_new_key = KEYS[3]

local build_id = ARGV[1]

-- Skip cleanup if the build still has jobs that have not been enqueued.
-- This makes remove_active_build safe from race conditions where a new job is
-- added between noticing the build is empty and remove it from builds:active.
if redis.call('LLEN', build_jobs_new_key) > 0 then
  return 0
end

local result = redis.call('ZREM', 'builds:active', build_id)
redis.call('DEL', build_subscription_id_key)

return result
