RSpec.describe Percy::Hub::RedisService do
  let(:hub) { Percy::Hub.new }

  describe '#build_key' do
    it 'works for all valid keys' do
      expect(hub.build_key('builds:active')).to eq('builds:active')
      expect(hub.build_key(:build, 234, :subscription_id)).to eq('build:234:subscription_id')
      expect(hub.build_key(:build, 234, :jobs)).to eq('build:234:jobs')
      expect(hub.build_key('jobs:created:counter')).to eq('jobs:created:counter')
    end
    it 'fails for any other key' do
      expect { hub.build_key(:worker, 1, :fake) }.to raise_error(NotImplementedError)
    end
  end
end

