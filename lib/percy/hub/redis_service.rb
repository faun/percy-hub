require 'redis'

module Percy
  class Hub
    module RedisService
      def redis
        options = {
          host: ENV['REDIS_HOST'] || '127.0.0.1',
          port: Integer(ENV['REDIS_PORT'] || 6379),
          db: Integer(ENV['REDIS_DB'] || 0),

          # NOTE: Reduce connection churn by not re-establishing new connections in forked children.
          # This basically assumes that we do not re-use Hub objects from within forked processes,
          # and instead create new Hub instances. REDIS CONNECTIONS WILL BECOME CORRUPT if we ever
          # re-use Hub instances inside forked children.
          inherit_socket: true,
        }
        options[:password] = ENV['REDIS_PASSWORD'] if ENV['REDIS_PASSWORD']
        @redis ||= Redis.new(options)
      end
    end
  end
end

