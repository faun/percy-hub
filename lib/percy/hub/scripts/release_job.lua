local global_locks_claimed_key = KEYS[1]
local subscription_locks_claimed_key = KEYS[2]
local job_data_key = KEYS[3]
local job_build_id_key = KEYS[4]
local job_subscription_id_key = KEYS[5]
local job_num_retries_key = KEYS[6]
local job_serialized_trace_key = KEYS[7]

local job_id = ARGV[1]

-- Release the global lock and subscription lock that were added by enqueue_jobs.
redis.call('ZREM', global_locks_claimed_key, job_id)
redis.call('ZREM', subscription_locks_claimed_key, job_id)

-- Delete the job data.
redis.call('DEL', job_data_key)
redis.call('DEL', job_build_id_key)
redis.call('DEL', job_subscription_id_key)
redis.call('DEL', job_num_retries_key)
redis.call('DEL', job_serialized_trace_key)
