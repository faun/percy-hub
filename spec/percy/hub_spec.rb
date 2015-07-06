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
      expect(hub.redis.ttl('build:234:subscription_id').to_i).to be > 604000
      expect(hub.redis.zscore('build:234:jobs', 'process_snapshot:123')).to eq(0)
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
end

