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

    def insert_snapshot_job(snapshot_id:, build_id:, subscription_id:, inserted_at: nil)
      keys = [
        build_key('jobs:created:counter'),
        build_key('builds:active'),
        build_key(:build, build_id, :subscription_id),
        build_key(:build, build_id, :jobs),
      ]
      job_data = "process_snapshot:#{snapshot_id}"
      args = [
        snapshot_id,
        build_id,
        subscription_id,
        inserted_at || Time.now.to_i,
        job_data,
      ]
      _run_script('insert_snapshot_job.lua', keys: keys, argv: args)
    end

    private def _run_script(name, keys:, argv: nil)
      script = File.read(File.expand_path("../hub/scripts/#{name}", __FILE__))
      redis.eval(script, keys: keys, argv: argv)
    end
  end
end
