RSpec.describe Percy::Hub::RedisService do
  let(:hub) { Percy::Hub.new }

  describe '#redis' do
    it 'returns a client' do
      expect(hub.redis).to be
    end
  end
end

