require 'redis'

module Percy
  class Hub
    module RedisService
      def redis
        return @redis if @redis

        options = {
          host: ENV['REDIS_HOST'] || '127.0.0.1',
          port: Integer(ENV['REDIS_PORT'] || 6379),
          db: Integer(ENV['REDIS_DB'] || 0),
        }
        options[:password] = ENV['REDIS_PASSWORD'] if ENV['REDIS_PASSWORD']

        @redis = Redis.new(options)

        # Important: define a finalizer that will close the redis TCP connection when this object
        # gets garbage collected. It is also important that this proc is from the class method
        # and not just created inline here, see:
        # http://www.mikeperham.com/2010/02/24/the-trouble-with-ruby-finalizers/
        ObjectSpace.define_finalizer(@redis, self.class._destroy_redis_client(@redis))

        @redis
      end

      def reset_redis_connection
        @redis.disconnect! if @redis
        @redis = nil
      end
    end

    def self._destroy_redis_client(redis_obj)
      proc { redis_obj.disconnect! }
    end
  end
end

