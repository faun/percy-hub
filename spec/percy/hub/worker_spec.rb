require 'percy/hub/worker'

RSpec.describe Percy::Hub::Worker do
  let(:hub) { Percy::Hub.new }
  let(:worker) { Percy::Hub::Worker.new }

  describe '#run' do
    let(:machine_id) { hub.start_machine }
    let(:worker_id) { hub.register_worker(machine_id: machine_id) }

    it 'yields a block and gives the action and kwargs' do
      got_action = nil
      got_options = nil

      thread = Thread.new do
        worker.run(times: 1) do |action, options|
          got_action = action
          got_options = options
        end
      end

      # Wait until the worker is running.
      sleep 0.1 until hub.redis.zcard('workers:idle') > 0

      hub.insert_job(job_data: 'process_snapshot:123', build_id: 234, subscription_id: 345)
      hub._enqueue_jobs
      hub._schedule_next_job

      thread.join(1)
      expect(got_action).to eq(:process_snapshot)
      expect(got_options).to eq({snapshot_id: 123})
    end
    it 'fails if not given a block' do
      expect { worker.run }.to raise_error(ArgumentError)
    end
    it 'silently captures exceptions and re-inserts the job to be retried' do
      thread = Thread.new do
        worker.run(times: 1) do |action, options|
          raise Exception
        end
      end

      # Wait until the worker is running.
      sleep 0.1 until hub.redis.zcard('workers:idle') > 0

      hub.insert_job(job_data: 'process_snapshot:123', build_id: 234, subscription_id: 345)
      hub._enqueue_jobs
      hub._schedule_next_job
      expect(hub.redis.get('job:1:data')).to be

      thread.join(1)
      expect(hub.redis.get('job:1:data')).to_not be
      expect(hub.redis.get('job:2:data')).to be
    end
  end
end

