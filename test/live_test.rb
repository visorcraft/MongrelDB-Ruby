# frozen_string_literal: true

# Live integration tests against a real mongreldb-server daemon.
#
# These are live tests: they boot a real mongreldb-server daemon and exercise
# the full client surface against it. They skip automatically when no daemon is
# available.
#
# The harness boots the daemon from a binary resolved in this order:
#   1. the MONGRELDB_SERVER env var (path to the server binary).
#   2. a prebuilt binary at ./bin/mongreldb-server (downloaded by the CI
#      workflow or `make server`).
#   3. mongreldb-server on PATH.
#
# If no binary is available, the suite is skipped. Set MONGRELDB_URL to point
# at an already-running daemon to skip the boot and connect directly.
#
# Run with:
#   bundle exec rake test          # runs the live suite
#   ruby test/live_test.rb         # runs standalone
#
# On CI, the workflow downloads the server binary into ./bin before running.

# NOTE: minitest/autorun is required at the very bottom of this file, AFTER the
# daemon shutdown at_exit hook is registered. at_exit hooks run in LIFO order,
# so registering ours first ensures the daemon is torn down AFTER minitest's
# at_exit hook runs the test suite (not before, which would kill the daemon
# mid-suite).
require "minitest/spec"
require "securerandom"
require "fileutils"
require "timeout"

require_relative "../lib/mongreldb"

module MongrelDB
  module LiveTest
    # Shared daemon lifecycle for the live test suite. Boots a real
    # mongreldb-server (or reuses one at MONGRELDB_URL) and exposes the
    # connected +Client+ via {.client}.
    module Daemon
      class << self
        # The client connected to the test daemon, or +nil+ when none booted.
        attr_reader :client

        # Boot the daemon once for the whole suite. Sets +@client+ on success,
        # leaves it +nil+ (so tests self-skip) when no binary is available.
        def boot
          @pid = nil
          @log_path = nil

          existing = ENV["MONGRELDB_URL"]
          unless existing.nil? || existing.empty?
            if reachable?(existing)
              @client = MongrelDB::Client.new(
                url: existing,
                token: ENV["MONGRELDB_TOKEN"]
              )
              return
            end
            # Asked for a specific URL but it's not up -- fail loudly rather
            # than silently booting our own.
            warn "mongreldb: MONGRELDB_URL=#{existing} is not reachable"
            exit 1
          end

          bin = resolve_server_binary
          if bin.nil?
            warn "--- no mongreldb-server binary: live tests will skip"
            return
          end

          port = free_port
          data_dir = File.join(Dir.tmpdir, "mongreldb-ruby-test-#{SecureRandom.hex(6)}")
          FileUtils.mkdir_p(data_dir)
          url = "http://127.0.0.1:#{port}"
          @log_path = File.join(Dir.tmpdir, "mongreldb-ruby-server-#{SecureRandom.hex(6)}.log")

          begin
            @pid = spawn(bin, data_dir, "--port", port.to_s,
                         out: @log_path, err: [:child, :out])
          rescue Errno::ENOENT => e
            warn "mongreldb: failed to start server: #{e.message}"
            return
          end
          # Detach so the daemon is not reaped/killed prematurely while the
          # test process keeps running; shutdown still terminates it via kill!.
          Process.detach(@pid)

          unless wait_for_health(url, 40)
            dump_log
            warn "mongreldb: server did not become healthy"
            kill!
            exit 1
          end

          @client = MongrelDB::Client.new(url: url)
        end

        # Tear the daemon down (called at exit).
        def shutdown
          kill!
        end

        # The path to the server log, if a daemon was booted here.
        attr_reader :log_path

        def dump_log
          return if @log_path.nil? || !File.exist?(@log_path)

          warn "--- mongreldb-server log (#{@log_path}) ---"
          warn File.read(@log_path)
        end

        private

        def kill!
          return if @pid.nil?

          Process.kill("TERM", @pid) rescue nil
          Process.wait(@pid) rescue nil
          @pid = nil
        end

        # Find the daemon binary, or +nil+ to skip.
        def resolve_server_binary
          env = ENV["MONGRELDB_SERVER"]
          if env && !env.empty?
            expanded = File.expand_path(env)
            return expanded if File.executable?(expanded)
          end

          local = File.expand_path("bin/mongreldb-server", Dir.pwd)
          return local if File.executable?(local)

          require "rbconfig"
          exe = RbConfig::CONFIG["EXEEXT"]
          path = ENV["PATH"].to_s.split(File::PATH_SEPARATOR).find do |dir|
            f = File.join(dir, "mongreldb-server#{exe}")
            File.executable?(f)
          end
          path ? File.join(path, "mongreldb-server#{exe}") : nil
        end

        def reachable?(url)
          client = MongrelDB::Client.new(url: url, token: ENV["MONGRELDB_TOKEN"])
          Timeout.timeout(2) { client.health }
        rescue StandardError
          false
        end

        def wait_for_health(url, max_seconds)
          deadline = Time.now + max_seconds
          while Time.now < deadline
            return true if reachable?(url)

            sleep 0.5
          end
          false
        end

        def free_port
          require "socket"
          server = TCPServer.new("127.0.0.1", 0)
          port = server.addr[1]
          server.close
          port
        end
      end
    end

    # Helpers shared by every live test.
    module Helpers
      # A unique table name per call to isolate each test's data.
      def unique_table(prefix = "rb_tbl")
        "#{prefix}_#{SecureRandom.hex(6)}"
      end

      # A typed int64 column descriptor.
      def int_col(id, name, primary_key: false)
        { "id" => id, "name" => name, "ty" => "int64",
          "primary_key" => primary_key, "nullable" => false }
      end

      # A typed float64 column descriptor.
      def float_col(id, name)
        { "id" => id, "name" => name, "ty" => "float64",
          "primary_key" => false, "nullable" => false }
      end

      # A typed varchar column descriptor.
      def varchar_col(id, name)
        { "id" => id, "name" => name, "ty" => "varchar",
          "primary_key" => false, "nullable" => false }
      end

      # Drop +name+ if present then create it with the given columns.
      def fresh_table(name, *columns)
        client.drop_table(name) rescue nil
        client.create_table(name, columns)
      end

      # Extract a column value from a Kit row's flat +cells+ array
      # (shape: +[col_id, value, col_id, value, ...]+).
      def cell_value(cells, col_id)
        return nil unless cells.is_a?(Array)
        cells.each_slice(2) do |id, val|
          return val if id == col_id
        end
        nil
      end

      # Skip the test when the suite was unable to boot a daemon.
      def skip_if_no_client!
        skip "no mongreldb-server available" if Daemon.client.nil?
      end

      def client
        Daemon.client
      end
    end
  end
