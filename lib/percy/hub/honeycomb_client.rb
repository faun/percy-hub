require 'honeycomb-beeline'

module Percy
  class Hub
    HoneycombClient = ::Honeycomb.dup
    HoneycombClient.configure do |config|
      config.write_key = ENV['HONEYCOMB_WRITE_KEY']
      config.dataset = ENV['HONEYCOMB_DATASET']
      config.service_name = 'percy-hub'
    end
  end
end
