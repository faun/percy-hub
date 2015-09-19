RSpec.describe Percy::Hub::RedisService do
  let(:hub) { Percy::Hub.new }

  describe '#redis' do
    it 'returns a client' do
      expect(hub.redis).to be
    end
  end
  describe '#reset_redis_connection' do
    it 'clears the instance variable' do
      old_redis = hub.redis
      hub.reset_redis_connection
      expect(hub.redis).to_not eq(old_redis)
    end
  end
end

