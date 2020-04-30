require 'redis'
require 'percy/redis_client'

module Percy
  class Hub
    module RedisService
      def redis(options = {})
        @redis ||= redis_client(default_redis_options.merge(options)).client
      end

      def disconnect_redis
        @redis&.close
        @redis = nil
        @redis_client = nil
      end

      private def default_redis_options
        options = {
          # These need to be longer than the longest BRPOPLPUSH timeout.
          # Defaults are 5, 5, and 1.
          timeout: 20,
          connect_timeout: 20,
          reconnect_attempts: 2,
          tcp_keepalive: 10,
        }
        if ENV['REDIS_URL']
          options[:url] = ENV['REDIS_URL'] if ENV['REDIS_URL']
        else
          options[:host] = ENV['REDIS_HOST'] if ENV['REDIS_HOST']
          options[:port] = Integer(ENV['REDIS_PORT']) if ENV['REDIS_PORT']
          options[:db] = Integer(ENV['REDIS_DB']) if ENV['REDIS_DB']
          options[:password] = ENV['REDIS_PASSWORD'] if ENV['REDIS_PASSWORD']
        end
        options
      end

      private def redis_client(options)
        @redis_client ||= Percy::RedisClient.new(options)
      end
    end
  end
end
