local global_locks_claimed_key = KEYS[1]
local subscription_locks_claimed_key = KEYS[2]

local job_id = ARGV[1]

-- Release the global lock and subscription lock that were added by enqueue_jobs.
redis.call('ZREM', global_locks_claimed_key, job_id)
redis.call('ZREM', subscription_locks_claimed_key, job_id)
