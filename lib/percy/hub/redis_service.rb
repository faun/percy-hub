require 'redis'

module Percy
  class Hub
    module RedisService
      def redis
        options = {
          host: ENV['REDIS_HOST'] || '127.0.0.1',
          port: Integer(ENV['REDIS_PORT'] || 6379),
          db: Integer(ENV['REDIS_DB'] || 0),

          # These need to be longer than the longest BRPOPLPUSH timeout.
          # Defaults are 5, 5, and 1.
          timeout: 20,
          connect_timeout: 20,
          reconnect_attempts: 2,
        }
        options[:password] = ENV['REDIS_PASSWORD'] if ENV['REDIS_PASSWORD']

        @redis ||= Redis.new(options)
      end

      def disconnect_redis
        @redis.close if @redis
        @redis = nil
      end
    end
  end
end

