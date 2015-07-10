RSpec.describe Percy::Hub do
  let(:hub) { Percy::Hub.new }
  let(:machine_id) { hub.start_machine }

  describe '#insert_snapshot_job' do
    it 'inserts a snapshot job and updates relevant keys' do
      expect(hub.redis.get('jobs:counter')).to be_nil

      result = hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
      expect(result).to eq(1)
      expect(hub.redis.get('jobs:counter').to_i).to eq(1)
      expect(hub.redis.zscore('builds:active', 234)).to be > 1
      expect(hub.redis.get('build:234:subscription_id').to_i).to eq(345)
      expect(hub.redis.lrange('build:234:jobs:new', 0, 10)).to eq(['1'])

      expect(hub.redis.get('job:1:data')).to eq('process_snapshot:123')
      expect(hub.redis.get('job:1:subscription_id').to_i).to eq(345)
    end
    it 'is idempotent and re-uses the inserted_at score if present' do
      expect(hub.redis.get('jobs:counter')).to be_nil
      hub.insert_snapshot_job(
        snapshot_id: 123,
        build_id: 234,
        subscription_id: 345,
        inserted_at: 20000,
      )
      expect(hub.redis.get('jobs:counter').to_i).to eq(1)
      expect(hub.redis.zscore('builds:active', 234)).to eq(20000)

      hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
      expect(hub.redis.get('jobs:counter').to_i).to eq(2)
      expect(hub.redis.zscore('builds:active', 234)).to eq(20000)
    end
  end
  describe '#_enqueue_jobs' do
    context 'with idle workers available' do
      before(:each) do
        hub.set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))
        hub.set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))
        hub.set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))
        hub.set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))
        hub.set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))
      end

      it 'enqueues all jobs if enough idle workers and subscription locks' do
        hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
        hub.insert_snapshot_job(snapshot_id: 124, build_id: 234, subscription_id: 345)

        # Returns 0.5, indicating completion of all enqueuing.
        expect(hub._enqueue_jobs).to eq(0.5)

        expect(hub.redis.llen('jobs:runnable')).to eq(2)
      end
      it 'enqueues jobs from multiple builds if enough idle workers and subscription locks' do
        hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
        hub.insert_snapshot_job(snapshot_id: 124, build_id: 234, subscription_id: 345)
        hub.insert_snapshot_job(snapshot_id: 130, build_id: 235, subscription_id: 346)
        hub.insert_snapshot_job(snapshot_id: 131, build_id: 235, subscription_id: 346)

        # Returns 0.5, indicating completion of all enqueuing.
        expect(hub._enqueue_jobs).to eq(0.5)

        expect(hub.redis.llen('jobs:runnable')).to eq(4)
      end
      it 'skips empty builds and cleans up empty active builds' do
        # Insert a job and then enqueue, so we leave a build ID in builds:active.
        job_id = hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
        expect(hub.redis.zcard('builds:active')).to eq(1)
        expect(hub._enqueue_jobs).to eq(0.5)
        expect(hub.redis.zcard('builds:active')).to eq(0)
        expect(hub.redis.llen('jobs:runnable')).to eq(1)

        expect(hub.redis.llen('jobs:runnable')).to eq(1)
        expect(hub.redis.lrange('jobs:runnable', 0, 0)).to eq([job_id.to_s])
      end
      it 'enforces concurrency limits (default 2 per subscription)' do
        hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
        hub.insert_snapshot_job(snapshot_id: 124, build_id: 234, subscription_id: 345)
        hub.insert_snapshot_job(snapshot_id: 125, build_id: 234, subscription_id: 345)
        hub.insert_snapshot_job(snapshot_id: 126, build_id: 234, subscription_id: 345)

        hub.insert_snapshot_job(snapshot_id: 130, build_id: 235, subscription_id: 346)
        hub.insert_snapshot_job(snapshot_id: 131, build_id: 235, subscription_id: 346)
        hub.insert_snapshot_job(snapshot_id: 132, build_id: 235, subscription_id: 346)

        # Returns 0.5, indicating completion of all enqueuing.
        expect(hub._enqueue_jobs).to eq(0.5)

        # There are 2 enqueued jobs from the first subscription and 2 from the second.
        expect(hub.redis.llen('jobs:runnable')).to eq(4)
        expect(hub.redis.lrange('jobs:runnable', 0, 3)).to eq(['6', '5', '2', '1'])
      end
    end
    context 'with NO idle workers available' do
      it 'returns sleeptime 1 and does not enqueue jobs' do
        hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
        expect(hub._enqueue_jobs).to eq(1)
        expect(hub.redis.llen('jobs:runnable')).to eq(0)
      end
      it 'performs lock count check first before idle worker check' do
        hub.set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))
        hub.set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))
        hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
        hub.insert_snapshot_job(snapshot_id: 124, build_id: 234, subscription_id: 345)
        hub.insert_snapshot_job(snapshot_id: 124, build_id: 234, subscription_id: 345)

        # This magic "0.5" indicates the hit_lock_limit sleeptime path.
        expect(hub._enqueue_jobs).to eq(0.5)
        expect(hub.redis.llen('jobs:runnable')).to eq(2)
      end
    end
    it 'returns sleeptime 2 if there are no active builds' do
      expect(hub._enqueue_jobs).to eq(2)
    end
  end
  describe '#_enqueue_next_job' do
    let(:worker_id) { hub.register_worker(machine_id: machine_id) }

    it 'returns no_idle_worker if there are no idle workers available' do
      hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
      result = hub._enqueue_next_job(build_id: 234, subscription_id: 345)
      expect(result).to eq('no_idle_worker')
      expect(hub.redis.llen('jobs:runnable')).to eq(0)
    end
    it 'computes number of idle workers as idle workers minus the number of jobs:runnable' do
      # Create an idle worker and add a job to jobs:runnable.
      hub.set_worker_idle(worker_id: worker_id)
      hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
      result = hub._enqueue_next_job(build_id: 234, subscription_id: 345)
      expect(result).to eq(1)
      expect(hub.redis.llen('jobs:runnable')).to eq(1)

      # The worker is idle but there is a job in jobs:runnable, so 'no_idle_worker' is returned.
      hub.insert_snapshot_job(snapshot_id: 124, build_id: 234, subscription_id: 345)
      expect(hub._enqueue_next_job(build_id: 234, subscription_id: 345)).to eq('no_idle_worker')
    end
    it 'returns hit_lock_limit when concurrency limit is exceeded (and defaults limit to 2)' do
      hub.set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))
      hub.set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))
      hub.set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))

      hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
      hub.insert_snapshot_job(snapshot_id: 124, build_id: 234, subscription_id: 345)
      hub.insert_snapshot_job(snapshot_id: 125, build_id: 234, subscription_id: 345)

      expect(hub.redis.llen('jobs:runnable')).to eq(0)
      expect(hub._enqueue_next_job(build_id: 234, subscription_id: 345)).to eq(1)
      expect(hub.redis.llen('jobs:runnable')).to eq(1)
      expect(hub._enqueue_next_job(build_id: 234, subscription_id: 345)).to eq(1)
      expect(hub.redis.llen('jobs:runnable')).to eq(2)
      expect(hub._enqueue_next_job(build_id: 234, subscription_id: 345)).to eq('hit_lock_limit')
      expect(hub.redis.llen('jobs:runnable')).to eq(2)

      # Release one of the subscription's locks and enqueue another job from the build.
      hub.redis.decr('subscription:345:locks:active')
      expect(hub._enqueue_next_job(build_id: 234, subscription_id: 345)).to eq(1)
      expect(hub.redis.llen('jobs:runnable')).to eq(3)
    end
    it 'returns 0 when no jobs exist in the build' do
      hub.set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))
      result = hub._enqueue_next_job(build_id: 234, subscription_id: 345)
      expect(result).to eq(0)
    end
    it 'returns 1 and moves the earliest job into jobs:runnable if there is an idle worker' do
      hub.set_worker_idle(worker_id: worker_id)

      hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
      hub.insert_snapshot_job(snapshot_id: 124, build_id: 234, subscription_id: 345)
      hub.insert_snapshot_job(snapshot_id: 1000, build_id: 234, subscription_id: 345)

      result = hub._enqueue_next_job(build_id: 234, subscription_id: 345)
      expect(result).to eq(1)

      tail_item = hub.redis.lindex('jobs:runnable', -1)
      expect(tail_item).to eq('1')
    end
  end
  describe '#remove_active_build' do
    it 'removes the build from builds:active' do
      hub.set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))
      hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
      hub._enqueue_next_job(build_id: 234, subscription_id: 345)

      expect(hub.redis.zscore('builds:active', 234)).to be > 1
      expect(hub.redis.get('build:234:subscription_id').to_i).to eq(345)

      expect(hub.remove_active_build(build_id: 234)).to eq(true)
      expect(hub.redis.zscore('builds:active', 234)).to be_nil
      expect(hub.redis.get('build:234:subscription_id')).to be_nil
    end
    it 'does nothing if build does not exist in builds:active' do
      expect(hub.remove_active_build(build_id: 234)).to eq(false)
    end
    it 'does nothing if build is actually active (has unqueued jobs)' do
      hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)

      expect(hub.remove_active_build(build_id: 234)).to eq(false)
      expect(hub.redis.zscore('builds:active', 234)).to be > 1
      expect(hub.redis.get('build:234:subscription_id').to_i).to eq(345)
    end
  end
  describe '#start_machine' do
    it 'returns an incrementing id' do
      expect(hub.stats).to receive(:gauge).once.with('hub.machines.started', 1)
      expect(hub.stats).to receive(:gauge).once.with('hub.machines.started', 2)
      expect(hub.stats).to receive(:gauge).once.with('hub.machines.started', 3)
      expect(hub.start_machine).to eq(1)
      expect(hub.start_machine).to eq(2)
      expect(hub.start_machine).to eq(3)
      expect(hub.redis.get('machines:counter').to_i).to eq(3)
    end
    it 'sets started_at and an expiration' do
      machine_id = hub.start_machine
      expect(hub.redis.get("machine:#{machine_id}:started_at").to_i).to be > 1
      expect(hub.redis.ttl("machine:#{machine_id}:started_at").to_i).to be > 80000
    end
  end
  describe '#register_worker' do
    it 'returns an incrementing id' do
      expect(hub.register_worker(machine_id: machine_id)).to eq(1)
      expect(hub.register_worker(machine_id: machine_id)).to eq(2)
      expect(hub.register_worker(machine_id: machine_id)).to eq(3)
      expect(hub.redis.get('workers:counter').to_i).to eq(3)
    end
    it 'adds the worker to workers:online and records startup time' do
      expect(hub.stats).to receive(:histogram).once
        .with('hub.workers.startup_time', kind_of(Numeric)).and_call_original

      worker_id = hub.register_worker(machine_id: machine_id)
      expect(hub.redis.zscore('workers:online', worker_id)).to eq(machine_id)
    end
    it 'works if the machine started_at time has expired' do
      expect(hub.stats).to_not receive(:histogram)
      hub.redis.del("machine:#{machine_id}:started_at")
      worker_id = hub.register_worker(machine_id: machine_id)
    end
  end
  describe '#remove_worker' do
    it 'removes worker related keys' do
      worker_id = hub.register_worker(machine_id: machine_id)
      hub.set_worker_idle(worker_id: worker_id)
      expect(hub.redis.zscore('workers:online', worker_id)).to be
      expect(hub.redis.zscore('workers:idle', worker_id)).to be

      hub.remove_worker(worker_id: worker_id)
      expect(hub.redis.zscore('workers:online', worker_id)).to_not be
      expect(hub.redis.zscore('workers:idle', worker_id)).to_not be
    end
    it 'pushes orphaned jobs from worker:<id>:runnable into jobs:orphaned' do
      worker_id = hub.register_worker(machine_id: machine_id)
      hub.set_worker_idle(worker_id: worker_id)
      hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
      hub._enqueue_jobs
      hub._schedule_next_job

      expect(hub.redis.lrange("worker:#{worker_id}:runnable", 0, 10)).to eq(['1'])
      expect(hub.redis.lrange('jobs:orphaned', 0, 10)).to eq([])
      hub.remove_worker(worker_id: worker_id)
      expect(hub.redis.exists("worker:#{worker_id}:running")).to eq(false)
      expect(hub.redis.lrange('jobs:orphaned', 0, 10)).to eq(['1'])
    end
    it 'pushes orphaned jobs from worker:<id>:running into jobs:orphaned' do
      worker_id = hub.register_worker(machine_id: machine_id)
      hub.set_worker_idle(worker_id: worker_id)
      hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
      hub._enqueue_jobs
      hub._schedule_next_job
      hub.wait_for_job(worker_id: worker_id)

      expect(hub.redis.lrange("worker:#{worker_id}:running", 0, 10)).to eq(['1'])
      expect(hub.redis.lrange('jobs:orphaned', 0, 10)).to eq([])
      hub.remove_worker(worker_id: worker_id)
      expect(hub.redis.exists("worker:#{worker_id}:running")).to eq(false)
      expect(hub.redis.lrange('jobs:orphaned', 0, 10)).to eq(['1'])
    end
  end
  describe '#_schedule_next_job' do
    it 'returns 0 and pops job from jobs:runnable to the first idle worker' do
      first_worker_id = hub.register_worker(machine_id: machine_id)
      second_worker_id = hub.register_worker(machine_id: machine_id)
      hub.set_worker_idle(worker_id: second_worker_id)

      hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
      hub._enqueue_jobs
      expect(hub.redis.zrange('workers:idle', 0, 10)).to eq([second_worker_id.to_s])

      expect(hub._schedule_next_job).to eq(0)
      expect(hub.redis.zrange('workers:idle', 0, 10)).to eq([])
      expect(hub.redis.llen("worker:#{second_worker_id}:runnable")).to eq(1)
      expect(hub.redis.lindex("worker:#{second_worker_id}:runnable", 0)).to eq('1')
    end
    it 'returns 1 in the edge case where no idle worker is available but a job is' do
      worker_id = hub.register_worker(machine_id: machine_id)
      hub.set_worker_idle(worker_id: worker_id)
      hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
      hub._enqueue_jobs
      hub._clear_worker_idle(worker_id: worker_id)

      expect(hub._schedule_next_job).to eq(1)

      # Idempotent check:
      expect(hub._schedule_next_job).to eq(1)

      # And back to success:
      hub.set_worker_idle(worker_id: worker_id)
      expect(hub._schedule_next_job).to eq(0)
    end
  end
  describe '#wait_for_job' do
    let(:worker_id) { hub.register_worker(machine_id: machine_id) }
    it 'returns the next runnable job on the worker' do
      hub.set_worker_idle(worker_id: worker_id)
      hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
      hub._enqueue_jobs
      hub._schedule_next_job

      result = hub.wait_for_job(worker_id: worker_id)
      expect(result).to eq('1')
      expect(hub.redis.llen("worker:#{worker_id}:runnable")).to eq(0)
      expect(hub.redis.lindex("worker:#{worker_id}:running", 0)).to eq('1')
    end
  end
  describe '#worker_job_complete' do
    let(:worker_id) { hub.register_worker(machine_id: machine_id) }
    before(:each) do
      hub.set_worker_idle(worker_id: worker_id)
      hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
      hub._enqueue_jobs
      hub._schedule_next_job
      hub.wait_for_job(worker_id: worker_id)
    end
    it 'removes the job from the worker:<id>:running queue' do
      expect(hub.redis.lrange("worker:#{worker_id}:running", 0, 10)).to eq(['1'])
      hub.worker_job_complete(worker_id: worker_id)
      expect(hub.redis.lrange("worker:#{worker_id}:running", 0, 10)).to eq([])
    end
    it 'releases a subscription lock' do
      expect(hub.redis.get('subscription:345:locks:active')).to eq('1')
      hub.worker_job_complete(worker_id: worker_id)
      expect(hub.redis.get('subscription:345:locks:active')).to eq('0')
    end
    it 'returns -1 if no job was running' do
      expect(hub.worker_job_complete(worker_id: 999)).to eq(-1)
    end
    it 'records stats if successful' do
      expect(hub.stats).to receive(:increment).once.with('hub.jobs.completed').and_call_original
      expect(hub.worker_job_complete(worker_id: 999)).to eq(-1)
      hub.worker_job_complete(worker_id: worker_id)
    end
  end
  describe '#cleanup_job' do
    it 'removes job related keys' do
      hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
      expect(hub.redis.get('job:1:data')).to be
      expect(hub.redis.get('job:1:subscription_id')).to be
      hub.cleanup_job(job_id: 1)
      expect(hub.redis.get('job:1:data')).to be_nil
      expect(hub.redis.get('job:1:subscription_id')).to be_nil
    end
  end
  describe '#_clear_worker_idle and #set_worker_idle' do
    it 'adds or removes worker from workers:idle' do
      machine_id = hub.start_machine
      worker_id = hub.register_worker(machine_id: machine_id)

      expect(hub.redis.zscore('workers:idle', worker_id)).to be_nil

      hub.set_worker_idle(worker_id: worker_id)
      expect(hub.redis.zscore('workers:idle', worker_id)).to eq(machine_id)

      hub._clear_worker_idle(worker_id: worker_id)
      expect(hub.redis.zscore('workers:idle', worker_id)).to be_nil
    end
  end
  describe '#_record_worker_stats' do
    it 'records the number of workers online (0) and idle (0)' do
      expect(hub.stats).to receive(:gauge).once.with('hub.workers.online', 0)
      expect(hub.stats).to receive(:gauge).once.with('hub.workers.idle', 0)
      hub._record_worker_stats
    end
    it 'records the number of workers online (1) and idle (0)' do
      hub.register_worker(machine_id: machine_id)
      expect(hub.stats).to receive(:gauge).once.with('hub.workers.online', 1)
      expect(hub.stats).to receive(:gauge).once.with('hub.workers.idle', 0)
      hub._record_worker_stats
    end
    it 'records the number of workers online (2) and idle (1)' do
      hub.register_worker(machine_id: machine_id)
      hub.set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))

      expect(hub.stats).to receive(:gauge).once.with('hub.workers.online', 2)
      expect(hub.stats).to receive(:gauge).once.with('hub.workers.idle', 1)
      hub._record_worker_stats
    end
  end
end
