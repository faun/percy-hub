require 'redis'

module Percy
  class Hub
    module RedisService
      def redis
        @redis ||= Redis.new(
          host: ENV['REDIS_HOST'] || '127.0.0.1',
          port: ENV['REDIS_PORT'] || 6379,
          db: ENV['REDIS_DB'] || 0,
        )
      end
    end
  end
end

