require 'redis'

module Percy
  class Hub
    module RedisService
      VALID_KEYS_REGEX = %r{
        \A
        worker:\d+:lock
        |worker:\d+:idle
        |worker:\d+:jobs
        |worker:\d+:keepalive_lock
        |worker:\d+:last_finished_at
        \Z
      }x

      def build_key(*args)
        key = args.join(':')
        raise ArgumentError if !VALID_KEYS_REGEX.match(key)
        key
      end

      def redis_client
        @redis_client ||= Redis.new(
          host: ENV['REDIS_HOST'] || '127.0.0.1',
          port: ENV['REDIS_PORT'] || 6379,
          db: ENV['REDIS_DB'] || 0,
        )
      end

      def enqueue_jobs

      end
    end
  end
end

