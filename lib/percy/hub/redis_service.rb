require 'redis'
require 'percy/redis_client'
require 'connection_pool'
require 'digest/sha1'

module Percy
  class Hub
    module RedisService
      CONNECTION_POOL_TIMEOUT = ENV.fetch('REDIS_CONNECTION_POOL_TIMEOUT', 5)
      CONNECTION_POOL_SIZE = ENV.fetch('REDIS_CONNECTION_POOL_SIZE', 5)
      attr_reader :cache_key

      # rubocop:disable Style/GlobalVars
      $redis_connection_pool = {}
      # rubocop:enable Style/GlobalVars

      def redis_pool
        raise 'Missing redis configuration' unless @redis_options

        # rubocop:disable Style/GlobalVars
        @mutex.synchronize do
          $redis_connection_pool[cache_key] ||= ::ConnectionPool.new(
            size: CONNECTION_POOL_SIZE,
            timeout: CONNECTION_POOL_TIMEOUT,
          ) do
            single_connection
          end
        end
        # rubocop:enable Style/GlobalVars
      end

      def redis
        raise 'Missing redis configuration' unless @redis_options

        @redis ||= ::ConnectionPool::Wrapper.new(
          size: CONNECTION_POOL_SIZE,
          timeout: CONNECTION_POOL_TIMEOUT,
        ) do
          single_connection
        end
      end

      def configure_redis_options(options = {})
        @mutex = Mutex.new
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
        @cache_key = Digest::SHA1.hexdigest(@redis_options.to_s)
        @redis_options
      end

      private def redis_connection(options)
        Percy::RedisClient.new(options)
      end

      private def single_connection
        redis_connection(@redis_options).client
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