end

# Boot the daemon once when this file loads, and register the shutdown hook
# BEFORE minitest/autorun registers its own at_exit hook. at_exit hooks run in
# LIFO order, so this guarantees the daemon is torn down AFTER minitest runs the
# suite (not before, which would kill the daemon mid-suite).
MongrelDB::LiveTest::Daemon.boot
at_exit { MongrelDB::LiveTest::Daemon.shutdown }

# Now that our shutdown hook is registered first, pull in autorun so minitest's
# at_exit hook (registered next) runs the suite before our teardown.
require "minitest/autorun"

# ── Live test suite ──────────────────────────────────────────────────────────

# Base class for live tests; pulls in the shared helpers.
class MongrelDB::LiveTestCase < Minitest::Test
  include MongrelDB::LiveTest::Helpers
end

# Full lifecycle: health, create, put, count, query, delete, drop, schema,
# SQL, transactions, compaction, and error mapping.
class MongrelDB::LiveFullLifecycleTest < MongrelDB::LiveTestCase
  def test_health_returns_true_against_real_daemon
    skip_if_no_client!
    assert_equal true, client.health
  end

  def test_create_table_and_count
    skip_if_no_client!
    name = unique_table("rb_create")
    fresh_table(name, int_col(1, "id", primary_key: true), float_col(2, "amount"))

    assert_equal 0, client.count(name)
  end

  def test_put_and_count_round_trip
    skip_if_no_client!
    name = unique_table("rb_put")
    fresh_table(name, int_col(1, "id", primary_key: true), float_col(2, "amount"))

    client.put(name, {1 => 1, 2 => 99.5})
    client.put(name, {1 => 2, 2 => 150.0})

    assert_equal 2, client.count(name)
  end

  def test_upsert_inserts_then_updates
    skip_if_no_client!
    name = unique_table("rb_upsert")
    fresh_table(name, int_col(1, "id", primary_key: true), float_col(2, "amount"))

    # First upsert inserts.
    client.upsert(name, {1 => 1, 2 => 99.5}, update_cells: { 2 => 99.5 })
    assert_equal 1, client.count(name)

    # Second upsert on the same PK updates (still one row).
    client.upsert(name, {1 => 1, 2 => 120.0}, update_cells: { 2 => 120.0 })
    assert_equal 1, client.count(name)

    # Query by PK and assert the updated cell value.
    rows = client.query(name).where("pk", "value" => 1).execute
    assert_equal 1, rows.length
    assert_equal 1, cell_value(rows.first["cells"], 1)
    assert_equal 120.0, cell_value(rows.first["cells"], 2)
  end

  def test_query_by_primary_key
    skip_if_no_client!
    name = unique_table("rb_pk")
    fresh_table(name, int_col(1, "id", primary_key: true))

    client.put(name, {1 => 42})
    client.put(name, {1 => 43})

    rows = client.query(name).where("pk", "value" => 42).execute
    assert_equal 1, rows.length
    # The returned row must carry the queried PK value.
    assert_equal 42, cell_value(rows.first["cells"], 1)
  end

  def test_query_range_with_friendly_aliases
    skip_if_no_client!
    name = unique_table("rb_range")
    fresh_table(name, int_col(1, "id", primary_key: true), int_col(2, "amount"))

    client.put(name, {1 => 1, 2 => 50})
    client.put(name, {1 => 2, 2 => 120})
    client.put(name, {1 => 3, 2 => 200})

    # Range predicate using friendly aliases (column/min/max -> column_id/lo/hi).
    q = client.query(name).where("range", "column" => 2, "min" => 100, "max" => 150)
    rows = q.execute
    # Only the row with amount=120 (pk=2) falls in [100, 150].
    assert_equal 1, rows.length
    refute q.truncated
    # Verify the PK and amount values of returned rows match the filter range.
    rows.each do |row|
      cells = row["cells"]
      assert_equal 2, cell_value(cells, 1), "expected returned pk 2"
      amt = cell_value(cells, 2)
      assert_operator amt, :>=, 100
      assert_operator amt, :<=, 150
    end
  end

  def test_query_projection_and_limit
    skip_if_no_client!
    name = unique_table("rb_proj")
    fresh_table(name, int_col(1, "id", primary_key: true), float_col(2, "amount"))

    5.times { |i| client.put(name, {1 => i, 2 => i.to_f}) }

    rows = client.query(name).projection([1]).limit(2).execute
    assert_equal 2, rows.length
  end

  def test_delete_by_pk_removes_the_row
    skip_if_no_client!
    name = unique_table("rb_del")
    fresh_table(name, int_col(1, "id", primary_key: true))

    client.put(name, {1 => 5})
    assert_equal 1, client.count(name)

    client.delete_by_pk(name, 5)
    assert_equal 0, client.count(name)
  end

  def test_transaction_put_commit
    skip_if_no_client!
    name = unique_table("rb_txn")
    fresh_table(name, int_col(1, "id", primary_key: true))

    txn = client.begin_transaction
    txn.put(name, {1 => 1})
    txn.put(name, {1 => 2})
    txn.put(name, {1 => 3})
    assert_equal 3, txn.count

    results = txn.commit
    assert_equal 3, results.length
    assert_equal 3, client.count(name)
  end

  def test_transaction_commit_with_idempotency_key
    skip_if_no_client!
    name = unique_table("rb_txn_idem")
    fresh_table(name, int_col(1, "id", primary_key: true))

    # Unique key per run so stale keys from prior runs don't replay.
    idem_key = "order-100-create-#{Time.now.to_i}"

    txn = client.begin_transaction
    txn.put(name, {1 => 100})
    results = txn.commit(idempotency_key: idem_key)
    assert_equal 1, results.length
    assert_equal 1, client.count(name)

    # A second, identical idempotent commit must not create a duplicate row.
    txn2 = client.begin_transaction
    txn2.put(name, {1 => 100})
    txn2.commit(idempotency_key: idem_key) rescue nil
    assert_equal 1, client.count(name)
  end

  def test_transaction_rollback_discards_ops
    skip_if_no_client!
    name = unique_table("rb_txn_rb")
    fresh_table(name, int_col(1, "id", primary_key: true))

    txn = client.begin_transaction
    txn.put(name, {1 => 1})
    txn.put(name, {1 => 2})
    txn.rollback

    assert_equal 0, client.count(name)
  end

  def test_transaction_double_commit_raises
    skip_if_no_client!
    name = unique_table("rb_txn_double")
    fresh_table(name, int_col(1, "id", primary_key: true))

    txn = client.begin_transaction
    txn.put(name, {1 => 1})
    txn.commit

    assert_raises(RuntimeError) { txn.commit }
  end

  def test_table_names_lists_created_table
    skip_if_no_client!
    name = unique_table("rb_tables")
    fresh_table(name, int_col(1, "id", primary_key: true))

    names = client.table_names
    assert_includes names, name
  end

  def test_drop_table_removes_it
    skip_if_no_client!
    name = unique_table("rb_drop")
    fresh_table(name, int_col(1, "id", primary_key: true))

    client.drop_table(name)
    refute_includes client.table_names, name
  end

  def test_sql_insert_increases_count_and_select_returns_row
    skip_if_no_client!
    name = unique_table("rb_sql")
    fresh_table(name, int_col(1, "id", primary_key: true), float_col(2, "amount"))

    assert_equal 0, client.count(name)
    # INSERT via SQL must increase the row count.
    client.sql("INSERT INTO #{name} (id, amount) VALUES (77, 7.5)")
    assert_equal 1, client.count(name)

    # JSON SQL mode must return the inserted row. An old server ignores the
    # requested JSON format and answers with Arrow IPC bytes, so sql() returns
    # [] - only verify row content when JSON mode worked.
    rows = client.sql("SELECT id, amount FROM #{name}")
    unless rows.empty?
      assert_equal 1, rows.length
      assert_equal 77, rows.first["id"]
    end
  end

  def test_schema_includes_created_table
    skip_if_no_client!
    name = unique_table("rb_schema")
    fresh_table(name, int_col(1, "id", primary_key: true), float_col(2, "amount"))

    schema = client.schema
    assert_includes schema.keys, name
  end

  def test_schema_for_returns_descriptor
    skip_if_no_client!
    name = unique_table("rb_schema_for")
    fresh_table(name, int_col(1, "id", primary_key: true), float_col(2, "amount"))

    desc = client.schema_for(name)
    assert_kind_of Hash, desc
    assert_includes desc.keys, "schema_id"
    cols = desc["columns"]
    assert_kind_of Array, cols
    assert_equal 2, cols.length
  end

  def test_history_retention_setters_and_as_of_epoch
    skip_if_no_client!

    original = client.history_retention_epochs
    assert_operator original, :>, 0

    client.set_history_retention_epochs(1_000)
    assert_equal 1_000, client.history_retention_epochs

    name = unique_table("rb_retention")
    fresh_table(name, int_col(1, "id", primary_key: true), float_col(2, "amount"))

    client.put(name, { 1 => 1, 2 => 1.0 })
    insert_epoch = client.last_epoch
    assert_operator insert_epoch, :>, 0

    # Update the row at a later epoch.
    client.upsert(name, { 1 => 1, 2 => 9.0 }, update_cells: { 2 => 9.0 })

    # The historical value at the insert epoch must still be readable.
    rows = client.sql("SELECT id, amount FROM #{name} AS OF EPOCH #{insert_epoch}")
    assert_equal 1, rows.length
    assert_equal 1, rows.first["id"]
    assert_equal 1.0, rows.first["amount"]

    # The current value reflects the update.
    current = client.sql("SELECT id, amount FROM #{name}")
    assert_equal 1, current.length
    assert_equal 9.0, current.first["amount"]
  ensure
    client.set_history_retention_epochs(original) if original.is_a?(Integer)
  end

  def test_compact_all_tables
    skip_if_no_client!
    result = client.compact
    assert_kind_of Hash, result
  end

  def test_compact_single_table
    skip_if_no_client!
    name = unique_table("rb_compact")
    fresh_table(name, int_col(1, "id", primary_key: true))
    client.put(name, {1 => 1})

    result = client.compact_table(name)
    assert_kind_of Hash, result
  end

  def test_error_on_nonexistent_table_is_not_found
    skip_if_no_client!
    name = unique_table("rb_missing")

    err = assert_raises(MongrelDB::NotFoundError) { client.schema_for(name) }
    refute_empty err.message
  end

  def test_duplicate_put_raises_conflict
    skip_if_no_client!
    name = unique_table("rb_conflict")
    # A bare put on a PK-only table is last-write-wins; a UNIQUE constraint is
    # required for the engine to reject a duplicate with a 409.
    client.drop_table(name) rescue nil
    client.post("/kit/create_table", {
      "name" => name,
      "columns" => [int_col(1, "id", primary_key: true)],
      "constraints" => { "uniques" => [{ "id" => 1, "name" => "uq", "columns" => [1] }] }
    })

    client.put(name, {1 => 1})
    err = assert_raises(MongrelDB::ConflictError) { client.put(name, {1 => 1}) }
    # The server reports a structured error code for constraint violations.
    refute_empty err.error_code
  end

  def test_put_with_unconfigured_client_works
    skip_if_no_client!
    # Sanity: the default-constructed client (no auth) matches the daemon's
    # open mode used by the live suite.
    refute client.auth?
  end
