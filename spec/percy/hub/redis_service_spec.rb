RSpec.describe Percy::Hub::RedisService do
  let(:hub) { Percy::Hub.new }

  describe '#redis' do
    it 'returns a client' do
      expect(hub.redis).to be
    end
  end
  describe '#reset_redis_connection' do
    it 'clears the instance variable and disconnects ' do
      old_redis = hub.redis
      old_redis.get('test')
      expect(old_redis.connected?).to eq(true)
      hub.reset_redis_connection
      expect(hub.redis).to_not eq(old_redis)
      expect(old_redis.connected?).to eq(false)
    end
  end
end

