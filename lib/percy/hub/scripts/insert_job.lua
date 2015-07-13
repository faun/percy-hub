local builds_active_key = KEYS[1]
local build_subscription_id_key = KEYS[2]
local build_jobs_new_key = KEYS[3]
local job_data_key = KEYS[4]
local job_build_id_key = KEYS[5]
local job_subscription_id_key = KEYS[6]

local job_id = ARGV[1]
local build_id = ARGV[2]
local subscription_id = ARGV[3]
local now = ARGV[4]
local job_data = ARGV[5]

-- The score in builds:active is the first insertion time of build_id into builds:active. If the
-- build already exists in this sorted set when the next snapshot job is inserted, the score is
-- re-used. This has the side-effect of keeping active builds that are sending snapshots quickly
-- at the front of the queue, and bumping slow builds to the back of the queue if they send
-- snapshots slower than the snapshots are processed.
local score = redis.call('ZSCORE', builds_active_key, build_id) or now

-- Add the build to builds:active.
redis.call('ZADD', builds_active_key, score, build_id)

-- Set the build subscription ID.
redis.call('SET', build_subscription_id_key, subscription_id)

-- Set the job data.
redis.call('SET', job_data_key, job_data)
redis.call('SET', job_build_id_key, build_id)
redis.call('SET', job_subscription_id_key, subscription_id)

-- Add the job ID to the sorted set of build jobs.
redis.call('LPUSH', build_jobs_new_key, job_id)
