require 'redis'
require 'percy/redis_client'

module Percy
  class Hub
    module RedisService
      def redis_client(options = {})
        @redis_client ||= redis_connection(default_redis_options.merge(options)).client
      end

      def disconnect_redis
        return unless @redis_client

        @redis_client.close
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
        # If REDIS_HOST is defined, use the legacy environment variables
        # Otherwise, use HUB_REDIS_URL (if defined)
        if ENV['REDIS_HOST']
          options[:host] = ENV['REDIS_HOST'] if ENV['REDIS_HOST']
          options[:port] = Integer(ENV['REDIS_PORT']) if ENV['REDIS_PORT']
          options[:db] = Integer(ENV['REDIS_DB']) if ENV['REDIS_DB']
          options[:password] = ENV['REDIS_PASSWORD'] if ENV['REDIS_PASSWORD']
        elsif ENV['HUB_REDIS_URL']
          options[:url] = ENV['HUB_REDIS_URL']
        end
        options
      end

      private def redis_connection(options)
        Percy::RedisClient.new(options)
      end
    end
  end
end
