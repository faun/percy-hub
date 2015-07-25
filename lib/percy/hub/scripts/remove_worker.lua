local workers_online_key = KEYS[1]
local workers_idle_key = KEYS[2]
local workers_heartbeat_key = KEYS[3]
local worker_runnable_key = KEYS[4]
local worker_running_key = KEYS[5]
local jobs_orphaned_key = KEYS[6]

local worker_id = ARGV[1]

-- Clear the worker from workers:idle, workers:online, and workers:heartbeat.
local result = redis.call('ZREM', workers_online_key, worker_id)
redis.call('ZREM', workers_idle_key, worker_id)
redis.call('ZREM', workers_heartbeat_key, worker_id)

-- If the worker died hard without cleanup, it may have orphaned jobs still in its queues.
-- Push any orphaned jobs into jobs:orphaned so at least we can detect this and handle them later.
redis.call('RPOPLPUSH', worker_runnable_key, jobs_orphaned_key)
redis.call('RPOPLPUSH', worker_running_key, jobs_orphaned_key)

return result
