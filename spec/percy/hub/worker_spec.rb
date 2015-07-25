require 'percy/hub/worker'

Thread.abort_on_exception = true

RSpec.describe Percy::Hub::Worker do
  let(:hub) { Percy::Hub.new }
  let(:worker) { Percy::Hub::Worker.new }

  def wait_until_any_worker_is_running
    10.times { sleep 0.1 unless hub.redis.zcard('workers:idle') > 0 }
    expect(hub.redis.zcard('workers:idle')).to be > 0
  end

  def insert_and_schedule_random_job
    hub.insert_job(job_data: 'process_snapshot:123', build_id: 234, subscription_id: 345)
    hub._enqueue_jobs
    hub._schedule_next_job
  end

  describe '#reset_hub' do
    it 'resets the hub instance var' do
      old_hub = worker.hub
      worker.reset_hub
      expect(worker.hub).to_not eq(old_hub)
    end
  end
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

      wait_until_any_worker_is_running
      insert_and_schedule_random_job
      thread.join(1)

      expect(got_action).to eq(:process_snapshot)
      expect(got_options).to eq({snapshot_id: 123})
    end
    it 'fails if not given a block' do
      expect { worker.run }.to raise_error(ArgumentError)
    end
    it 'silently captures exceptions and retries the job as a new job' do
      thread = Thread.new do
        worker.run(times: 1) do |action, options|
          raise Exception
        end
      end

      wait_until_any_worker_is_running
      insert_and_schedule_random_job
      expect(hub.redis.get('job:1:data')).to be

      thread.join(1)
      expect(hub.redis.get('job:1:data')).to_not be
      expect(hub.redis.get('job:2:data')).to be
    end
    it 'raises an error if killed by a redis error' do
      failhub = Percy::Hub.new
      expect(failhub).to receive(:get_job_data).and_raise(Redis::CannotConnectError)
      expect(worker).to receive(:hub).at_least(:once).times.and_return(failhub)
      thread = Thread.new do
        begin
          worker.run(times: 1) { }
        rescue Exception => e
          e
        end
      end

      wait_until_any_worker_is_running
      insert_and_schedule_random_job
      thread.join(1)
      expect(thread.value.class).to eq(Redis::CannotConnectError)
    end
    it 'runs a heartbeat thread alongside the worker' do
      thread = Thread.new do
        worker.run(times: 1) { }
      end

      wait_until_any_worker_is_running
      insert_and_schedule_random_job
      thread.join(1)
      expect(hub.list_workers_by_heartbeat(older_than_seconds: 0)).to eq(['1'])
      expect(hub.list_workers_by_heartbeat(older_than_seconds: 5)).to eq([])
    end
  end
end

