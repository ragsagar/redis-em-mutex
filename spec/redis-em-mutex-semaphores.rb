$:.unshift "lib"
require 'securerandom'
require 'em-synchrony'
require 'em-synchrony/fiber_iterator'
require 'redis-em-mutex'

describe Redis::EM::Mutex do

  it "should lock and prevent locking on the same semaphore" do
    begin
      described_class.new(@lock_names.first).owned?.should be_false
      mutex = described_class.lock(@lock_names.first)
      mutex.names.should eq [@lock_names.first]
      mutex.locked?.should be_true
      mutex.owned?.should be_true
      mutex.should be_an_instance_of described_class
      described_class.new(@lock_names.first).try_lock.should be_false
      expect {
        mutex.lock
      }.to raise_error(Redis::EM::Mutex::MutexError, /deadlock; recursive locking/)
      mutex.unlock.should be_an_instance_of described_class
      mutex.locked?.should be_false
      mutex.owned?.should be_false
      mutex.try_lock.should be_true
    ensure
      mutex.unlock if mutex
    end
  end

  it "should lock and prevent locking on the same multiple semaphores" do
    begin
      mutex = described_class.lock(*@lock_names)
      mutex.names.should eq @lock_names
      mutex.locked?.should be_true
      mutex.owned?.should be_true
      mutex.should be_an_instance_of described_class
      described_class.new(*@lock_names).try_lock.should be_false
      @lock_names.each do |name|
        described_class.new(name).try_lock.should be_false
      end
      mutex.try_lock.should be_false
      expect {
        mutex.lock
      }.to raise_error(Redis::EM::Mutex::MutexError, /deadlock; recursive locking/)
      @lock_names.each do |name|
        expect {
          described_class.new(name).lock
        }.to raise_error(Redis::EM::Mutex::MutexError, /deadlock; recursive locking/)
      end
      mutex.unlock.should be_an_instance_of described_class
      mutex.locked?.should be_false
      mutex.owned?.should be_false
      mutex.try_lock.should be_true
    ensure
      mutex.unlock if mutex
    end
  end

  it "should lock and prevent other fibers to lock on the same semaphore" do
    begin
      mutex = described_class.lock(@lock_names.first)
      mutex.should be_an_instance_of described_class
      mutex.owned?.should be_true
      locked = true
      ::EM::Synchrony.next_tick do
        mutex.try_lock.should be false
        mutex.owned?.should be_false
        start = Time.now
        mutex.synchronize do
          (Time.now - start).should be_within(0.01).of(0.26)
          locked.should be false
          locked = nil
        end
      end
      ::EM::Synchrony.sleep 0.25
      locked = false
      mutex.owned?.should be_true
      mutex.unlock.should be_an_instance_of described_class
      mutex.owned?.should be_false
      ::EM::Synchrony.sleep 0.1
      locked.should be_nil
    ensure
      mutex.unlock if mutex
    end
  end

  it "should lock and prevent other fibers to lock on the same multiple semaphores" do
    begin
      mutex = described_class.lock(*@lock_names)
      mutex.should be_an_instance_of described_class
      mutex.owned?.should be_true
      locked = true
      ::EM::Synchrony.next_tick do
        locked.should be true
        mutex.try_lock.should be false
        mutex.owned?.should be_false
        start = Time.now
        mutex.synchronize do
          mutex.owned?.should be_true
          (Time.now - start).should be_within(0.01).of(0.26)
          locked.should be false
        end
        mutex.owned?.should be_false
        ::EM::Synchrony.sleep 0.1
        start = Time.now
        ::EM::Synchrony::FiberIterator.new(@lock_names, @lock_names.length).each do |name|
          locked.should be true
          described_class.new(name).synchronize do
            (Time.now - start).should be_within(0.01).of(0.26)
            locked.should be_an_instance_of Fixnum
            locked-= 1
          end
        end
      end
      ::EM::Synchrony.sleep 0.25
      locked = false
      mutex.owned?.should be_true
      mutex.unlock.should be_an_instance_of described_class
      mutex.owned?.should be_false
      ::EM::Synchrony.sleep 0.1

      locked = true
      mutex.lock.should be true
      ::EM::Synchrony.sleep 0.25
      locked = 10
      mutex.unlock.should be_an_instance_of described_class
      ::EM::Synchrony.sleep 0.1
      locked.should eq 0
    ensure
      mutex.unlock if mutex
    end
  end

  it "should lock and prevent other fibers to lock on the same semaphore with block timeout" do
    begin
      mutex = described_class.lock(*@lock_names)
      mutex.should be_an_instance_of described_class
      mutex.owned?.should be_true
      locked = true
      ::EM::Synchrony.next_tick do
        start = Time.now
        mutex.lock(0.25).should be false
        mutex.owned?.should be_false
        (Time.now - start).should be_within(0.01).of(0.26)
        locked.should be true
        locked = nil
      end
      ::EM::Synchrony.sleep 0.26
      locked.should be_nil
      locked = false
      mutex.locked?.should be_true
      mutex.owned?.should be_true
      mutex.unlock.should be_an_instance_of described_class
      mutex.locked?.should be_false
      mutex.owned?.should be_false
    ensure
      mutex.unlock if mutex
    end
  end

  it "should lock and expire while other fiber lock on the same semaphore with block timeout" do
    begin
      mutex = described_class.lock(*@lock_names, expire: 0.2499999)
      mutex.expire_timeout.should eq 0.2499999
      mutex.should be_an_instance_of described_class
      mutex.owned?.should be_true
      locked = true
      ::EM::Synchrony.next_tick do
        mutex.owned?.should be_false
        start = Time.now
        mutex.lock(0.25).should be true
        (Time.now - start).should be_within(0.011).of(0.26)
        locked.should be true
        locked = nil
        mutex.locked?.should be_true
        mutex.owned?.should be_true
        ::EM::Synchrony.sleep 0.2
        locked.should be_false
        mutex.unlock.should be_an_instance_of described_class
        mutex.owned?.should be_false
        mutex.locked?.should be_false
      end
      ::EM::Synchrony.sleep 0.26
      locked.should be_nil
      locked = false
      mutex.locked?.should be_true
      mutex.owned?.should be_false
      mutex.unlock.should be_an_instance_of described_class
      mutex.locked?.should be_true
      mutex.owned?.should be_false
      ::EM::Synchrony.sleep 0.2
    ensure
      mutex.unlock if mutex
    end
  end

  it "should lock and prevent (with refresh) other fibers to lock on the same semaphore with block timeout" do
    begin
      mutex = described_class.lock(*@lock_names, expire: 0.11)
      mutex.should be_an_instance_of described_class
      mutex.owned?.should be_true
      locked = true
      ::EM::Synchrony.next_tick do
        start = Time.now
        mutex.lock(0.3).should be false
        mutex.owned?.should be_false
        (Time.now - start).should be_within(0.01).of(0.31)
        locked.should be true
        locked = nil
      end
      ::EM::Synchrony.sleep 0.08
      mutex.owned?.should be_true
      mutex.refresh
      ::EM::Synchrony.sleep 0.08
      mutex.owned?.should be_true
      mutex.refresh(0.5)
      ::EM::Synchrony.sleep 0.15
      locked.should be_nil
      locked = false
      mutex.locked?.should be_true
      mutex.owned?.should be_true
      mutex.unlock.should be_an_instance_of described_class
      mutex.locked?.should be_false
      mutex.owned?.should be_false
    ensure
      mutex.unlock if mutex
    end
  end

  it "should lock some resource and play with it safely" do
    mutex = described_class.new(*@lock_names)
    play_name = SecureRandom.random_bytes
    result = []
    ::EM::Synchrony::FiberIterator.new((0..9).to_a, 10).each do |i|
      was_locked = false
      redis = Redis.new @redis_options
      mutex.owned?.should be_false
      mutex.synchronize do
        mutex.owned?.should be_true
        was_locked = true
        redis.setnx(play_name, i).should be_true
        ::EM::Synchrony.sleep 0.1
        redis.get(play_name).should eq i.to_s
        redis.del(play_name).should eq 1
      end
      was_locked.should be_true
      mutex.owned?.should be_false
      result << i
    end
    mutex.locked?.should be_false
    result.sort.should eq (0..9).to_a
  end

  it "should lock and the other fiber should acquire lock as soon as possible" do
    mutex = described_class.lock(*@lock_names)
    mutex.should be_an_instance_of described_class
    time = nil
    EM::Synchrony.next_tick do
      time.should be_nil
      was_locked = false
      mutex.synchronize do
        time.should be_an_instance_of Time
        (Time.now - time).should be < 0.0009
        was_locked = true
      end
      was_locked.should be_true
    end
    EM::Synchrony.sleep 0.1
    mutex.owned?.should be_true
    mutex.unlock.should be_an_instance_of described_class
    time = Time.now
    mutex.owned?.should be_false
    EM::Synchrony.sleep 0.1
  end

  it "should lock and the other process should acquire lock as soon as possible" do
    mutex = described_class.lock(*@lock_names)
    mutex.should be_an_instance_of described_class
    time_key1 = SecureRandom.random_bytes
    time_key2 = SecureRandom.random_bytes
    ::EM.fork_reactor do
      Fiber.new do
        begin
          redis = Redis.new @redis_options
          redis.set time_key1, Time.now.to_f.to_s
          mutex.synchronize do
            redis.set time_key2, Time.now.to_f.to_s
          end
          described_class.stop_watcher(false)
        # rescue => e
        #   warn e.inspect
        ensure
          EM.stop
        end
      end.resume
    end
    EM::Synchrony.sleep 0.25
    mutex.owned?.should be_true
    mutex.unlock.should be_an_instance_of described_class
    time = Time.now.to_f
    mutex.owned?.should be_false
    EM::Synchrony.sleep 0.25
    redis = Redis.new @redis_options
    t1, t2 = redis.mget(time_key1, time_key2)
    t1.should be_an_instance_of String
    t1.to_f.should be < time - 0.25
    t2.should be_an_instance_of String
    t2.to_f.should be > time
    t2.to_f.should be_within(0.001).of(time)
    redis.del(time_key1, time_key2)
  end

  around(:each) do |testcase|
    @after_em_stop = nil
    ::EM.synchrony do
      begin
        testcase.call
      ensure
        described_class.stop_watcher(false)
        ::EM.stop
      end
    end
    @after_em_stop.call if @after_em_stop
  end

  before(:all) do
    @redis_options = {}
    described_class.setup @redis_options.merge(size: 11)
    @lock_names = 10.times.map {
      SecureRandom.random_bytes
    }
  end

  after(:all) do
    # @lock_names
  end
end