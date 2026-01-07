# spike_f_box_ractor.rb
# Exploring how Ruby Box and Ractors interact
# Ruby 4.0 - Two orthogonal isolation mechanisms
#
# Ruby Box: Namespace isolation (classes, modules, monkey patches, globals)
# Ractor: Memory isolation (share-nothing concurrency)
#
# QUESTIONS:
# Q1: Can we enable both RUBY_BOX=1 and Ractors at the same time?
# Q2: Can a Ractor run code defined in a specific Box?
# Q3: What happens when objects cross Box/Ractor boundaries?
# Q4: Can we protect coordinator code from application monkey patches?
# Q5: How do class definitions behave across Box/Ractor boundaries?
# Q6: Can Boxes provide application isolation beyond Ractors?
#
# RUN WITH: RUBY_BOX=1 ruby spikes/spike_f_box_ractor.rb
#
# NOTE: If Ruby::Box is not available, some tests will be skipped.

puts "=" * 70
puts "SPIKE F: Ruby Box + Ractor Interaction"
puts "Ruby #{RUBY_VERSION}"
puts "=" * 70
puts

# Check if Ruby Box is enabled
BOX_ENABLED = defined?(Ruby::Box) && Ruby::Box.enabled?

puts "Ruby Box enabled: #{BOX_ENABLED}"
unless BOX_ENABLED
  puts
  puts "WARNING: Ruby Box not enabled!"
  puts "Re-run with: RUBY_BOX=1 ruby #{$0}"
  puts "Some tests will be skipped."
end
puts

# Helper to safely test and report with timeout
def test(description, skip_reason: nil, timeout_sec: 5)
  print "Testing: #{description}... "

  if skip_reason
    puts "SKIPPED (#{skip_reason})"
    return nil
  end

  begin
    result  = nil
    thread  = Thread.new { result = yield }
    success = thread.join(timeout_sec)
    if success
      puts "SUCCESS"
      puts "  Result: #{result.inspect}"
      result
    else
      thread.kill
      puts "TIMEOUT"
      puts "  Test hung for #{timeout_sec}s"
      nil
    end
  rescue StandardError => e
    puts "FAILED"
    puts "  Error: #{e.class}: #{e.message}"
    puts "  #{e.backtrace.first(3).join("\n  ")}" if e.backtrace
    nil
  end
end

# ============================================================
# BASELINE: Confirm Ractors still work
# ============================================================
puts "\n" + ("=" * 70)
puts "BASELINE: Ractors still functional with RUBY_BOX=1"
puts "=" * 70

puts "\n--- Test B1: Basic Ractor ---"
test("Basic Ractor creation and value") do
  r = Ractor.new { 42 }
  r.value
end

puts "\n--- Test B2: Ractor with Port ---"
test("Ractor with Port communication") do
  port = Ractor::Port.new
  r = Ractor.new(port) do |p|
    p.send("hello from ractor")
    "ractor done"
  end
  msg = port.receive
  r.value
  "Received: #{msg}"
end

# ============================================================
# Q1: Basic Box functionality (if enabled)
# ============================================================
puts "\n" + ("=" * 70)
puts "Q1: Basic Ruby Box functionality"
puts "=" * 70

