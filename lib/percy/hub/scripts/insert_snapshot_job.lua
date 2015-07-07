local jobs_created_counter_key = KEYS[1]
local builds_active_key = KEYS[2]
local build_subscription_id_key = KEYS[3]
local build_jobs_key = KEYS[4]

local snapshot_id = ARGV[1]
local build_id = ARGV[2]
local subscription_id = ARGV[3]
local now = ARGV[4]
local job_data = ARGV[5]

-- Increment the global jobs counter.
local num_total_jobs = redis.call('INCR', jobs_created_counter_key)

-- The score in builds:active is the first insertion time of build_id into builds:active. If the
-- build already exists in this sorted set when the next snapshot job is inserted, the score is
-- re-used. This has the side-effect of keeping active builds that are sending snapshots quickly
-- at the front of the queue, and bumping slow builds to the back of the queue if they send
-- snapshots slower than the snapshots are processed.
local score = redis.call('ZSCORE', builds_active_key, build_id) or now

-- Add the build to builds:active.
redis.call('ZADD', builds_active_key, score, build_id)

-- Make sure the build subscription ID is set and self destructs in one week, after we're sure the
-- build has finished or failed.
redis.call('SET', build_subscription_id_key, subscription_id)
redis.call('EXPIRE', build_subscription_id_key, 604800)

-- Add the job to the sorted set of build jobs.
-- Score of 0 means the job has not been queued or scheduled yet.
redis.call('ZADD', build_jobs_key, 0, job_data)

return num_total_jobs