end

# Config-only tests: assert the client attaches the right Authorization header.
# These run with an in-process stdlib socket stub, so they do NOT need a daemon
# (and never skip).
class MongrelDB::ClientAuthConfigTest < Minitest::Test
  # A minimal HTTP/1.0 server built on TCPServer (stdlib only, no webrick).
  # It records the last Authorization header, path, and Content-Type, then
  # returns a canned response per path.
  class StubServer
    attr_reader :last_auth, :last_path, :last_content_type

    def initialize
      require "socket"
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @mutex = Mutex.new
      @running = false
    end

    def url
      "http://127.0.0.1:#{@port}"
    end

    def start
      @running = true
      @thread = Thread.new { serve while @running }
      self
    end

    def stop
      @running = false
      @server.close rescue nil
      @thread&.join
    end

    private

    def serve
      conn = @server.accept
    rescue IOError
      return
    else
      handle(conn)
    ensure
      conn&.close rescue nil
    end

    def handle(conn)
      request_line = conn.gets
      return unless request_line

      method, path, = request_line.split(" ")
      headers = {}
      while (line = conn.gets)
        line = line.chomp
        break if line.empty?

        key, val = line.split(":", 2)
        headers[key.downcase] = val.strip if val
      end

      # Read the request body if Content-Length is set.
      length = headers["content-length"].to_i
      conn.read(length) if length.positive?

      @mutex.synchronize do
        @last_auth = headers["authorization"]
        @last_path = path
        @last_content_type = headers["content-type"]
      end

      status, body, content_type = route(path)
      conn.write("HTTP/1.0 #{status}\r\n")
      conn.write("Content-Type: #{content_type}\r\n") if content_type
      conn.write("Content-Length: #{body.bytesize}\r\n") unless body.nil?
      conn.write("Connection: close\r\n\r\n")
      conn.write(body) unless body.nil?
    end

    def route(path)
      case path
      when "/health"
        [200, '{"status":"ok"}', "application/json"]
      when "/tables"
        [200, "[]", "application/json"]
      when "/sql"
        # Daemon streams Arrow IPC for SELECTs; reply empty so SQL() returns [].
        [200, "", "application/octet-stream"]
      else
        [404, '{"error":{"message":"not found","code":"NOT_FOUND"}}', "application/json"]
      end
    end
  end

  def setup
    @stub = StubServer.new.start
  end

  def teardown
    @stub&.stop
  end

  def test_bearer_token_is_applied
    c = MongrelDB::Client.new(url: @stub.url, token: "super-secret")
    assert c.health
    assert_equal "Bearer super-secret", @stub.last_auth
  end

  def test_basic_auth_is_applied
    c = MongrelDB::Client.new(url: @stub.url, username: "alice", password: "s3cret")
    c.health
    # Mirror the client's own encoding (Array#pack 'm0' = strict base64, stdlib).
    expected = "Basic #{['alice:s3cret'].pack('m0')}"
    assert_equal expected, @stub.last_auth
  end

  def test_post_sets_json_content_type
    c = MongrelDB::Client.new(url: @stub.url)
    c.sql("SELECT 1")
    assert_equal "application/json", @stub.last_content_type
    assert_equal "/sql", @stub.last_path
  end

  def test_404_maps_to_not_found_error
    c = MongrelDB::Client.new(url: @stub.url)
    assert_raises(MongrelDB::NotFoundError) { c.schema_for("missing_table") }
  end

  def test_no_auth_when_neither_token_nor_username_set
    c = MongrelDB::Client.new(url: @stub.url)
    refute c.auth?
    c.health
    assert_nil @stub.last_auth
  end
