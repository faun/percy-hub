require 'percy/async'
require 'percy/logger'
require 'percy/hub/version'

module Percy
  class Hub
    def run
      Percy.logger.warn('WARN test')
      Percy::Async.run_periodically(1) do
      end
    end
  end
end