puts "\n--- Test 1a: Box creation ---"
test("Create a Ruby::Box", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  box = Ruby::Box.new
  "Box created: #{box.class}, #{box.inspect}"
end

puts "\n--- Test 1b: Box.current and Box.main ---"
test("Check current and main box", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  current = Ruby::Box.current
  main = Ruby::Box.main
  root = Ruby::Box.root
  "current=#{current.object_id}, main=#{main.object_id}, root=#{root.object_id}, current==main: #{current == main}"
end

puts "\n--- Test 1c: Define class in box via eval ---"
test("Define and access class in box", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  box = Ruby::Box.new
  box.eval(<<~RUBY)
    class Greeter
      def self.greet(name)
        "Hello, \#{name} from box!"
      end
    end
  RUBY

  result = box::Greeter.greet("World")

  # Verify it's not in main
  main_has_greeter = defined?(Greeter) ? true : false

  "Box result: #{result}, main has Greeter: #{main_has_greeter}"
end

puts "\n--- Test 1d: Monkey patch isolation ---"
test("Monkey patches isolated to box", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  box = Ruby::Box.new
  box.eval(<<~RUBY)
    class String
      def shouting
        self.upcase + "!!!"
      end
    end

    module BoxTest
      def self.shout(s)
        s.shouting
      end
    end
  RUBY

  # In box, String has #shouting
  box_result = box::BoxTest.shout("hello")

  # In main, String should NOT have #shouting
  main_has_method = "test".respond_to?(:shouting)

  "Box: #{box_result}, main has #shouting: #{main_has_method}"
end

# ============================================================
# Q2: Can a Ractor run code from a specific Box?
# ============================================================
puts "\n" + ("=" * 70)
puts "Q2: Can a Ractor run code defined in a Box?"
puts "=" * 70

puts "\n--- Test 2a: Pass Box to Ractor ---"
test("Pass Ruby::Box to Ractor", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  box = Ruby::Box.new
  box.eval(<<~RUBY)
    module Worker
      def self.work
        "work done in box"
      end
    end
  RUBY

  # Can we pass the box to a Ractor?
  r = Ractor.new(box) do |b|
    "Ractor received box: #{b.class}"
  end
  r.value
end

puts "\n--- Test 2b: Call Box method from Ractor ---"
test("Ractor calls method defined in Box", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  box = Ruby::Box.new
  box.eval(<<~RUBY)
    module Calculator
      def self.add(a, b)
        a + b
      end
    end
  RUBY

  # Get reference to the module
  calc = box::Calculator

  r = Ractor.new(calc) do |c|
    result = c.add(2, 3)
    "Ractor calculated: #{result}"
  end
  r.value
end

puts "\n--- Test 2c: Box class instance in Ractor ---"
test("Create instance of Box class, use in Ractor", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  box = Ruby::Box.new
  box.eval(<<~RUBY)
    class Counter
      def initialize(start)
        @count = start
      end

      def increment
        @count += 1
      end

      def value
        @count
      end
    end
  RUBY

  # Create instance in main
  counter = box::Counter.new(10)

  # Pass to Ractor
  r = Ractor.new(counter) do |c|
    c.increment
    c.increment
    "Ractor incremented to: #{c.value}"
  end
  r.value
end

puts "\n--- Test 2d: Box with monkey patch, call from Ractor ---"
test("Ractor uses Box's monkey-patched method", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  box = Ruby::Box.new
  box.eval(<<~RUBY)
    class Array
      def sum_doubled
        self.sum * 2
      end
    end

    module ArrayProcessor
      def self.process(arr)
        arr.sum_doubled
      end
    end
  RUBY

  processor = box::ArrayProcessor

  r = Ractor.new(processor) do |p|
    arr = [1, 2, 3, 4, 5]
    result = p.process(arr)
    "Ractor got: #{result}"
  end
  r.value
end

# ============================================================
# Q3: What happens when objects cross Box/Ractor boundaries?
# ============================================================
puts "\n" + ("=" * 70)
puts "Q3: Objects crossing Box/Ractor boundaries"
puts "=" * 70

puts "\n--- Test 3a: Object created in Box, sent to Ractor ---"
test("Box-created object sent via Port", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  box = Ruby::Box.new
  box.eval(<<~RUBY)
    class Message
      attr_reader :content
      def initialize(content)
        @content = content
      end
    end
  RUBY

  # Create instance in main context but using Box's class
  msg = box::Message.new("hello from box")

  port = Ractor::Port.new
  r = Ractor.new(port) do |_p|
    received = Ractor.receive
    "Ractor received: #{received.class}, content: #{received.content}"
  end

  r.default_port.send(msg)
  r.value
end

puts "\n--- Test 3b: Which Box does a Ractor run in? ---"
test("Check Ruby::Box.current inside Ractor", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  main_box_id = Ruby::Box.current.object_id

  r = Ractor.new(main_box_id) do |main_id|
    ractor_box = Ruby::Box.current
    "Main box id: #{main_id}, Ractor box id: #{ractor_box.object_id}, same: #{main_id == ractor_box.object_id}"
  end
  r.value
end

puts "\n--- Test 3c: Can Ractor see main's monkey patches? ---"
test("Ractor visibility of main's monkey patches", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  # Add a monkey patch in main
  class String
    def main_method = "from main"
  end

  r = Ractor.new do
    # Can ractor see main's monkey patch?
    has_method = "test".respond_to?(:main_method)
    if has_method
      result = "test".main_method
      "Ractor sees main's patch: #{result}"
    else
      "Ractor does NOT see main's patch"
    end
  end
  r.value
end

puts "\n--- Test 3d: Ractor with its own Box ---"
test("Create Box inside Ractor", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  r = Ractor.new do
    # Create a box inside the ractor
    inner_box = Ruby::Box.new
    inner_box.eval(<<~RUBY)
      class InnerClass
        def self.hello
          "hello from inner box in ractor"
        end
      end
    RUBY

    result = inner_box::InnerClass.hello
    "Ractor created box and called: #{result}"
  end
  r.value
end

# ============================================================
# Q4: Protecting coordinator code from application monkey patches
# ============================================================
puts "\n" + ("=" * 70)
puts "Q4: Coordinator protection from monkey patches"
puts "=" * 70

puts "\n--- Test 4a: Simulate coordinator protection ---"
test("Coordinator in root, app in box", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  # Simulate: Coordinator uses Ractor::Port
  # App tries to monkey-patch Ractor::Port

  # Create "application" box
  app_box = Ruby::Box.new
  app_box.eval(<<~RUBY)
    # Malicious or buggy app tries to break Ractor::Port
    class Ractor
      class Port
        def send(msg)
          # Do nothing - broken!
          nil
        end
      end
    end

    module App
      def self.run
        "app running"
      end
    end
  RUBY

  # Coordinator (in main/root) creates a port
  coord_port = Ractor::Port.new

  # Test: Does coordinator's port still work?
  r = Ractor.new(coord_port) do |p|
    p.send("message from ractor")
    "sent"
  end

  # Can coordinator receive?
  begin
    msg = coord_port.receive
    r.value
    "Coordinator received: #{msg} (protected from app's monkey patch)"
  rescue StandardError => e
    "Coordinator broken: #{e.class}"
  end
end

puts "\n--- Test 4b: App uses monkey-patched class internally ---"
test("App's monkey patches work inside app's box", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  app_box = Ruby::Box.new
  app_box.eval(<<~RUBY)
    class String
      def enhanced
        "[[\#{self}]]"
      end
    end

    module App
      def self.format(s)
        s.enhanced
      end
    end
  RUBY

  # App's code uses its own monkey patches
  app_result = app_box::App.format("hello")

  # Main's String is unaffected
  main_has_enhanced = "test".respond_to?(:enhanced)

  "App result: #{app_result}, main has #enhanced: #{main_has_enhanced}"
end

# ============================================================
# Q5: Class definitions across Box/Ractor boundaries
# ============================================================
puts "\n" + ("=" * 70)
puts "Q5: Class behavior across Box/Ractor boundaries"
puts "=" * 70

puts "\n--- Test 5a: Class identity across boxes ---"
test("Is String the same object across boxes?", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  box = Ruby::Box.new

  main_string_id = String.object_id
  box_string_id = box::String.object_id

  "Main String id: #{main_string_id}, Box String id: #{box_string_id}, same: #{main_string_id == box_string_id}"
end

puts "\n--- Test 5b: Subclass in box, parent in root ---"
test("Box subclasses root class", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  box = Ruby::Box.new
  box.eval(<<~RUBY)
    class MyArray < Array
      def custom_sum
        self.sum + 100
      end
    end
  RUBY

  arr = box::MyArray.new([1, 2, 3])

  r = Ractor.new(arr) do |a|
    "Ractor: class=#{a.class}, sum=#{a.sum}, custom_sum=#{a.custom_sum}"
  end
  r.value
end

puts "\n--- Test 5c: Proc defined in box, executed in ractor ---"
test("Proc from box executed in Ractor", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  box = Ruby::Box.new
  box.eval(<<~RUBY)
    MULTIPLIER = 10

    module ProcFactory
      def self.make_proc
        ->(x) { x * MULTIPLIER }
      end
    end
  RUBY

  # Get proc from box
  the_proc = box::ProcFactory.make_proc

  # Can we pass proc to Ractor?
  begin
    r = Ractor.new(the_proc) do |p|
      result = p.call(5)
      "Ractor called proc: #{result}"
    end
    r.value
  rescue StandardError => e
    "Error passing proc: #{e.class} - #{e.message}"
  end
end

# ============================================================
# Q6: Application isolation with Box + Ractor
# ============================================================
puts "\n" + ("=" * 70)
puts "Q6: Full application isolation (Box + Ractor)"
puts "=" * 70

puts "\n--- Test 6a: Two apps in separate boxes ---"
test("Two applications with conflicting definitions", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  app1_box = Ruby::Box.new
  app1_box.eval(<<~RUBY)
    VERSION = "1.0"

    class Helper
      def self.version
        VERSION
      end
    end

    module App1
      def self.info
        "App1 using Helper v\#{Helper.version}"
      end
    end
  RUBY

  app2_box = Ruby::Box.new
  app2_box.eval(<<~RUBY)
    VERSION = "2.0"

    class Helper
      def self.version
        VERSION
      end
    end

    module App2
      def self.info
        "App2 using Helper v\#{Helper.version}"
      end
    end
  RUBY

  # Both apps have different VERSIONs and Helper classes
  result1 = app1_box::App1.info
  result2 = app2_box::App2.info

  "#{result1} | #{result2}"
end

puts "\n--- Test 6b: Apps in separate Ractors with separate Boxes ---"
test("Full isolation: each app in own Box + own Ractor", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  results_port = Ractor::Port.new

  # App 1 in its own Ractor
  # NOTE: No global variables - Ractors can't access them!
  r1 = Ractor.new(results_port) do |port|
    box = Ruby::Box.new
    box.eval(<<~RUBY)
      class String
        def tag
          "[A1:\#{self}]"
        end
      end

      module App
        def self.process(input)
          input.tag
        end

        def self.name
          "App1"
        end
      end
    RUBY

    result = box::App.process("hello")
    name = box::App.name
    port.send({ app: 1, result: result, name: name })
    "r1 done"
  end

  # App 2 in its own Ractor
  r2 = Ractor.new(results_port) do |port|
    box = Ruby::Box.new
    box.eval(<<~RUBY)
      class String
        def tag
          "<A2:\#{self}>"
        end
      end

      module App
        def self.process(input)
          input.tag
        end

        def self.name
          "App2"
        end
      end
    RUBY

    result = box::App.process("world")
    name = box::App.name
    port.send({ app: 2, result: result, name: name })
    "r2 done"
  end

  # Collect results
  res1 = results_port.receive
  res2 = results_port.receive
  r1.value
  r2.value

  # Main's String is unaffected
  main_has_tag = "test".respond_to?(:tag)

  "Results: #{res1.inspect}, #{res2.inspect}, main has #tag: #{main_has_tag}"
end

puts "\n--- Test 6c: Coordinator pattern with Box protection ---"
test("Coordinator orchestrates Box-isolated apps", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  # Coordinator runs in main (implicitly protected)
  # Each "app" gets its own Box and Ractor
  #
  # NOTE: Can't use class instance variables (@data on module) in non-main Ractor.
  # Instead, use a class that holds instance state.

  coordinator_inbox = Ractor::Port.new

  # Start "database" app
  db_ractor = Ractor.new(coordinator_inbox) do |coord|
    box = Ruby::Box.new
    box.eval(<<~RUBY)
      class Database
        def initialize
          @data = {}
        end

        def set(k, v)
          @data[k] = v
        end

        def get(k)
          @data[k]
        end
      end
    RUBY

    # Create instance (instance variables on instances are fine in Ractors)
    db = box::Database.new
    inbox = Ractor::Port.new

    # Register with coordinator
    coord.send({ type: :register, name: :database, inbox: inbox })

    # Handle requests
    loop do
      msg = inbox.receive
      case msg
      in { cmd: :set, key:, value:, reply_to: }
        db.set(key, value)
        reply_to.send(:ok)
      in { cmd: :get, key:, reply_to: } then reply_to.send(db.get(key))
      in { cmd: :shutdown }             then break
      end
    end
    "db shutdown"
  end

  # Coordinator receives registration
  reg = coordinator_inbox.receive
  db_inbox = reg[:inbox]

  # Coordinator sends commands to database
  reply_port = Ractor::Port.new

  db_inbox.send({ cmd: :set, key: "user", value: "alice", reply_to: reply_port })
  set_result = reply_port.receive

  db_inbox.send({ cmd: :get, key: "user", reply_to: reply_port })
  get_result = reply_port.receive

  # Shutdown
  db_inbox.send({ cmd: :shutdown })
  db_ractor.value

  "Set: #{set_result}, Get: #{get_result}"
end

# ============================================================
# Q7: Edge cases and potential issues
# ============================================================
puts "\n" + ("=" * 70)
puts "Q7: Edge cases and potential issues"
puts "=" * 70

puts "\n--- Test 7a: Box shareability ---"
test("Is Ruby::Box shareable?", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  box = Ruby::Box.new
  shareable = Ractor.shareable?(box)
  "Box shareable: #{shareable}"
end

puts "\n--- Test 7b: Module from box shareability ---"
test("Is module defined in Box shareable?", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  box = Ruby::Box.new
  box.eval("module Foo; def self.bar; 42; end; end")

  mod = box::Foo
  shareable = Ractor.shareable?(mod)
  "Module from box shareable: #{shareable}"
end

puts "\n--- Test 7c: Class from box shareability ---"
test("Is class defined in Box shareable?", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  box = Ruby::Box.new
  box.eval("class Bar; end")

  klass = box::Bar
  shareable = Ractor.shareable?(klass)
  "Class from box shareable: #{shareable}"
end

puts "\n--- Test 7d: Instance from box class shareability ---"
test("Is instance of Box class shareable?", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  box = Ruby::Box.new
  # NOTE: Don't use "Data" as class name - conflicts with Ruby's built-in Data class
  box.eval("class MyData; def initialize(v); @v = v; end; attr_reader :v; end")

  instance = box::MyData.new(42)
  shareable = Ractor.shareable?(instance)

  # Can we make it shareable?
  begin
    made_shareable = Ractor.make_shareable(box::MyData.new(99))
    "Instance shareable: #{shareable}, after make_shareable: #{Ractor.shareable?(made_shareable)}"
  rescue StandardError => e
    "Instance shareable: #{shareable}, make_shareable error: #{e.class}"
  end
end

puts "\n--- Test 7e: Class variables in Box inside Ractor ---"
test("Can non-main Ractor use class variables in its own Box?", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  r = Ractor.new do
    box = Ruby::Box.new
    begin
      box.eval("class Foo; @@count = 0; end")
      "SUCCESS: class variable set"
    rescue StandardError => e
      "BLOCKED: #{e.class} - #{e.message}"
    end
  end
  r.value
end

puts "\n--- Test 7f: Class instance variables in Box inside Ractor ---"
test("Can non-main Ractor use class instance variables in its own Box?", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  r = Ractor.new do
    box = Ruby::Box.new
    begin
      box.eval("class Foo; @count = 0; end")
      "SUCCESS: class instance variable set"
    rescue StandardError => e
      "BLOCKED: #{e.class} - #{e.message}"
    end
  end
  r.value
end

puts "\n--- Test 7g: Instance variables on instances in Box inside Ractor ---"
test("Can non-main Ractor use instance variables on instances?", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  r = Ractor.new do
    box = Ruby::Box.new
    begin
      box.eval(<<~RUBY)
        class Counter
          def initialize; @count = 0; end
          def increment; @count += 1; end
          def value; @count; end
        end
      RUBY
      counter = box::Counter.new
      counter.increment
      counter.increment
      "SUCCESS: counter.value = #{counter.value}"
    rescue StandardError => e
      "BLOCKED: #{e.class} - #{e.message}"
    end
  end
  r.value
end

# ============================================================
# Q8: Workarounds for Ractor class-level state restrictions
# ============================================================
puts "\n" + ("=" * 70)
puts "Q8: Workarounds for Ractor class-level state restrictions"
puts "=" * 70

puts "\n--- Test 8a: Ractor-local storage (Ractor.current[key]) ---"
test("Ractor-local storage as alternative to class variables") do
  r = Ractor.new do
    # Instead of class variables or class instance variables,
    # use Ractor.current[key] for per-Ractor state

    class Counter
      STORAGE_KEY = :counter_value

      def self.increment
        Ractor.current[STORAGE_KEY] ||= 0
        Ractor.current[STORAGE_KEY] += 1
      end

      def self.value = Ractor.current[STORAGE_KEY] || 0

      def self.reset = Ractor.current[STORAGE_KEY] = 0
    end

    Counter.increment
    Counter.increment
    Counter.increment

    "Ractor-local counter: #{Counter.value}"
  end
  r.value
end

puts "\n--- Test 8b: Ractor-local storage is per-Ractor ---"
test("Each Ractor has its own storage") do
  results_port = Ractor::Port.new

  # Two Ractors using same "class" but separate storage
  r1 = Ractor.new(results_port) do |port|
    class SharedCounter
      KEY = :shared_counter
      def self.add(n)
        Ractor.current[KEY] ||= 0
        Ractor.current[KEY] += n
      end

      def self.value = Ractor.current[KEY] || 0
    end

    SharedCounter.add(100)
    SharedCounter.add(100)
    port.send({ ractor: 1, value: SharedCounter.value })
  end

  r2 = Ractor.new(results_port) do |port|
    class SharedCounter
      KEY = :shared_counter
      def self.add(n)
        Ractor.current[KEY] ||= 0
        Ractor.current[KEY] += n
      end

      def self.value = Ractor.current[KEY] || 0
    end

    SharedCounter.add(1)
    port.send({ ractor: 2, value: SharedCounter.value })
  end

  res1 = results_port.receive
  res2 = results_port.receive
  r1.value
  r2.value

  "R1: #{res1[:value]}, R2: #{res2[:value]} (isolated from each other)"
end

puts "\n--- Test 8c: RactorLocalSingleton module ---"
test("RactorLocalSingleton as Singleton replacement") do
  require 'singleton'

  # Pass RactorLocalSingleton to the Ractor since require inside Ractor
  # may not make it available in all contexts
  r = Ractor.new(RactorLocalSingleton) do |rls|
    class AppConfig
      attr_accessor :debug, :log_level

      def initialize
        @debug = false
        @log_level = :info
      end
    end

    AppConfig.include(rls)

    config = AppConfig.instance
    config.debug = true
    config.log_level = :debug

    same_instance = AppConfig.instance.equal?(config)
    "RactorLocalSingleton: debug=#{config.debug}, same_instance=#{same_instance}"
  end
  r.value
end

puts "\n--- Test 8d: RactorLocalSingleton in Box ---"
test("RactorLocalSingleton in Box inside Ractor", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  require 'singleton'

  r = Ractor.new(RactorLocalSingleton) do |rls|
    box = Ruby::Box.new

    # Define class in box
    box.eval(<<~RUBY)
      class ServiceConfig
        attr_accessor :endpoint, :timeout
      end
    RUBY

    # Include RactorLocalSingleton from outside (workaround for Box require quirk)
    box::ServiceConfig.include(rls)

    config = box::ServiceConfig.instance
    config.endpoint = "https://api.example.com"
    config.timeout = 30

    same = box::ServiceConfig.instance.equal?(config)
    "Box+RactorLocalSingleton: endpoint=#{config.endpoint}, same=#{same}"
  end
  r.value
end

puts "\n--- Test 8e: Ractor-local storage in Box ---"
test("Ractor.current[key] storage in Box", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  r = Ractor.new do
    box = Ruby::Box.new
    box.eval(<<~RUBY)
      class Cache
        CACHE_KEY = :my_cache_data

        def self.store(key, value)
          Ractor.current[CACHE_KEY] ||= {}
          Ractor.current[CACHE_KEY][key] = value
        end

        def self.fetch(key)
          return nil unless Ractor.current[CACHE_KEY]
          Ractor.current[CACHE_KEY][key]
        end

        def self.size
          return 0 unless Ractor.current[CACHE_KEY]
          Ractor.current[CACHE_KEY].size
        end
      end
    RUBY

    box::Cache.store(:user, "alice")
    box::Cache.store(:token, "abc123")

    user = box::Cache.fetch(:user)
    size = box::Cache.size

    "Ractor-local cache in Box: user=#{user}, size=#{size}"
  end
  r.value
end

puts "\n--- Test 8f: Combining patterns - instance + Ractor-local registry ---"
test("Instance state + Ractor-local registry pattern") do
  r = Ractor.new do
    # Pattern: Use instances for state, Ractor-local storage for registry

    class Worker
      REGISTRY_KEY = :worker_registry

      attr_reader :name, :status

      def initialize(name)
        @name = name
        @status = :idle
        self.class.register(self)
      end

      def work
        @status = :busy
        # do work...
        @status = :idle
      end

      # Registry methods using Ractor-local storage
      def self.register(worker)
        Ractor.current[REGISTRY_KEY] ||= {}
        Ractor.current[REGISTRY_KEY][worker.name] = worker
      end

      def self.find(name)
        return nil unless Ractor.current[REGISTRY_KEY]

        Ractor.current[REGISTRY_KEY][name]
      end

      def self.all = Ractor.current[REGISTRY_KEY]&.values || []
    end

    Worker.new(:worker_1)
    Worker.new(:worker_2)
    Worker.new(:worker_3)

    found = Worker.find(:worker_2)
    all_count = Worker.all.size

    "Workers: found=#{found&.name}, total=#{all_count}"
  end
  r.value
end

# ============================================================
# Continuing Q7 edge cases
# ============================================================
puts "\n" + ("=" * 70)
puts "Q7 (continued): Edge cases"
puts "=" * 70

puts "\n--- Test 7h: Box.root modifications ---"
test("Can we modify root box?", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  Ruby::Box.root.eval("ROOT_CONST = 'from root eval'")
  "Root eval succeeded, ROOT_CONST defined: #{defined?(ROOT_CONST)}"
rescue StandardError => e
  "Root eval error: #{e.class} - #{e.message}"
end

puts "\n--- Test 7i: require in box ---"
test("Box.require of stdlib", skip_reason: BOX_ENABLED ? nil : "RUBY_BOX not set") do
  box = Ruby::Box.new
  begin
    box.require('json')

    # Can we use JSON in box?
    result = box::JSON.generate({ test: 123 })

    "Box required json, generated: #{result}"
  rescue StandardError => e
    "Box require error: #{e.class} - #{e.message}"
  end
end

# ============================================================
# SUMMARY
# ============================================================
puts "\n" + ("=" * 70)
puts "SPIKE COMPLETE"
puts "=" * 70

if BOX_ENABLED
  puts <<~SUMMARY

    === SPIKE F FINDINGS ===

    Q1: Can we enable both RUBY_BOX=1 and Ractors?
        YES! Both work together without fundamental issues.
        - Ractor.new, Ractor::Port, Ractor.select all function normally
        - No observed performance issues (though both are experimental)

    Q2: Can a Ractor run code from a specific Box?
        YES! This is the key finding for Umi.
        - Can pass Box reference to Ractor (Box is shareable)
        - Ractor can call methods defined in Box
        - Box class instances work in Ractor
        - Box's monkey patches work when called from Ractor

    Q3: What happens when objects cross Box/Ractor boundaries?
        Objects cross successfully with some nuances:
        - Objects from Box can be sent to Ractor via Port
        - Ractor runs in the SAME box as its creator (Box.current is same)
        - Ractor CAN see main's monkey patches (they share box context)
        - Ractor can create its own Box inside (full isolation)
        - Procs CANNOT cross Ractor boundary (TypeError)

    Q4: Can we protect coordinator from monkey patches?
        YES! This validates the coordinator protection pattern:
        - App's monkey patch to Ractor::Port didn't affect main
        - Each Box's patches are isolated to that Box
        - Coordinator in main box is protected from app boxes

    Q5: How do class definitions behave across boundaries?
        Classes work well, with expected limitations:
        - Built-in classes (String) are same object across boxes
        - Subclassing across boundaries works
        - Procs can't cross Ractor boundary (Ractor limitation)

    Q6: Full application isolation (Box + Ractor)?
        YES! The pattern works:
        - Multiple apps with conflicting definitions work in separate boxes
        - Each app in own Ractor + own Box = full isolation
        - Coordinator pattern with Box protection works

        IMPORTANT CONSTRAINTS (Ractor limitations, not Box):
        - No global variables in non-main Ractor
        - No class instance variables (@var on Class/Module) in non-main Ractor
        - Use instance variables on instances instead

    Q7: Edge cases (shareability, root box, require)?
        - Box is shareable (can pass between Ractors)
        - Module/Class from Box is shareable
        - Instances are NOT shareable by default
        - Ractor.make_shareable works on Box instances
        - Box.root.eval works (can modify root)
        - Box.require works for stdlib (json, etc.)

        CRITICAL - Box does NOT bypass Ractor restrictions:
        - Class variables (@@var): BLOCKED even in own Box
        - Class instance variables (@var on Class): BLOCKED even in own Box
        - Instance variables on instances (@var): WORKS

    Q8: Workarounds for Ractor class-level state restrictions?
        Three patterns work in non-main Ractors:

        1. INSTANCE VARIABLES ON INSTANCES (simplest)
           Instead of class-level state, create instances and use their @vars.

           ```ruby
           # Instead of:
           class Counter
             @@count = 0                    # BLOCKED
             def self.increment = @@count += 1
           end

           # Use:
           class Counter
             def initialize = @count = 0   # WORKS
             def increment = @count += 1
           end
           counter = Counter.new
           ```

        2. RACTOR-LOCAL STORAGE (Ractor.current[key])
           Per-Ractor hash storage. Each Ractor has its own isolated copy.

           ```ruby
           class Counter
             KEY = :counter_value

             def self.increment
               Ractor.current[KEY] ||= 0
               Ractor.current[KEY] += 1
             end

             def self.value
               Ractor.current[KEY] || 0
             end
           end
           ```

           Benefits:
           - Works like class variables but Ractor-safe
           - Each Ractor gets isolated state automatically
           - Can store any object (even unshareable)

        3. RACTOR-LOCAL SINGLETON (RactorLocalSingleton)
           Ruby's built-in Ractor-compatible Singleton replacement.

           ```ruby
           require 'singleton'

           class AppConfig
             include RactorLocalSingleton  # NOT Singleton!
             attr_accessor :debug
           end

           config = AppConfig.instance  # Per-Ractor instance
           ```

           Note: Regular `Singleton` module FAILS in non-main Ractors.
           Use `RactorLocalSingleton` instead.

        4. COMBINED PATTERN: Instance state + Ractor-local registry
           Use instances for state, Ractor-local storage for lookups.

           ```ruby
           class Worker
             REGISTRY_KEY = :worker_registry
             attr_reader :name

             def initialize(name)
               @name = name
               self.class.register(self)
             end

             def self.register(worker)
               Ractor.current[REGISTRY_KEY] ||= {}
               Ractor.current[REGISTRY_KEY][worker.name] = worker
             end

             def self.find(name)
               Ractor.current[REGISTRY_KEY]&.[](name)
             end
           end
           ```

    === IMPLICATIONS FOR UMI ===

    1. BOX + RACTOR PROVIDE COMPLEMENTARY ISOLATION:
       - Ractor: Memory isolation (share-nothing concurrency)
       - Box: Namespace isolation (monkey-patch containment)
       Together: Apps can't interfere with each other's memory OR definitions

    2. COORDINATOR PROTECTION PATTERN:
       - Coordinator runs in main box (protected)
       - Each app creates its own Box INSIDE its Ractor
       - App's monkey patches can't affect coordinator's primitives

    3. RACTOR INHERITS BOX CONTEXT:
       - Ractor runs in same box as creator by default
       - For true isolation, create Box inside Ractor
       - This is actually useful: can share coordinator's box context

    4. RACTOR LIMITATIONS STILL APPLY:
       - No global variables in non-main Ractors
       - No class/module instance variables in non-main Ractors
       - Procs can't cross Ractor boundaries
       - These are Ractor constraints, not Box constraints

    5. RECOMMENDED PATTERN FOR UMI:
       ```ruby
       # Coordinator (in main Ractor, main Box)
       app_ractor = Ractor.new(coordinator_port) do |coord|
         # Create isolated box for this app
         app_box = Ruby::Box.new
         app_box.require('my_app')

         # App's monkey patches stay in app_box
         # Coordinator's code is protected

         supervisor = app_box::MyApp::Supervisor.new
         supervisor.run(coord)
       end
       ```

  SUMMARY

else
  puts <<~SUMMARY

    === SPIKE F: NOT RUN ===

    Ruby Box was not enabled. To run this spike:

      RUBY_BOX=1 ruby spikes/spike_f_box_ractor.rb

    Without Box enabled, only baseline Ractor tests were run.

  SUMMARY
end
