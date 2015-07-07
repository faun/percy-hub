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
      expect(hub.redis.ttl('build:234:subscription_id').to_i).to be > 600000
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
  describe '#_enqueue_jobs_for_build' do
    it 'returns the number of jobs enqueued' do
      hub.insert_snapshot_job(snapshot_id: 123, build_id: 234, subscription_id: 345)

      hub._enqueue_jobs_for_build(build_id: 234, subscription_id: 345)

      expect(hub.redis.lindex('jobs:runnable', -1)).to eq('process_snapshot:123')
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
  end
end

