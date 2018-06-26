# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SidekiqUniqueJobs::Locksmith, redis: :redis do
  let(:locksmith)                 { described_class.new(lock_item) }
  let(:lock_expiration)           { nil }
  let(:lock_stale_client_timeout) { nil }
  let(:jid)                       { 'maaaahjid' }
  let(:lock_item) do
    {
      'jid' => jid,
      'queue' => 'dupsallowed',
      'class' => 'UntilAndWhileExecuting',
      'unique' => 'until_executed',
      'unique_digest' => 'test_mutex_key',
      'args' => [1],
      'lock_expiration' => lock_expiration,
      'stale_client_timeout' => lock_stale_client_timeout,
    }
  end
  let(:lock_with_different_jid) { described_class.new(lock_item_with_different_jid) }
  let(:jid_2)                   { 'jidmayhem' }
  let(:lock_item_with_different_jid) do
    lock_item.merge('jid' => jid_2)
  end

  shared_examples_for 'a lock' do
    it 'does not exist from the start' do
      expect(locksmith.exists?).to eq(false)
      locksmith.lock
      expect(locksmith.exists?).to eq(true)
    end

    it 'is unlocked from the start' do
      expect(locksmith.locked?).to eq(false)
    end

    it 'locks and unlock' do
      locksmith.lock(1)
      expect(locksmith.locked?).to eq(true)
      locksmith.unlock
      expect(locksmith.locked?).to eq(false)
    end

    it 'does not lock twice as a mutex' do
      expect(locksmith.lock(1)).to be_truthy
      expect(locksmith.lock(1)).to eq(nil)
    end

    it 'executes the given code block' do
      code_executed = false
      locksmith.lock(1) do
        code_executed = true
      end
      expect(code_executed).to eq(true)
    end

    it 'passes an exception right through' do
      expect do
        locksmith.lock(1) do
          raise Exception, 'redis lock exception'
        end
      end.to raise_error(Exception, 'redis lock exception')
    end

    it 'does not leave the lock locked after raising an exception' do
      expect do
        locksmith.lock(1) do
          raise Exception, 'redis lock exception'
        end
      end.to raise_error(Exception, 'redis lock exception')

      expect(locksmith.locked?).to eq(false)
    end

    it 'returns the value of the block if block-style locking is used' do
      block_value = locksmith.lock(1) do
        42
      end
      expect(block_value).to eq(42)
    end

    it 'disappears without a trace when calling `delete!`' do
      original_key_size = keys.size

      locksmith.create
      locksmith.delete!

      expect(keys.size).to eq(original_key_size)
    end

    it 'does not block when the timeout is zero' do
      did_we_get_in = false

      locksmith.lock do
        locksmith.lock(0) do
          did_we_get_in = true
        end
      end

      expect(did_we_get_in).to be false
    end

    it 'is locked when the timeout is zero' do
      locksmith.lock(0) do
        expect(locksmith.locked?).to be true
      end
      expect(locksmith.locked?).to eq false
    end
  end

  describe 'lock with expiration' do
    let(:lock_expiration) { 1 }

    it_behaves_like 'a lock'

    it 'expires keys' do
      Sidekiq.redis(&:flushdb)
      locksmith.create
      keys = unique_keys
      expect(unique_keys).not_to include(keys)
    end

    it 'expires keys after unlocking' do
      Sidekiq.redis(&:flushdb)
      locksmith.lock do
        # noop
      end
      keys = unique_keys
      expect { unique_keys }.to eventually_not include(keys)
    end
  end

  describe 'lock without staleness checking' do
    it_behaves_like 'a lock'

    it 'can dynamically add resources' do
      locksmith.create

      3.times do
        locksmith.signal
      end

      expect(locksmith.available_count).to eq(4)

      locksmith.wait(1)
      locksmith.wait(1)
      locksmith.wait(1)

      expect(locksmith.available_count).to eq(1)
    end

    # stale clients and concurrency removed in a0cff5bc42edbe7190d6ede7e7f845074d2d7af6
    # shared_examples 'can release stale clients' do
    #   # TODO: This spec is flaky and should be improved to not use sleeps
    #   it 'can have stale locks released by a third process', :retry do
    #     watchdog = described_class.new(lock_item.merge('stale_client_timeout' => 0.5))
    #     locksmith.lock

    #     watchdog.release_stale_locks
    #     expect(locksmith.locked?).to eq(true)

    #     sleep 0.6
    #     watchdog.release_stale_locks

    #     expect(locksmith.locked?).to eq(false)
    #   end
    # end

    # context 'when redis version < 3.2', redis_ver: '<= 3.2' do
    #   before { allow(SidekiqUniqueJobs).to receive(:redis_version).and_return('3.1') }

    #   it_behaves_like 'can release stale clients'
    # end

    # context 'when redis version >= 3.2' do
    #   before { allow(SidekiqUniqueJobs).to receive(:redis_version).and_return('3.2') }

    #   it_behaves_like 'can release stale clients'
    # end
  end

  describe 'current_time' do
    let(:lock_stale_client_timeout) { 5 }

    before do
      Timecop.freeze(Time.local(1990))
    end

    it 'with time support should return a different time than frozen time' do
      expect(locksmith.send(:current_time)).not_to eq(Time.now)
    end
  end
end