RSpec.describe Percy::Hub::RedisService do
  let(:hub) { Percy::Hub.new }

  describe '#redis' do
    it 'returns a client' do
      expect(hub.redis).to be
    end
  end
  describe '#disconnect_redis' do
    it 'clears the instance variable' do
      old_redis = hub.redis
      hub.disconnect_redis
      expect(hub.redis).to_not eq(old_redis)
    end
  end
end

