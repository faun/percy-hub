local build_subscription_locks_active_key = KEYS[1]
local job_data_key = KEYS[2]
local job_build_id_key = KEYS[3]
local job_subscription_id_key = KEYS[4]

-- Release the subscription lock that was added by enqueue_jobs.
redis.call('DECR', build_subscription_locks_active_key)

-- Delete the job data.
redis.call('DEL', job_data_key)
redis.call('DEL', job_build_id_key)
redis.call('DEL', job_subscription_id_key)