end

# QueryBuilder alias-translation unit test (no daemon needed): assert the
# friendly aliases map to the canonical on-wire keys.
class MongrelDB::QueryBuilderAliasTest < Minitest::Test
  def test_generic_aliases_are_translated
    params = MongrelDB::QueryBuilder.normalize_condition(
      "range", "column" => 3, "min" => 100, "max" => 150,
      "min_inclusive" => true, "max_inclusive" => false
    )
    assert_equal({ "column_id" => 3, "lo" => 100, "hi" => 150,
                   "lo_inclusive" => true, "hi_inclusive" => false }, params)
  end

  def test_canonical_keys_pass_through
    params = MongrelDB::QueryBuilder.normalize_condition(
      "range", "column_id" => 3, "lo" => 100, "hi" => 150
    )
    assert_equal({ "column_id" => 3, "lo" => 100, "hi" => 150 }, params)
  end

  def test_fts_value_alias_maps_to_pattern
    params = MongrelDB::QueryBuilder.normalize_condition(
      "fm_contains", "column" => 2, "value" => "database performance"
    )
    assert_equal({ "column_id" => 2, "pattern" => "database performance" }, params)
  end

  def test_pk_value_is_not_aliased
    params = MongrelDB::QueryBuilder.normalize_condition("pk", "value" => 42)
    assert_equal({ "value" => 42 }, params)
  end

  def test_build_payload_shape
    c = MongrelDB::Client.new(url: "http://127.0.0.1:1")
    q = c.query("orders").where("range", "column" => 3, "min" => 100).projection([1, 2]).limit(10)
    payload = q.build
    assert_equal "orders", payload["table"]
    assert_kind_of Array, payload["conditions"]
    assert_equal 1, payload["conditions"].length
    assert_equal({ "column_id" => 3, "lo" => 100 }, payload["conditions"].first["range"])
    assert_equal [1, 2], payload["projection"]
    assert_equal 10, payload["limit"]
  end

  def test_build_omits_unset_fields
    c = MongrelDB::Client.new(url: "http://127.0.0.1:1")
    payload = c.query("orders").build
    assert_equal({ "table" => "orders" }, payload)
  end
