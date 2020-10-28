require 'redis'
require 'percy/redis_client'
require 'connection_pool'

module Percy
  class Hub
    module RedisService
      def redis_pool
        @redis_pool ||= connection_pool
      end

      def redis
        @redis ||= ::ConnectionPool::Wrapper.new(size: 5, timeout: 5) do
          single_connection
        end
      end

      def disconnect_redis
        return unless @redis

        @redis.close
        @redis = nil
      end

      def configure_redis_options(options = {})
        options.transform_keys! do |key|
          begin
            key.to_sym
          rescue StandardError
            key
          end
        end
        # If options are explicitly defined, use the values provided in the
        # options hash
        #
        # Otherwise, if REDIS_HOST is defined, use the legacy environment
        # variables: REDIS_HOST, REDIS_PORT, REDIS_DB and REDIS_PASSWORD
        #
        # Otherwise, use HUB_REDIS_URL (if defined)

        if options.empty?
          if ENV['REDIS_HOST']
            options[:host] = ENV['REDIS_HOST'] if ENV['REDIS_HOST']
            options[:port] = Integer(ENV['REDIS_PORT']) if ENV['REDIS_PORT']
            options[:db] = Integer(ENV['REDIS_DB']) if ENV['REDIS_DB']
            options[:password] = ENV['REDIS_PASSWORD'] if ENV['REDIS_PASSWORD']
          elsif ENV['HUB_REDIS_URL']
            options[:url] = ENV['HUB_REDIS_URL']
          end
          @redis_options = options
        else
          @redis_options = default_connection_options.merge(options)
        end
      end

      private def redis_connection(options)
        Percy::RedisClient.new(options)
      end

      private def single_connection
        raise 'Missing redis configuration' unless @redis_options

        redis_connection(@redis_options).client
      end

      private def connection_pool
        ::ConnectionPool.new(size: 5, timeout: 5) do
          single_connection
        end
      end

      private def default_connection_options
        {
          # These need to be longer than the longest BRPOPLPUSH timeout.
          # Defaults are 5, 5, and 1.
          timeout: 20,
          connect_timeout: 20,
          reconnect_attempts: 2,
          tcp_keepalive: 10,
        }
      end
    end
  end
end
