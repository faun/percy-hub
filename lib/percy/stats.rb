require 'statsd'

module Percy
  class Stats < ::Statsd
    def initialize(*args)
      super
      self.tags = ["env:#{ENV['PERCY_ENV'] || 'development'}"]
    end
  end
end