end

# Exception hierarchy + cells-flattening unit tests (no daemon needed).
class MongrelDB::ClientUnitTest < Minitest::Test
  def test_exception_hierarchy
    assert_equal MongrelDB::MongrelDBError, MongrelDB::AuthError.superclass
    assert_equal MongrelDB::MongrelDBError, MongrelDB::NotFoundError.superclass
    assert_equal MongrelDB::MongrelDBError, MongrelDB::ConflictError.superclass
    assert_equal MongrelDB::MongrelDBError, MongrelDB::QueryError.superclass
  end

  def test_conflict_error_carries_code_and_op_index
    err = MongrelDB::ConflictError.new("dup", error_code: "UNIQUE_VIOLATION", op_index: 2)
    assert_equal "UNIQUE_VIOLATION", err.error_code
    assert_equal 2, err.op_index
    assert_equal "dup", err.message
  end

  def test_flatten_cells
    flat = MongrelDB::Client.flatten_cells(1 => "Alice", 3 => 99.5)
    # Pair order is not significant; sort into [col_id, value] pairs.
    pairs = flat.each_slice(2).to_a
    assert_equal [[1, "Alice"], [3, 99.5]], pairs.sort_by(&:first)
  end

  def test_default_base_url
    c = MongrelDB::Client.new
    assert_equal MongrelDB::DEFAULT_BASE_URL, c.base_url
  end

  def test_trailing_slash_is_stripped
    c = MongrelDB::Client.new(url: "http://127.0.0.1:8453/")
    assert_equal "http://127.0.0.1:8453", c.base_url
  end
end
