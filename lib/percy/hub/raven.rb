require 'raven'

Raven.configure do |config|
  # SENTRY_DSN is set in the environment in development and production.
  config.dsn = ENV['SENTRY_DSN'] if ENV['SENTRY_DSN']

  config.environments = %w[production development test]
  config.current_environment = ENV.fetch('PERCY_ENV', 'development')

  config.release = ENV['SOURCE_COMMIT_SHA'] if ENV['SOURCE_COMMIT_SHA']

  config.silence_ready = true
end
