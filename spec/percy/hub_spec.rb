RSpec.describe Percy::Hub do
  let(:hub) { Percy::Hub.new }
  let(:machine_id) { hub.start_machine }

  def create_idle_test_workers(num_workers)
    worker_ids = []
    num_workers.times do
      worker_id = hub.register_worker(machine_id: machine_id)
      hub.set_worker_idle(worker_id: worker_id)
      worker_ids << worker_id
    end
    worker_ids
  end

  describe '#set_subscription_locks_limit' do
    it 'inserts a snapshot job and updates relevant keys' do
      expect(hub.redis.get('jobs:created:counter')).to be_nil

      result = hub.set_subscription_locks_limit(subscription_id: 'foo:123', limit: 5)
      expect(hub.redis.get('subscription:foo:123:locks:limit').to_i).to eq(5)
    end
    it 'fails if given bad limit' do
      expect do
        hub.set_subscription_locks_limit(subscription_id: 'foo:123', limit: nil)
      end.to raise_error(TypeError)
    end
  end
  describe '#get_subscription_locks_limit' do
    it 'gets the set limit or default' do
      expect(hub.get_subscription_locks_limit(subscription_id: 'foo:123')).to eq(2)
      hub.set_subscription_locks_limit(subscription_id: 'foo:123', limit: 5)
      expect(hub.get_subscription_locks_limit(subscription_id: 'foo:123')).to eq(5)
    end
  end
  describe '#insert_job' do
    it 'inserts a snapshot job and updates relevant keys' do
      expect(hub.redis.get('jobs:created:counter')).to be_nil

      result = hub.insert_job(
        job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
      expect(result).to eq(1)
      expect(hub.redis.get('jobs:created:counter').to_i).to eq(1)
      expect(hub.redis.zscore('builds:active', 234)).to be > 1
      expect(hub.redis.get('build:234:subscription_id').to_i).to eq(345)
      expect(hub.redis.lrange('build:234:jobs:new', 0, 10)).to eq(['1'])

      expect(hub.redis.get('job:1:data')).to eq('process_comparison:123')
      expect(hub.redis.get('job:1:subscription_id').to_i).to eq(345)
      expect(hub.redis.get('job:1:build_id').to_i).to eq(234)
      expect(hub.redis.get('job:1:num_retries').to_i).to eq(0)
    end
    it 'is idempotent and re-uses the inserted_at score if present' do
      expect(hub.redis.get('jobs:created:counter')).to be_nil
      hub.insert_job(
        job_data: 'process_comparison:123',
        build_id: 234,
        subscription_id: 345,
        inserted_at: 20000,
      )
      expect(hub.redis.get('jobs:created:counter').to_i).to eq(1)
      expect(hub.redis.zscore('builds:active', 234)).to eq(20000)

      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
      expect(hub.redis.get('jobs:created:counter').to_i).to eq(2)
      expect(hub.redis.zscore('builds:active', 234)).to eq(20000)
    end
    it 'fails if given nil arguments' do
      expect do
        hub.insert_job(snapshot_id: nil, build_id: 234, subscription_id: 345)
      end.to raise_error(ArgumentError)
      expect do
        hub.insert_job(job_data: 'process_comparison:123', build_id: nil, subscription_id: 345)
      end.to raise_error(ArgumentError)
      expect do
        hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: nil)
      end.to raise_error(ArgumentError)
    end
    it 'fails if given bad job_data' do
      expect do
        hub.insert_job(job_data: 'bad-action-name:123', build_id: 234, subscription_id: 345)
      end.to raise_error(ArgumentError)
    end
  end
  describe '#get_job_data' do
    it 'returns the arbitrary job data' do
      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
      expect(hub.get_job_data(job_id: 1)).to eq('process_comparison:123')
    end
  end
  describe '#get_job_num_retries' do
    it 'returns the num_retries for job' do
      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
      expect(hub.get_job_num_retries(job_id: 1)).to eq(0)
    end
    it 'safely handles when num_retries does not exist (legacy backwards-compatibility)' do
      expect(hub.get_job_num_retries(job_id: 1)).to eq(0)
    end
  end
  describe '#_enqueue_jobs' do
    context 'with idle workers available' do
      before(:each) { create_idle_test_workers(5) }

      it 'enqueues all jobs if enough idle workers and subscription locks' do
        hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
        hub.insert_job(job_data: 'process_comparison:124', build_id: 234, subscription_id: 345)

        # Returns 0.5, indicating completion of all enqueuing.
        expect(hub._enqueue_jobs).to eq(0.5)

        expect(hub.redis.llen('jobs:runnable')).to eq(2)
      end
      it 'enqueues jobs from multiple builds if enough idle workers and subscription locks' do
        hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
        hub.insert_job(job_data: 'process_comparison:124', build_id: 234, subscription_id: 345)
        hub.insert_job(job_data: 'process_comparison:130', build_id: 235, subscription_id: 346)
        hub.insert_job(job_data: 'process_comparison:131', build_id: 235, subscription_id: 346)

        # Returns 0.5, indicating completion of all enqueuing.
        expect(hub._enqueue_jobs).to eq(0.5)

        expect(hub.redis.llen('jobs:runnable')).to eq(4)
      end
      it 'skips empty builds' do
        # Insert a job and then enqueue, so we leave a build ID in builds:active.
        job_id = hub.insert_job(
          job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
        expect(hub.redis.zcard('builds:active')).to eq(1)
        expect(hub._enqueue_jobs).to eq(0.5)

        # Build is still active, because it is not expired:
        expect(hub.redis.zcard('builds:active')).to eq(1)

        expect(hub.redis.llen('jobs:runnable')).to eq(1)
        expect(hub.redis.lrange('jobs:runnable', 0, 0)).to eq([job_id.to_s])
      end
      it 'skips empty builds and cleans up empty active builds after expiration' do
        # Insert a job and then enqueue, so we leave a build ID in builds:active.
        job_id = hub.insert_job(
          job_data: 'process_comparison:123',
          build_id: 234,
          subscription_id: 345,
          inserted_at: Time.now.to_i - Percy::Hub::DEFAULT_ACTIVE_BUILD_TIMEOUT_SECONDS - 1
        )
        expect(hub.redis.zcard('builds:active')).to eq(1)
        expect(hub._enqueue_jobs).to eq(0.5)

        # Build is cleaned up.
        expect(hub.redis.zcard('builds:active')).to eq(0)

        expect(hub.redis.llen('jobs:runnable')).to eq(1)
        expect(hub.redis.lrange('jobs:runnable', 0, 0)).to eq([job_id.to_s])
      end
      it 'enforces concurrency limits (default 2 per subscription)' do
        hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
        hub.insert_job(job_data: 'process_comparison:124', build_id: 234, subscription_id: 345)
        hub.insert_job(job_data: 'process_comparison:125', build_id: 234, subscription_id: 345)
        hub.insert_job(job_data: 'process_comparison:126', build_id: 234, subscription_id: 345)

        hub.insert_job(job_data: 'process_comparison:130', build_id: 235, subscription_id: 346)
        hub.insert_job(job_data: 'process_comparison:131', build_id: 235, subscription_id: 346)
        hub.insert_job(job_data: 'process_comparison:132', build_id: 235, subscription_id: 346)

        # Returns 0.5, indicating completion of all enqueuing.
        expect(hub._enqueue_jobs).to eq(0.5)

        # There are 2 enqueued jobs from the first subscription and 2 from the second.
        expect(hub.redis.llen('jobs:runnable')).to eq(4)
        expect(hub.redis.lrange('jobs:runnable', 0, 3)).to eq(['6', '5', '2', '1'])
      end
    end
    context 'with NO idle workers available' do
      it 'returns sleeptime 1 and does not enqueue jobs' do
        hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
        expect(hub._enqueue_jobs).to eq(1)
        expect(hub.redis.llen('jobs:runnable')).to eq(0)
      end
      it 'performs lock count check first before idle worker check' do
        hub.set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))
        hub.set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))
        hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
        hub.insert_job(job_data: 'process_comparison:124', build_id: 234, subscription_id: 345)
        hub.insert_job(job_data: 'process_comparison:124', build_id: 234, subscription_id: 345)

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
      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
      result = hub._enqueue_next_job(build_id: 234, subscription_id: 345)
      expect(result).to eq('no_idle_worker')
      expect(hub.redis.llen('jobs:runnable')).to eq(0)
    end
    it 'computes number of idle workers as idle workers minus the number of jobs:runnable' do
      # Create an idle worker and add a job to jobs:runnable.
      hub.set_worker_idle(worker_id: worker_id)
      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
      result = hub._enqueue_next_job(build_id: 234, subscription_id: 345)
      expect(result).to eq(1)
      expect(hub.redis.llen('jobs:runnable')).to eq(1)

      # The worker is idle but there is a job in jobs:runnable, so 'no_idle_worker' is returned.
      hub.insert_job(job_data: 'process_comparison:124', build_id: 234, subscription_id: 345)
      expect(hub._enqueue_next_job(build_id: 234, subscription_id: 345)).to eq('no_idle_worker')
    end
    it 'returns hit_lock_limit when concurrency limit is exceeded (and defaults limit to 2)' do
      worker_id_1, worker_id_2, worker_id_3 = create_idle_test_workers(3)

      first_job_id = hub.insert_job(
        job_data: 'process_comparison:123',
        build_id: 234,
        subscription_id: 345,
      )
      hub.insert_job(job_data: 'process_comparison:124', build_id: 234, subscription_id: 345)
      hub.insert_job(job_data: 'process_comparison:125', build_id: 234, subscription_id: 345)

      expect(hub.redis.llen('jobs:runnable')).to eq(0)
      expect(hub._enqueue_next_job(build_id: 234, subscription_id: 345)).to eq(1)
      expect(hub.redis.llen('jobs:runnable')).to eq(1)
      expect(hub._enqueue_next_job(build_id: 234, subscription_id: 345)).to eq(1)
      expect(hub.redis.llen('jobs:runnable')).to eq(2)
      expect(hub._enqueue_next_job(build_id: 234, subscription_id: 345)).to eq('hit_lock_limit')
      expect(hub.redis.llen('jobs:runnable')).to eq(2)

      # Release one of the subscription's locks and enqueue another job from the build.
      hub.cleanup_job(job_id: first_job_id)

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

      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
      hub.insert_job(job_data: 'process_comparison:124', build_id: 234, subscription_id: 345)
      hub.insert_job(job_data: 'process_comparison:1000', build_id: 234, subscription_id: 345)

      result = hub._enqueue_next_job(build_id: 234, subscription_id: 345)
      expect(result).to eq(1)

      tail_item = hub.redis.lindex('jobs:runnable', -1)
      expect(tail_item).to eq('1')
    end
  end
  describe '#remove_active_build' do
    it 'removes the build from builds:active' do
      hub.set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))
      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
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
      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)

      expect(hub.remove_active_build(build_id: 234)).to eq(false)
      expect(hub.redis.zscore('builds:active', 234)).to be > 1
      expect(hub.redis.get('build:234:subscription_id').to_i).to eq(345)
    end
  end
  describe '#start_machine' do
    it 'returns an incrementing id' do
      expect(hub.stats).to receive(:gauge).once.with('hub.machines.created.alltime', 1)
      expect(hub.stats).to receive(:gauge).once.with('hub.machines.created.alltime', 2)
      expect(hub.stats).to receive(:gauge).once.with('hub.machines.created.alltime', 3)
      expect(hub.start_machine).to eq(1)
      expect(hub.start_machine).to eq(2)
      expect(hub.start_machine).to eq(3)
      expect(hub.redis.get('machines:created:counter').to_i).to eq(3)
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
      expect(hub.redis.get('workers:created:counter').to_i).to eq(3)
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
    it 'fails if given nil machine_id' do
      expect { hub.register_worker(machine_id: nil) }.to raise_error(ArgumentError)
    end
  end
  describe '#worker_heartbeat' do
    it 'sets the worker score in workers:heartbeat to the current time' do
      worker_id = hub.register_worker(machine_id: machine_id)
      hub.worker_heartbeat(worker_id: worker_id)
      expect(hub.redis.zscore('workers:heartbeat', worker_id)).to be_within(1).of(Time.now.to_i)
    end
    it 'accepts an offset' do
      worker_id = hub.register_worker(machine_id: machine_id)
      hub.worker_heartbeat(worker_id: worker_id, offset_seconds: 10)
      expect(hub.redis.zscore('workers:heartbeat', worker_id)).to_not be_within(1).of(Time.now.to_i)
    end
    it 'fails if worker is not online' do
      expect do
        hub.worker_heartbeat(worker_id: 123)
      end.to raise_error(Percy::Hub::DeadWorkerError)
    end
  end
  describe '#list_workers_by_heartbeat' do
    it 'finds worker heartbeats older than some number of seconds' do
      worker_id = hub.register_worker(machine_id: machine_id)
      hub.worker_heartbeat(worker_id: worker_id)

      expect(hub.list_workers_by_heartbeat(older_than_seconds: 0)).to eq([worker_id.to_s])
      expect(hub.list_workers_by_heartbeat(older_than_seconds: 1)).to eq([])
      expect(hub.list_workers_by_heartbeat(older_than_seconds: 10)).to eq([])
    end
  end
  describe '#remove_worker' do
    it 'removes worker related keys' do
      worker_id = hub.register_worker(machine_id: machine_id)
      hub.set_worker_idle(worker_id: worker_id)
      hub.worker_heartbeat(worker_id: worker_id)
      expect(hub.redis.zscore('workers:online', worker_id)).to be
      expect(hub.redis.zscore('workers:idle', worker_id)).to be
      expect(hub.redis.zscore('workers:heartbeat', worker_id)).to be

      hub.remove_worker(worker_id: worker_id)
      expect(hub.redis.zscore('workers:online', worker_id)).to_not be
      expect(hub.redis.zscore('workers:idle', worker_id)).to_not be
      expect(hub.redis.zscore('workers:heartbeat', worker_id)).to_not be
    end
    it 'pushes orphaned jobs from worker:<id>:runnable into jobs:orphaned' do
      worker_id = hub.register_worker(machine_id: machine_id)
      hub.set_worker_idle(worker_id: worker_id)
      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
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
      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
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
  describe '#_reap_workers' do
    it 'removes workers that have not sent a heartbeat recently' do
      dead_worker_id = hub.register_worker(machine_id: machine_id)
      alive_worker_id = hub.register_worker(machine_id: machine_id)

      hub.worker_heartbeat(worker_id: dead_worker_id)
      hub.worker_heartbeat(worker_id: alive_worker_id, offset_seconds: 10)

      all_worker_ids = [dead_worker_id.to_s, alive_worker_id.to_s]
      expect(hub.redis.zrange('workers:online', 0, 10)).to eq(all_worker_ids)

      expect(hub._reap_workers(older_than_seconds: 0)).to eq(5)
      expect(hub.redis.zrange('workers:online', 0, 10)).to eq([alive_worker_id.to_s])
    end
    it 'schedules orphaned jobs' do
      # Create a dead worker with a job in worker:<id>:running.
      worker_id = hub.register_worker(machine_id: machine_id)
      hub.worker_heartbeat(worker_id: worker_id)
      hub.set_worker_idle(worker_id: worker_id)
      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
      hub._enqueue_jobs
      hub._schedule_next_job
      hub.wait_for_job(worker_id: worker_id)

      # Create a dead worker with a job in worker:<id>:runnable.
      worker_id = hub.register_worker(machine_id: machine_id)
      hub.worker_heartbeat(worker_id: worker_id)
      hub.set_worker_idle(worker_id: worker_id)
      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
      hub._enqueue_jobs
      hub._schedule_next_job

      expect(hub.redis.get('job:1:data')).to be
      expect(hub.redis.get('job:2:data')).to be
      expect(hub._reap_workers(older_than_seconds: 0)).to eq(5)
      expect(hub.redis.get('job:1:data')).to_not be
      expect(hub.redis.get('job:2:data')).to_not be
      expect(hub.redis.get('job:3:data')).to be
      expect(hub.redis.get('job:4:data')).to be

      # Run again to make sure that orphaned jobs were popped and cleaned up correctly.
      expect(hub._reap_workers(older_than_seconds: 0)).to eq(5)
    end
  end
  describe '#_release_expired_locks' do
    before(:each) { create_idle_test_workers(3) }

    it 'releases locks that have expired' do
      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)

      enqueued_at = Time.now.to_i - Percy::Hub::DEFAULT_EXPIRED_LOCK_TIMEOUT_SECONDS - 1
      hub._enqueue_next_job(build_id: 234, subscription_id: 345, enqueued_at: enqueued_at)
      hub._enqueue_next_job(build_id: 234, subscription_id: 345, enqueued_at: enqueued_at)
      hub._enqueue_next_job(build_id: 234, subscription_id: 345) # Intetionally exclude enqueued_at.

      expect(hub._release_expired_locks(subscription_id: 345)).to eq(2)
    end
    it 'does nothing when no locks exist' do
      expect(hub._release_expired_locks(subscription_id: 345)).to eq(0)
    end
    it 'does nothing when locks exist but are not expired' do
      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
      hub._enqueue_next_job(build_id: 234, subscription_id: 345)

      expect(hub._release_expired_locks(subscription_id: 345)).to eq(0)
    end
  end
  describe '#_schedule_next_job' do
    it 'returns 0 and pops job from jobs:runnable to an idle worker' do
      first_worker_id = hub.register_worker(machine_id: machine_id)
      second_worker_id = hub.register_worker(machine_id: machine_id)
      hub.set_worker_idle(worker_id: second_worker_id)

      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
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
      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
      hub._enqueue_jobs
      hub.clear_worker_idle(worker_id: worker_id)

      expect(hub.redis.llen('jobs:runnable')).to eq(1)
      expect(hub.redis.llen('jobs:scheduling')).to eq(0)
      expect(hub.redis.llen("worker:#{worker_id}:runnable")).to eq(0)
      expect(hub._schedule_next_job).to eq(1)

      # Idempotent check:
      expect(hub._schedule_next_job).to eq(1)

      # And back to success:
      hub.set_worker_idle(worker_id: worker_id)
      expect(hub._schedule_next_job).to eq(0)
      expect(hub.redis.llen('jobs:runnable')).to eq(0)
      expect(hub.redis.llen('jobs:scheduling')).to eq(0)
      expect(hub.redis.llen("worker:#{worker_id}:runnable")).to eq(1)
    end
    it 'handles jobs that might be orphaned in jobs:scheduling' do
      worker_id = hub.register_worker(machine_id: machine_id)
      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
      hub.set_worker_idle(worker_id: worker_id)
      hub._enqueue_jobs
      expect(hub.redis.llen('jobs:runnable')).to eq(1)
      expect(hub.redis.llen('jobs:scheduling')).to eq(0)

      # Manually force the enqueued job into jobs:scheduling.
      hub.redis.rpoplpush('jobs:runnable', 'jobs:scheduling')

      expect(hub._schedule_next_job).to eq(0)

      expect(hub.redis.llen('jobs:runnable')).to eq(0)
      expect(hub.redis.llen('jobs:scheduling')).to eq(0)
      expect(hub.redis.llen("worker:#{worker_id}:runnable")).to eq(1)
    end
  end
  describe '#wait_for_job' do
    let!(:worker_id) { create_idle_test_workers(1).first }

    it 'returns the next runnable job on the worker' do
      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
      hub._enqueue_jobs
      hub._schedule_next_job

      result = hub.wait_for_job(worker_id: worker_id)
      expect(result).to eq('1')
      expect(hub.redis.llen("worker:#{worker_id}:runnable")).to eq(0)
      expect(hub.redis.lindex("worker:#{worker_id}:running", 0)).to eq('1')
    end
    it 'waits for timeout seconds if no jobs are available, and returns nil for no jobs' do
      expect(hub.redis).to receive(:brpoplpush)
        .with(
          "worker:#{worker_id}:runnable",
          "worker:#{worker_id}:running",
          Percy::Hub::DEFAULT_TIMEOUT_SECONDS
        )
        .and_return(nil)
      expect(hub.wait_for_job(worker_id: worker_id)).to be_nil
    end
    it 'returns nil if a redis timeout occurs' do
      expect(hub.redis).to receive(:brpoplpush)
        .with(
          "worker:#{worker_id}:runnable",
          "worker:#{worker_id}:running",
          Percy::Hub::DEFAULT_TIMEOUT_SECONDS
        )
        .and_raise(Redis::TimeoutError)
      expect(hub.wait_for_job(worker_id: worker_id)).to be_nil
    end
    it 'returns already claimed job if a redis timeout and race occurs' do
      # A job has been scheduled on this worker.
      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
      hub._enqueue_jobs
      hub._schedule_next_job

      expect(hub.redis).to receive(:brpoplpush).once do
        # Simulate timeout race condition (this is a real regression test): the brpoplpush command
        # is successful, but the timeout is reached at the same time and so a job is moved into
        # the :running queue but is not actually returned by wait_for_job.
        Percy::Hub.new.redis.brpoplpush(
          "worker:#{worker_id}:runnable",
          "worker:#{worker_id}:running",
          Percy::Hub::DEFAULT_TIMEOUT_SECONDS,
        )
        raise Redis::TimeoutError
      end

      # First time: we receive nil, but the job was actually pushed underneath.
      expect(hub.wait_for_job(worker_id: worker_id)).to be_nil
      expect(hub.redis.lrange("worker:#{worker_id}:runnable", 0, 100)).to eq([])
      expect(hub.redis.lrange("worker:#{worker_id}:running", 0, 100)).to eq(['1'])

      # Second time: we receive the job that we should have received the first time.
      expect(hub.wait_for_job(worker_id: worker_id)).to eq('1')
      expect(hub.redis.lrange("worker:#{worker_id}:runnable", 0, 100)).to eq([])
      expect(hub.redis.lrange("worker:#{worker_id}:running", 0, 100)).to eq(['1'])
    end
  end
  describe '#worker_job_complete' do
    let(:worker_id) { hub.register_worker(machine_id: machine_id) }

    before(:each) do
      hub.set_worker_idle(worker_id: worker_id)
      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
      hub._enqueue_jobs
      hub._schedule_next_job
      hub.wait_for_job(worker_id: worker_id)
    end
    it 'removes the job from the worker:<id>:running queue' do
      expect(hub.redis.lrange("worker:#{worker_id}:running", 0, 10)).to eq(['1'])
      hub.worker_job_complete(worker_id: worker_id)
      expect(hub.redis.lrange("worker:#{worker_id}:running", 0, 10)).to eq([])
    end
    it 'returns nil if no job was running' do
      expect(hub.stats).to_not receive(:increment)
      expect(hub.worker_job_complete(worker_id: 999)).to be_nil
    end
  end
  describe '#retry_job' do
    it 'inserts a new job with the same job data' do
      expect(hub.stats).to receive(:increment).once.with('hub.jobs.retried').and_call_original

      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
      expect(hub.redis.get('job:1:data')).to be

      # Make sure insert_job gets called correctly, so then we can weakly check some data.
      expect(hub).to receive(:insert_job)
        .once.with(
          job_data: 'process_comparison:123',
          build_id: '234',
          subscription_id: '345',
          num_retries: 1,
        )
        .and_call_original
      expect(hub.retry_job(job_id: 1)).to eq(2)
      expect(hub.redis.get('job:2:data')).to be
    end
    it 'increments num_retries each time a job is retried' do
      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
      expect(Integer(hub.redis.get('job:1:num_retries'))).to eq(0)
      expect(hub.retry_job(job_id: 1)).to eq(2)
      expect(Integer(hub.redis.get('job:2:num_retries'))).to eq(1)
      expect(hub.retry_job(job_id: 2)).to eq(3)
      expect(Integer(hub.redis.get('job:3:num_retries'))).to eq(2)
    end
    it 'handles backwards-compatibility with no num_retries key existing' do
      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
      hub.redis.del('job:1:num_retries')
      expect(hub.retry_job(job_id: 1)).to eq(2)
    end
  end
  describe '#cleanup_job' do
    it 'removes job related keys' do
      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
      expect(hub.redis.get('job:1:data')).to be
      expect(hub.redis.get('job:1:build_id')).to be
      expect(hub.redis.get('job:1:subscription_id')).to be
      expect(hub.redis.get('job:1:num_retries')).to be

      expect(hub.stats).to receive(:time).once.with('hub.methods.cleanup_job').and_call_original
      hub.cleanup_job(job_id: 1)
      expect(hub.redis.get('job:1:data')).to be_nil
      expect(hub.redis.get('job:1:build_id')).to be_nil
      expect(hub.redis.get('job:1:subscription_id')).to be_nil
      expect(hub.redis.get('job:1:num_retries')).to be_nil
    end
    it 'releases a subscription lock' do
      worker_id = create_idle_test_workers(1).first
      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
      hub._enqueue_jobs
      hub._schedule_next_job
      hub.wait_for_job(worker_id: worker_id)

      expect(hub.redis.zcount('subscription:345:locks:claimed', '-inf', '+inf')).to eq(1)
      hub.cleanup_job(job_id: 1)
      expect(hub.redis.zcount('subscription:345:locks:claimed', '-inf', '+inf')).to eq(0)
    end
    it 'records stats' do
      job_id = hub.insert_job(
        job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)

      expect(hub.stats).to receive(:increment).once.with('hub.jobs.completed').and_call_original
      expect(hub.stats).to receive(:gauge)
        .once.with('hub.jobs.completed.alltime', 1).and_call_original

      hub.cleanup_job(job_id: job_id)
    end
    it 'returns false if no job exists to cleanup' do
      hub.insert_job(job_data: 'process_comparison:123', build_id: 234, subscription_id: 345)
      expect(hub.cleanup_job(job_id: 1)).to eq(true)
      expect(hub.cleanup_job(job_id: 1)).to eq(false)
    end
  end
  describe '#get_monthly_usage' do
    it 'gets the current month subscription usage' do
      expect(hub.get_monthly_usage(subscription_id: 345)).to eq(0)
      expect(hub.increment_monthly_usage(subscription_id: 345)).to eq(1)
      expect(hub.get_monthly_usage(subscription_id: 345)).to eq(1)
      expect(hub.increment_monthly_usage(subscription_id: 345)).to eq(2)
      expect(hub.get_monthly_usage(subscription_id: 345)).to eq(2)
    end
  end
  describe '#increment_monthly_usage' do
    it 'increments a per-month counter for the subscription' do
      expect(hub.increment_monthly_usage(subscription_id: 345)).to eq(1)
      expect(hub.increment_monthly_usage(subscription_id: 345)).to eq(2)

      year = Time.now.strftime('%Y')
      month = Time.now.strftime('%m')
      expect(hub.redis.get("subscription:345:usage:#{year}:#{month}:counter")).to eq('2')
    end
    it 'accepts an increment count' do
      expect(hub.increment_monthly_usage(subscription_id: 345)).to eq(1)
      expect(hub.increment_monthly_usage(subscription_id: 345, count: 90)).to eq(91)
    end
  end
  describe '#clear_worker_idle and #set_worker_idle' do
    it 'adds or removes worker from workers:idle' do
      machine_id = hub.start_machine
      worker_id = hub.register_worker(machine_id: machine_id)

      expect(hub.redis.zscore('workers:idle', worker_id)).to be_nil

      hub.set_worker_idle(worker_id: worker_id)
      expect(hub.redis.zscore('workers:idle', worker_id)).to eq(machine_id)

      hub.clear_worker_idle(worker_id: worker_id)
      expect(hub.redis.zscore('workers:idle', worker_id)).to be_nil
    end
    it 'fails if worker is not online' do
      expect do
        hub.set_worker_idle(worker_id: 123)
      end.to raise_error(Percy::Hub::DeadWorkerError)
    end
  end
  describe '#get_all_subscription_data' do
    it 'returns an empty hash if no data is present' do
      expect(hub.get_all_subscription_data).to eq({})
    end
    it 'returns a hash of subscription_id to usage data' do
      hub.increment_monthly_usage(subscription_id: 345)
      hub.increment_monthly_usage(subscription_id: 346, count: 90)

      expect(hub.get_all_subscription_data).to eq({
        '345' => '1',
        '346' => '90',
      })
    end
    it 'supports year and month arguments' do
      hub.increment_monthly_usage(subscription_id: 345)
      year = Time.now.strftime('%Y')
      month = Time.now.strftime('%m')
      expect(hub.get_all_subscription_data(year: year, month: month)).to eq({'345' => '1'})
      expect(hub.get_all_subscription_data(year: 1960, month: 12)).to eq({})
    end
  end
  describe '#_record_worker_stats' do
    it 'records the number of workers online (0) and idle (0)' do
      expect(hub.stats).to receive(:gauge).once.with('hub.workers.online', 0)
      expect(hub.stats).to receive(:gauge).once.with('hub.workers.idle', 0)
      expect(hub.stats).to receive(:gauge).once.with('hub.workers.processing', 0)
      hub._record_worker_stats
    end
    it 'records the number of workers online (1) and idle (0)' do
      hub.register_worker(machine_id: machine_id)
      expect(hub.stats).to receive(:gauge).once.with('hub.workers.online', 1)
      expect(hub.stats).to receive(:gauge).once.with('hub.workers.idle', 0)
      expect(hub.stats).to receive(:gauge).once.with('hub.workers.processing', 1)
      hub._record_worker_stats
    end
    it 'records the number of workers online (2) and idle (1)' do
      hub.register_worker(machine_id: machine_id)
      hub.set_worker_idle(worker_id: hub.register_worker(machine_id: machine_id))

      expect(hub.stats).to receive(:gauge).once.with('hub.workers.online', 2)
      expect(hub.stats).to receive(:gauge).once.with('hub.workers.idle', 1)
      expect(hub.stats).to receive(:gauge).once.with('hub.workers.processing', 1)
      hub._record_worker_stats
    end
  end
end
