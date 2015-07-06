require 'redis'

module Percy
  class Hub
    module RedisService
      VALID_KEYS_REGEX = %r{
        \A
        jobs:created:counter
        |builds:active
        |build:\d+:subscription_id
        |build:\d+:jobs
        \Z
      }x

      def build_key(*args)
        key = args.join(':')
        raise NotImplementedError.new(key) if !VALID_KEYS_REGEX.match(key)
        key
      end

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

