# -*- coding: UTF-8 -*-
require 'ostruct'
require 'securerandom'
require 'redis/connection/synchrony' unless defined? Redis::Connection::Synchrony
require 'redis'

class Redis
  module EM
    # Cross machine-process-fiber EventMachine + Redis based semaphore.
    #
    # WARNING:
    #
    # Methods of this class are NOT thread-safe.
    # They are machine/process/fiber-safe.
    # All method calls must be invoked only from EventMachine's reactor thread.
    # Wrap mutex calls in EventMachine.shedule from non-reactor threads.
    #
    # - The terms "lock" and "semaphore" used in documentation are synonims.
    # - The term "owner" denotes a Ruby Fiber executing code in the scope of Machine/Process/Fiber
    #   possessing exclusively a named semaphore(s).
    #
    class Mutex

      autoload :NS, 'redis/em-mutex/ns'
      autoload :Macro, 'redis/em-mutex/macro'

      module Errors
        class MutexError < RuntimeError; end
        class MutexTimeout < MutexError; end
      end

      include Errors
      extend Errors

      SIGNAL_QUEUE_CHANNEL = "::#{self.name}::"
      AUTO_NAME_SEED = '__@'
      DEFAULT_RECONNECT_MAX_RETRIES = 10
      @@default_expire = 3600*24
      @@name_index = AUTO_NAME_SEED
      @@redis_pool = nil
      @@watching = false
      @@signal_queue = Hash.new {|h,k| h[k] = []}
      @@ns = nil
      @@handler = nil
      @@uuid ||= if SecureRandom.respond_to?(:uuid)
        SecureRandom.uuid
      else
        SecureRandom.base64(24)
      end

      private

      def signal_queue; @@signal_queue end
      def uuid; @@uuid; end
      def redis_pool; @@redis_pool end

      public

      # Selected implementation handler module name
      def self.handler; @@handler && @@handler.name end

      # Whether selected implementation handler
      # supports refreshing of already expired locks.
      def self.can_refresh_expired?
        @@handler.can_refresh_expired?
      end

      # Whether selected implementation handler
      # supports refreshing of already expired locks.
      def can_refresh_expired?
        @@handler.can_refresh_expired?
      end

      # Creates a new cross machine/process/fiber semaphore
      #
      #   Redis::EM::Mutex.new(*names, options = {})
      #
      # - *names = lock identifiers - if none they are auto generated
      # - options = hash:
      # - :name - same as *names (in case *names arguments were omitted)
      # - :block - default block timeout
      # - :expire - default expire timeout (see: Mutex#lock and Mutex#try_lock)
      # - :ns - local namespace (otherwise global namespace is used)
      # - :owner - owner definition instead of Fiber#__id__
      #
      # Raises MutexError if used before Mutex.setup.
      # Raises ArgumentError on invalid options.
      def initialize(*args)
        raise MutexError, "call #{self.class}::setup first" unless @@redis_pool
        self.class.setup_handler unless @@handler

        opts = args.last.kind_of?(Hash) ? args.pop : {}

        @names = args
        @names = Array(opts[:name] || "#{@@name_index.succ!}.lock") if @names.empty?
        @slept = {}
        raise ArgumentError, "semaphore names must not be empty" if @names.empty?
        @multi = !@names.one?
        @ns = opts[:ns] || @@ns
        @ns_names = @ns ? @names.map {|n| "#@ns:#{n}".freeze }.freeze : @names.map {|n| n.to_s.dup.freeze }.freeze
        @marsh_names = Marshal.dump(@ns_names)
        self.expire_timeout = opts[:expire] if opts.key?(:expire)
        self.block_timeout = opts[:block] if opts.key?(:block)
        self.extend(@@handler)
        post_init(opts)
      end

      attr_reader :names, :ns, :block_timeout
      alias_method :namespace, :ns

      def expire_timeout; @expire_timeout || @@default_expire; end

      def expire_timeout=(value)
        raise ArgumentError, "#{self.class.name}\#expire_timeout value must be greater than 0" unless (value = value.to_f) > 0
        @expire_timeout = value
      end

      def block_timeout=(value)
        @block_timeout = value.nil? ? nil : value.to_f
      end

      # Releases the lock unconditionally.
      # If the semaphore wasn't locked by the current owner it is silently ignored.
      # Returns self.
      def unlock
        unlock!
        self
      end

      # Wakes up currently sleeping fiber on a mutex.
      def wakeup(fiber)
        fiber.resume if @slept.delete(fiber)
      end

      # for compatibility with EventMachine::Synchrony::Thread::ConditionVariable
      alias_method :_wakeup, :wakeup

      # Releases the lock and sleeps `timeout` seconds if it is given and non-nil or forever.
      # Raises MutexError if mutex wasn't locked by the current owner.
      # Raises MutexTimeout if #block_timeout= was set and timeout
      # occured while locking after sleep.
      # If code block is provided it is executed after waking up, just before grabbing a lock.
      def sleep(timeout = nil)
        raise MutexError, "can't sleep #{self.class} wasn't locked" unless unlock!
        start = Time.now
        current = Fiber.current
        @slept[current] = true
        if timeout
          timer = ::EM.add_timer(timeout) do
            wakeup(current)
          end
          Fiber.yield
          ::EM.cancel_timer timer
        else
          Fiber.yield
        end
        @slept.delete current
        yield if block_given?
        raise MutexTimeout unless lock
        Time.now - start
      end

      # Execute block of code protected with semaphore.
      # Code block receives mutex object.
      # Returns result of code block.
      #
      # If `block_timeout` or Mutex#block_timeout is set and
      # lock isn't obtained within `block_timeout` seconds this method raises
      # MutexTimeout.
      def synchronize(block_timeout=nil)
        if lock(block_timeout)
          begin
            yield self
          ensure
            unlock
          end
        else
          raise MutexTimeout
        end
      end

      # Returns true if watcher is connected
      def watching?; @@watching == $$; end

      # Returns true if watcher is connected
      def self.watching?; @@watching == $$; end

      class << self
        attr_reader :reconnect_max_retries
        def reconnect_forever?
          @reconnect_max_retries < 0
        end
        def reconnect_max_retries=(max)
          @reconnect_max_retries = max == :forever ? -1 : max.to_i
        end
        def ns; @@ns; end
        def ns=(namespace); @@ns = namespace; end
        alias_method :namespace, :ns
        alias_method :namespace=, :ns=

        # Default value of expiration timeout in seconds.
        def default_expire; @@default_expire; end

        # Assigns default value of expiration timeout in seconds.
        # Must be > 0.
        def default_expire=(value)
          raise ArgumentError, "#{name}.default_expire value must be greater than 0" unless (value = value.to_f) > 0
          @@default_expire = value
        end

        # Setup redis database and other defaults.
        # MUST BE called once before any semaphore is created.
        #
        # opts = options Hash:
        #
        # global options:
        #
        # - :connection_pool_class - default is Redis::EM::ConnectionPool
        # - :redis_factory - default is proc {|redis_opts| Redis.new redis_opts }
        # - :handler - the default value is taken from envronment variable: REDIS_EM_MUTEX_HANDLER or :auto
        #     :pure   - optimistic locking commands based (redis-server >= 2.4)
        #     :script - server scripting based (redis-server >= 2.6)
        #     :auto   - autodetect and choose best available handler
        # - :expire   - sets global Mutex.default_expire 
        # - :ns       - sets global Mutex.namespace
        # - :reconnect_max - maximum num. of attempts to re-establish
        #   connection to redis server;
        #   default is 10; set to 0 to disable re-connecting;
        #   set to -1 or :forever to attempt forever
        #
        # redis connection options:
        #
        # - :size     - redis connection pool size
        #
        # passed directly to redis_factory:
        #
        # - :url      - redis server url
        #
        # or
        #
        # - :scheme   - "redis" or "unix"
        # - :host     - redis host
        # - :port     - redis port
        # - :password - redis password
        # - :db       - redis database number
        # - :path     - redis unix-socket path
        #
        # or
        #
        # - :redis    - initialized ConnectionPool of Redis clients.
        def setup(opts = {})
          stop_watcher
          @watcher_subscribed = nil
          opts = OpenStruct.new(opts)
          yield opts if block_given?
          redis_options = {:driver => :synchrony}
          redis_updater = proc do |redis|
            redis_options.update({
              :scheme => redis.scheme,
              :host   => redis.host,
              :port   => redis.port,
              :password => redis.password,
              :db       => redis.db,
              :path     => redis.path
            }.reject {|_k, v| v.nil?})
          end
          if (redis = opts.redis) && !opts.url
            redis_updater.call redis.client
          elsif opts.url
            redis_options[:url] = opts.url
          end
          redis_updater.call opts
          pool_size = (opts.size.to_i.nonzero? || 1).abs
          self.default_expire = opts.expire if opts.expire
          self.reconnect_max_retries = opts.reconnect_max if opts.reconnect_max
          @connection_pool_class = opts.connection_pool_class if opts.connection_pool_class.kind_of?(Class)
          @redis_options = redis_options
          @reconnect_max_retries ||= DEFAULT_RECONNECT_MAX_RETRIES
          @redis_factory = opts.redis_factory if opts.redis_factory
          @redis_factory ||= proc {|opts| Redis.new opts }
          raise TypeError, "redis_factory should respond to [] method" unless @redis_factory.respond_to?(:[])
          @@ns = opts.ns if opts.ns
          unless (@@redis_pool = redis)
            unless @connection_pool_class
              begin
                require 'redis/em-connection-pool' unless defined?(Redis::EM::ConnectionPool)
              rescue LoadError
                raise ":connection_pool_class required; could not fall back to Redis::EM::ConnectionPool"
              end
              @connection_pool_class = Redis::EM::ConnectionPool
            end
            @@redis_pool = @connection_pool_class.new(size: pool_size) do
              @redis_factory[redis_options]
            end
          end
          @redis_watcher = @redis_factory[redis_options]
          start_watcher if ::EM.reactor_running?

          case handler = opts.handler || @@handler
          when Module
            @@handler = handler
          when nil, Symbol, String
            setup_handler(handler)
          else
            raise TypeError, 'handler must be Symbol or Module'
          end
        end

        def setup_handler(handler = nil)
          handler = (handler || ENV['REDIS_EM_MUTEX_HANDLER'] || :auto).to_sym.downcase
          if handler == :auto
            return unless ::EM.reactor_running?
            handler = :script
            begin
              @@redis_pool.script(:exists)
            rescue Redis::CommandError
              handler = :pure
            end
          end
          const_name = "#{handler.to_s.capitalize}HandlerMixin"
          begin
            unless self.const_defined?(const_name)
              require "redis/em-mutex/#{handler}_handler"
            end
            @@handler = self.const_get(const_name)
          rescue LoadError, NameError
            raise "handler: #{handler} not found"
          end
        end

        def ready?
          !!@@redis_pool
        end

        # resets Mutex's automatic name generator
        def reset_autoname
          @@name_index = AUTO_NAME_SEED
        end

        def wakeup_queue_all
          @@signal_queue.each_value do |queue|
            queue.each {|h| h.call }
          end
        end

        # Initializes the "unlock" channel watcher. It's called by Mutex.setup
        # internally. Should not be used under normal circumstances.
        # If EventMachine is to be re-started (or after EM.fork_reactor) this method may be used instead of
        # Mutex.setup for "lightweight" startup procedure.
        def start_watcher
          raise MutexError, "call #{self.class}::setup first" unless @redis_watcher
          return if watching?
          if @@watching # Process id changed, we've been forked alive!
            @redis_watcher = @redis_factory[@redis_options]
            @@signal_queue.clear
          end
          @@watching = $$
          retries = 0
          Fiber.new do
            begin
              @redis_watcher.subscribe(SIGNAL_QUEUE_CHANNEL) do |on|
                on.subscribe do |channel,|
                  if channel == SIGNAL_QUEUE_CHANNEL
                    @watcher_subscribed = true
                    retries = 0
                    wakeup_queue_all
                  end
                end
                on.message do |channel, message|
                  if channel == SIGNAL_QUEUE_CHANNEL
                    sig_match = {}
                    Marshal.load(message).each do |name|
                      sig_match[@@signal_queue[name].first] = true if @@signal_queue.key?(name)
                    end
                    sig_match.keys.each do |sig_proc|
                      sig_proc.call if sig_proc
                    end
                  end
                end
                on.unsubscribe do |channel,|
                  @watcher_subscribed = false if channel == SIGNAL_QUEUE_CHANNEL
                end
              end
              break
            rescue Redis::BaseConnectionError, EventMachine::ConnectionError => e
              @watcher_subscribed = false
              warn e.message
              retries+= 1
              if retries > reconnect_max_retries && reconnect_max_retries >= 0
                @@watching = false
              else
                sleep retries > 1 ? 1 : 0.1
              end
            end while watching?
          end.resume
          until @watcher_subscribed
            raise MutexError, "Can not establish watcher channel connection!" unless watching?
            fiber = Fiber.current
            ::EM.next_tick { fiber.resume }
            Fiber.yield
          end
        end

        # EM sleep helper
        def sleep(seconds)
          fiber = Fiber.current
          ::EM::Timer.new(seconds) { fiber.resume }
          Fiber.yield
        end

        # Stops the watcher of the "unlock" channel.
        # It should be called before stopping EvenMachine otherwise
        # EM might wait forever for channel connection to be closed.
        #
        # Raises MutexError if there are still some fibers waiting for lock.
        # Pass `true` to forcefully stop it. This might instead cause
        # MutexError to be raised in waiting fibers.
        def stop_watcher(force = false)
          return unless watching?
          raise MutexError, "call #{self.class}::setup first" unless @redis_watcher
          unless @@signal_queue.empty? || force
            raise MutexError, "can't stop: semaphores in queue"
          end
          @@watching = false
          if @watcher_subscribed
            @redis_watcher.unsubscribe SIGNAL_QUEUE_CHANNEL
            while @watcher_subscribed
              fiber = Fiber.current
              ::EM.next_tick { fiber.resume }
              Fiber.yield
            end
          end
        end

        # Remove all current Machine/Process locks.
        # Since there is no lock tracking mechanism, it might not be implemented easily.
        # If the need arises then it probably should be implemented.
        def sweep
          raise NotImplementedError
        end

        # Attempts to grab the lock and waits if it isn't available.
        # Raises MutexError if mutex was locked by the current owner
        # or if used before Mutex.setup.
        # Raises ArgumentError on invalid options.
        # Returns instance of Redis::EM::Mutex if lock was successfully obtained.
        # Returns `nil` if lock wasn't available within `:block` seconds.
        #
        #   Redis::EM::Mutex.lock(*names, options = {})
        #
        # - *names = lock identifiers - if none they are auto generated
        # - options = hash:
        # - :name - same as name (in case *names arguments were omitted)
        # - :block - block timeout
        # - :expire - expire timeout (see: Mutex#lock and Mutex#try_lock)
        # - :ns - namespace (otherwise global namespace is used)
        def lock(*args)
          mutex = new(*args)
          mutex if mutex.lock
        end

        # Execute block of code protected with named semaphore.
        # Returns result of code block.
        #
        #   Redis::EM::Mutex.synchronize(*names, options = {}, &block)
        # 
        # - *names = lock identifiers - if none they are auto generated
        # - options = hash:
        # - :name - same as name (in case *names arguments were omitted)
        # - :block - block timeout
        # - :expire - expire timeout (see: Mutex#lock and Mutex#try_lock)
        # - :ns - namespace (otherwise global namespace is used)
        # 
        # If `:block` is set and lock isn't obtained within `:block` seconds this method raises
        # MutexTimeout.
        # Raises MutexError if used before Mutex.setup.
        # Raises ArgumentError on invalid options.
        def synchronize(*args, &block)
          new(*args).synchronize(&block)
        end

      end

    end
  end
end

require 'redis/em-mutex/version'
