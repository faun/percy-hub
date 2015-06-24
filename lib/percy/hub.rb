require 'pry'
require 'statsd'

require 'percy/async'
require 'percy/logger'
require 'percy/hub/version'
require 'percy/hub/redis_service'

module Percy
  class Hub
    include Percy::Hub::RedisService

    def run
      stats = Percy::Stats.new
      binding.pry

      Percy.logger.warn('WARN test')
      Percy::Async.run_periodically(1) do
      end
    end
  end
end
