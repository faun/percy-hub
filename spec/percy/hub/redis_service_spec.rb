RSpec.describe Percy::Hub::RedisService do
  let(:hub) { Percy::Hub.new }

  describe '#redis' do
    it 'returns a client' do
      expect(hub.redis).to be
    end

    context 'without any environment variables' do
      let(:client_connection) { hub.redis.connection }
      let(:host) { ENV['REDIS_HOST'] || '127.0.0.1' }
      let(:port) { 6379 }
      let(:db) { 7 }

      it 'has the default configuration' do
        expect(client_connection.dig(:host)).to eq(host)
        expect(client_connection.dig(:port)).to eq(port)
        expect(client_connection.dig(:db)).to eq(db)
        expect(client_connection.dig(:location)).to eq("#{host}:#{port}")
      end
    end

    context 'with legacy redis environment variables' do
      around(:each) do |ex|
        original_redis_host = ENV['REDIS_HOST']
        original_redis_db = ENV['REDIS_DB']
        original_redis_port = ENV['REDIS_PORT']
        ENV['REDIS_HOST'] = host
        ENV['REDIS_DB'] = db.to_s
        ENV['REDIS_PORT'] = port.to_s
        ex.run
        ENV['REDIS_HOST'] = original_redis_host
        ENV['REDIS_DB'] = original_redis_db
        ENV['REDIS_PORT'] = original_redis_port
      end

      let(:host) { ENV['REDIS_HOST'] || 'localhost' }
      let(:port) { 6379 }
      let(:db) { 10 }
      let(:client_connection) { hub.redis.connection }

      it 'has the correct configuration' do
        expect(client_connection.dig(:host)).to eq(host)
        expect(client_connection.dig(:port)).to eq(port)
        expect(client_connection.dig(:db)).to eq(db)
        expect(client_connection.dig(:location)).to eq("#{host}:#{port}")
      end
    end

    context 'with HUB_REDIS_URL environment variable' do
      around(:each) do |ex|
        original_redis_url = ENV['HUB_REDIS_URL']
        ENV['HUB_REDIS_URL'] = redis_url
        ex.run
        ENV['HUB_REDIS_URL'] = original_redis_url
      end

      let(:scheme) { 'redis://' }
      let(:host) { ENV['REDIS_HOST'] || 'localhost' }
      let(:port) { 6379 }
      let(:db) { 10 }
      let(:redis_url) { "#{scheme}#{host}:#{port}/#{db}" }
      let(:client_connection) { hub.redis.connection }

      it 'has the correct configuration' do
        expect(client_connection.dig(:host)).to eq(host)
        expect(client_connection.dig(:port)).to eq(port)
        expect(client_connection.dig(:db)).to eq(db)
        expect(client_connection.dig(:location)).to eq("#{host}:#{port}")
      end
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
