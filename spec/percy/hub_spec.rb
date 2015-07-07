RSpec.describe Percy::Hub do
  let(:hub) { Percy::Hub.new }

  describe '#insert_snapshot_job' do
    it 'inserts a snapshot job and updates relevant keys' do
      expect(hub.redis.get('jobs:created:counter')).to be_nil

      result = hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
      expect(result).to eq(1)
      expect(hub.redis.get('jobs:created:counter').to_i).to eq(1)
      expect(hub.redis.zscore('builds:active', 234)).to be > 1
      expect(hub.redis.get('build:234:subscription_id').to_i).to eq(345)
      expect(hub.redis.lindex('build:234:jobs:new', -1)).to eq('process_snapshot:123')
    end
    it 'is idempotent and re-uses the inserted_at score if present' do
      expect(hub.redis.get('jobs:created:counter')).to be_nil
      hub.insert_snapshot_job(
        snapshot_id: 123,
        build_id: 234,
        subscription_id: 345,
        inserted_at: 20000,
      )
      expect(hub.redis.get('jobs:created:counter').to_i).to eq(1)
      expect(hub.redis.zscore('builds:active', 234)).to eq(20000)

      hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
      expect(hub.redis.get('jobs:created:counter').to_i).to eq(2)
      expect(hub.redis.zscore('builds:active', 234)).to eq(20000)
    end
  end
  describe '#_enqueue_jobs' do
    let(:machine_id) { hub.start_machine }

    context 'with idle workers available' do
      before(:each) do
        hub._set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))
        hub._set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))
        hub._set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))
        hub._set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))
        hub._set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))
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
        hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
        expect(hub._enqueue_jobs).to eq(0.5)
        expect(hub.redis.llen('jobs:runnable')).to eq(1)

        # Insert a new job from a different build.
        expect(hub.redis.zcard('builds:active')).to eq(1)
        hub.insert_snapshot_job(snapshot_id: 130, build_id: 235, subscription_id: 346)
        expect(hub.redis.zcard('builds:active')).to eq(2)

        # Returns 0.5, indicating completion of all enqueuing.
        expect(hub._enqueue_jobs).to eq(0.5)

        expect(hub.redis.llen('jobs:runnable')).to eq(2)
        expect(hub.redis.lrange('jobs:runnable', 0, 1)).to eq([
          'process_snapshot:130',
          'process_snapshot:123',
        ])
        # TODO: assert that cleanup_inactive_build is called.
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
        expect(hub.redis.lrange('jobs:runnable', 0, 3)).to eq([
          'process_snapshot:131',
          'process_snapshot:130',
          'process_snapshot:124',
          'process_snapshot:123',
        ])
      end
    end
    context 'with NO idle workers available' do
      it 'returns 1 (sleeptime before next run) and does not enqueue jobs' do
        hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
        expect(hub._enqueue_jobs).to eq(1)
        expect(hub.redis.llen('jobs:runnable')).to eq(0)
      end
      it 'performs idle worker check first, before concurrency limit check, to avoid spinning' do
        hub._set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))
        hub._set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))
        hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
        hub.insert_snapshot_job(snapshot_id: 124, build_id: 234, subscription_id: 345)
        hub.insert_snapshot_job(snapshot_id: 124, build_id: 234, subscription_id: 345)

        # This magic "1" indicates the no_idle_worker sleeptime path.
        expect(hub._enqueue_jobs).to eq(1)
        expect(hub.redis.llen('jobs:runnable')).to eq(2)
      end
    end
    it 'returns 2 (sleeptime) if there are no active builds' do
      expect(hub._enqueue_jobs).to eq(2)
    end
  end
  describe '#_enqueue_next_job' do
    let(:machine_id) { hub.start_machine }
    let(:worker_id) { hub.register_worker(machine_id: machine_id) }

    it 'returns no_idle_worker if there are no idle workers available' do
      hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
      result = hub._enqueue_next_job(build_id: 234, subscription_id: 345)
      expect(result).to eq('no_idle_worker')
      expect(hub.redis.llen('jobs:runnable')).to eq(0)
    end
    it 'computes number of idle workers as idle workers minus the number of jobs:runnable' do
      # Create an idle worker and add a job to jobs:runnable.
      hub._set_worker_idle(worker_id: worker_id)
      hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
      result = hub._enqueue_next_job(build_id: 234, subscription_id: 345)
      expect(result).to eq(1)
      expect(hub.redis.llen('jobs:runnable')).to eq(1)

      # The worker is idle but there is a job in jobs:runnable, so 'no_idle_worker' is returned.
      hub.insert_snapshot_job(snapshot_id: 124, build_id: 234, subscription_id: 345)
      expect(hub._enqueue_next_job(build_id: 234, subscription_id: 345)).to eq('no_idle_worker')
    end
    it 'returns hit_lock_limit when concurrency limit is exceeded (and defaults limit to 2)' do
      hub._set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))
      hub._set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))
      hub._set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))

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
      hub._set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))
      result = hub._enqueue_next_job(build_id: 234, subscription_id: 345)
      expect(result).to eq(0)
    end
    it 'returns 1 and moves the earliest job into jobs:runnable if there is an idle worker' do
      hub._set_worker_idle(worker_id: worker_id)

      hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)
      hub.insert_snapshot_job(snapshot_id: 124, build_id: 234, subscription_id: 345)
      hub.insert_snapshot_job(snapshot_id: 1000, build_id: 234, subscription_id: 345)

      result = hub._enqueue_next_job(build_id: 234, subscription_id: 345)
      expect(result).to eq(1)

      tail_item = hub.redis.lindex('jobs:runnable', -1)
      expect(tail_item).to eq('process_snapshot:123')
    end
  end
  describe '#start_machine' do
    it 'returns an incrementing id' do
      expect(hub.start_machine).to eq(1)
      expect(hub.start_machine).to eq(2)
      expect(hub.start_machine).to eq(3)
    end
    it 'sets started_at and an expiration' do
      machine_id = hub.start_machine
      expect(hub.redis.get("machine:#{machine_id}:started_at").to_i).to be > 1
      expect(hub.redis.ttl("machine:#{machine_id}:started_at").to_i).to be > 80000
    end
  end
  describe '#register_worker' do
    let(:machine_id) { hub.start_machine }
    it 'returns an incrementing id' do
      expect(hub.register_worker(machine_id: machine_id)).to eq(1)
      expect(hub.register_worker(machine_id: machine_id)).to eq(2)
      expect(hub.register_worker(machine_id: machine_id)).to eq(3)
    end
    it 'adds the worker to workers:online and records startup time' do
      expect(hub.stats).to receive(:histogram).once
        .with('hub.worker.startup_time', kind_of(Numeric)).and_call_original

      worker_id = hub.register_worker(machine_id: machine_id)
      expect(hub.redis.zscore('workers:online', worker_id)).to eq(machine_id)
    end
    it 'works if the machine started_at time has expired' do
      expect(hub.stats).to_not receive(:histogram)
      hub.redis.del("machine:#{machine_id}:started_at")
      worker_id = hub.register_worker(machine_id: machine_id)
    end
  end
end

