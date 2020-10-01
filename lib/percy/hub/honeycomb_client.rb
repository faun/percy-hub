require 'honeycomb-beeline'

module Percy
  class Hub
    Honeycomb = ::Honeycomb.dup
    Honeycomb.configure do |config|
      config.write_key = ENV['HONEYCOMB_WRITE_KEY']
      config.dataset = ENV['HONEYCOMB_DATASET']
      config.service_name = 'percy-hub'
    end

    ::Redis.honeycomb_client = Honeycomb.client
  end
end
