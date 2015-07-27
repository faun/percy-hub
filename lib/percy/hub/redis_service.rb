require 'redis'

module Percy
  class Hub
    module RedisService
      def redis
        options = {
          host: ENV['REDIS_HOST'] || '127.0.0.1',
          port: Integer(ENV['REDIS_PORT'] || 6379),
          db: Integer(ENV['REDIS_DB'] || 0),

          # By default, Redis TCP connections do NOT send keepalives. Since we connect to HAProxy
          # instead of a Redis server directly, we need to tune TCP keepalives so that HAProxy
          # can know when to reap connections. These are coordinated with the haproxy.cfg settings.
          #
          # Set Redis TCP connections to send the first keepalive after 5 seconds of inactivity
          # and every 5 seconds thereafter, and 2 unacknowledged probes will kill the connection.
          tcp_keepalive: {
            time: 5,
            intvl: 5,
            probes: 2,
          },
        }
        options[:password] = ENV['REDIS_PASSWORD'] if ENV['REDIS_PASSWORD']

        # Use the hiredis to avoid crazy threading/ruby segfault problems.
        options[:driver] = :hiredis

        @redis ||= Redis.new(options)
      end

      def reset_redis_connection
        @redis = nil
      end
    end
  end
end

