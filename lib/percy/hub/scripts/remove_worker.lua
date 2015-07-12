local workers_online_key = KEYS[1]
local workers_idle_key = KEYS[2]
local worker_runnable_key = KEYS[3]
local worker_running_key = KEYS[4]
local jobs_orphaned_key = KEYS[5]

local worker_id = ARGV[1]

-- Clear the worker from workers:idle and workers:online.
redis.call('ZREM', workers_idle_key, worker_id)
local result = redis.call('ZREM', workers_online_key, worker_id)

-- If the worker died hard without cleanup, it may have orphaned jobs still in its queues.
-- Push any orphaned jobs into jobs:orphaned so at least we can detect this and handle them later.
redis.call('RPOPLPUSH', worker_runnable_key, jobs_orphaned_key)
redis.call('RPOPLPUSH', worker_running_key, jobs_orphaned_key)

return result
