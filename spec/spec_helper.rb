require 'percy/hub'
require 'pry'

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    # This option will default to `true` in RSpec 4.
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.disable_monkey_patching!

  # Run specs in random order to surface order dependencies. If you find an
  # order dependency and want to debug it, you can fix the order by providing
  # the seed, which is printed after each run.
  #     --seed 1234
  config.order = :random

  # Seed global randomization in this process using the `--seed` CLI option.
  # Setting this allows you to use `--seed` to deterministically reproduce
  # test failures related to randomization by passing the same `--seed` value
  # as the one that triggered the failure.
  Kernel.srand config.seed

  # Set the PERCY_ENV variable so stat tags are set correctly.
  config.before(:all) { ENV['PERCY_ENV'] = 'test' }

  # Use DB #7 for test data and flush before each test run.
  config.before(:all) { ENV['HUB_REDIS_URL'] = 'redis://redis:6379/7' }
  config.before(:each) { Percy::Hub.new.redis.flushdb }

  config.filter_run :focus
  config.run_all_when_everything_filtered = true
end
