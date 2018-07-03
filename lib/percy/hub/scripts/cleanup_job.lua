local build_subscription_locks_claimed_key = KEYS[1]
local job_data_key = KEYS[2]
local job_build_id_key = KEYS[3]
local job_subscription_id_key = KEYS[4]
local job_num_retries_key = KEYS[5]

local job_id = ARGV[1]

-- Release the subscription lock that was added by enqueue_jobs.
redis.call('ZREM', build_subscription_locks_claimed_key, job_id)

-- Delete the job data.
redis.call('DEL', job_data_key)
redis.call('DEL', job_build_id_key)
redis.call('DEL', job_subscription_id_key)
redis.call('DEL', job_num_retries_key)
