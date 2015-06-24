RSpec.describe Percy::Hub::RedisService do
  let(:hub) { Percy::Hub.new }

  describe '#build_key' do
    it 'works for all valid keys' do
      expect(hub.build_key(:worker, 1, :lock)).to eq('worker:1:lock')
      expect(hub.build_key(:worker, 1, :jobs)).to eq('worker:1:jobs')
      expect(hub.build_key(:worker, 1, :idle)).to eq('worker:1:idle')
      expect(hub.build_key(:worker, 1, :keepalive_lock)).to eq('worker:1:keepalive_lock')
      expect(hub.build_key(:worker, 1, :last_finished_at)).to eq('worker:1:last_finished_at')
    end
    it 'fails for any other key' do
      expect { hub.build_key(:worker, 1, :fake) }.to raise_error(ArgumentError)
    end
  end
end

