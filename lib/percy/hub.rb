require 'pry'

require 'percy/async'
require 'percy/logger'
require 'percy/stats'
require 'percy/hub/version'
require 'percy/hub/redis_service'

module Percy
  class Hub
    include Percy::Hub::RedisService

    def run
      Percy.logger.warn('WARN test')

      binding.pry

      Percy::Async.run_periodically(1) do
      end
    end

    def stats
      @stats ||= Percy::Stats.new
    end

    def insert_snapshot_job(snapshot_id:, build_id:, subscription_id:, inserted_at: nil)
      stats.time('hub.methods.insert_snapshot_job') do
        keys = [
          'jobs:created:counter',
          'builds:active',
          "build:#{build_id}:subscription_id",
          "build:#{build_id}:jobs",
        ]
        job_data = "process_snapshot:#{snapshot_id}"
        args = [
          snapshot_id,
          build_id,
          subscription_id,
          inserted_at || Time.now.to_i,
          job_data,
        ]

        num_total_jobs = _run_script('insert_snapshot_job.lua', keys: keys, argv: args)
        stats.gauge('hub.jobs.created', num_total_jobs)
        num_total_jobs
      end
    end

    private def _run_script(name, keys:, argv: nil)
      script = File.read(File.expand_path("../hub/scripts/#{name}", __FILE__))
      redis.eval(script, keys: keys, argv: argv)
    end
  end
end
