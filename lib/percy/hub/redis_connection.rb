require 'redis'
require 'percy/redis_client'

module Percy
  class Hub
    class RedisConnection
      def initialize(options = {})
        options.transform_keys! do |key|
          begin
            key.to_sym
          rescue StandardError
            key
          end
        end
        if options[:redis]
          @connection_pool = true
          @redis = options[:redis].call
        else
          @connection_pool = false
          @redis_options = configure_redis_options(options)
        end
      end

      def redis
        @redis ||= redis_connection.client
      end

      def disconnect_redis
        return if connection_pool?
        return unless @redis

        @redis.close
        @redis = nil
      end

      def self.default_connection_options
        {
          # These need to be longer than the longest BRPOPLPUSH timeout.
          # Defaults are 5, 5, and 1.
          timeout: 20,
          connect_timeout: 20,
          reconnect_attempts: 2,
          tcp_keepalive: 10,
        }
      end

      private def configure_redis_options(options)
        # If options are explicitly defined, use the values provided in the
        # options hash
        #
        # Otherwise, if REDIS_HOST is defined, use the legacy environment
        # variables: REDIS_HOST, REDIS_PORT, REDIS_DB and REDIS_PASSWORD
        #
        # Otherwise, use HUB_REDIS_URL (if defined)
        @redis_options = self.class.default_connection_options.merge(
          legacy_options(options),
        )
      end

      private def legacy_options(options)
        return options unless options.empty?

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

      private def connection_pool?
        @connection_pool
      end

      private def redis_connection
        Percy::RedisClient.new(@redis_options)
      end
    end
  end
end
