RSpec.describe Percy::Hub::RedisConnection do
  let(:hub) { Percy::Hub.new }

  describe '#redis' do
    context 'without any environment variables' do
      let(:client_connection) { hub.redis.connection }
      let(:host) { 'redis' }
      let(:port) { 6379 }
      let(:db) { 7 }

      it 'has the default configuration' do
        expect(client_connection.dig(:host)).to eq(host)
        expect(client_connection.dig(:port)).to eq(port)
        expect(client_connection.dig(:db)).to eq(db)
        expect(client_connection.dig(:location)).to eq("#{host}:#{port}")
      end

      it 'returns a client' do
        expect(hub.redis).to be
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

      let(:host) { 'redis' }
      let(:port) { 6379 }
      let(:db) { 7 }
      let(:client_connection) { hub.redis.connection }

      it 'has the correct configuration' do
        expect(client_connection.dig(:host)).to eq(host)
        expect(client_connection.dig(:port)).to eq(port)
        expect(client_connection.dig(:db)).to eq(db)
        expect(client_connection.dig(:location)).to eq("#{host}:#{port}")
      end

      it 'returns a client' do
        expect(hub.redis).to be
      end
    end

    context 'with legacy redis environment variables and an explicit url' do
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

      let(:redis_url) { "redis://#{host}:#{port}/10" }
      let(:hub) { Percy::Hub.new(url: redis_url, timeout: 30) }
      let(:host) { 'redis' }
      let(:port) { 6379 }
      let(:db) { 7 }
      let(:client_connection) { hub.redis.connection }

      it 'has the correct configuration' do
        expect(client_connection.dig(:host)).to eq(host)
        expect(client_connection.dig(:port)).to eq(port)
        expect(client_connection.dig(:db)).to eq(10)
        expect(client_connection.dig(:location)).to eq("#{host}:#{port}")
        expect(client_connection.dig(:id)).to eq(redis_url)
      end

      it 'returns a client' do
        expect(hub.redis).to be
      end
    end

    context 'when REDIS_HOST is not defined but HUB_REDIS_URL is' do
      around(:each) do |ex|
        original_redis_host = ENV['REDIS_HOST']
        original_redis_url = ENV['HUB_REDIS_URL']
        ENV['REDIS_HOST'] = nil
        ENV['HUB_REDIS_URL'] = redis_url
        ex.run
        ENV['HUB_REDIS_URL'] = original_redis_url
        ENV['REDIS_HOST'] = original_redis_host
      end

      let(:scheme) { 'redis://' }
      let(:host) { 'redis' }
      let(:port) { 6379 }
      let(:db) { 7 }
      let(:redis_url) { "#{scheme}#{host}:#{port}/#{db}" }
      let(:client_connection) { hub.redis.connection }

      it 'has the correct configuration' do
        expect(client_connection.dig(:host)).to eq(host)
        expect(client_connection.dig(:port)).to eq(port)
        expect(client_connection.dig(:db)).to eq(db)
        expect(client_connection.dig(:location)).to eq("#{host}:#{port}")
      end

      it 'returns a client' do
        expect(hub.redis).to be
      end
    end

    context 'when passing an existing redis instance' do
      let(:hub) { Percy::Hub.new(redis: redis_instance) }
      let(:scheme) { 'redis://' }
      let(:host) { 'redis' }
      let(:port) { 6379 }
      let(:db) { 7 }
      let(:redis_url) { "#{scheme}#{host}:#{port}/#{db}" }
      let(:redis_instance) { Percy::RedisClient.new(url: redis_url).client }
      let(:client_connection) { hub.redis.connection }

      it 'has the correct configuration' do
        expect(client_connection.dig(:host)).to eq(host)
        expect(client_connection.dig(:port)).to eq(port)
        expect(client_connection.dig(:db)).to eq(db)
        expect(client_connection.dig(:location)).to eq("#{host}:#{port}")
      end

      it 'returns the existing redis client' do
        expect(hub.redis).to eq(redis_instance)
      end
    end

    context 'when passing a proc as a redis instance' do
      let(:hub) { Percy::Hub.new(redis: redis_conn) }
      let(:scheme) { 'redis://' }
      let(:host) { 'redis' }
      let(:port) { 6379 }
      let(:db) { 7 }
      let(:redis_url) { "#{scheme}#{host}:#{port}/#{db}" }
      let(:client_connection) { hub.redis.connection }
      let(:redis_conn) do
        proc {
          Percy::RedisClient.new(
            url: redis_url,
          ).client
        }
      end

      it 'has the correct configuration' do
        expect(client_connection.dig(:host)).to eq(host)
        expect(client_connection.dig(:port)).to eq(port)
        expect(client_connection.dig(:db)).to eq(db)
        expect(client_connection.dig(:location)).to eq("#{host}:#{port}")
      end

      it 'returns the existing redis client' do
        expect(hub.redis).to eq(redis_instance)
      end

      it 'can call hub methods using redis client' do
        expect(hub.get_global_locks_limit).to eq(10000)
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
