# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

require_relative "mongreldb/version"
require_relative "mongreldb/query_builder"
require_relative "mongreldb/transaction"

# MongrelDB is the pure-Ruby HTTP client for a running `mongreldb-server`
# daemon.
#
# It talks to the daemon's JSON API over the standard-library `net/http`
# client -- no external gems are required at runtime. The API mirrors the
# MongrelDB PHP, Go, and Java clients: typed CRUD over the Kit transaction
# endpoint, a fluent query builder that pushes conditions down to the engine's
# native indexes, idempotent batch transactions, full SQL access, schema
# introspection, and maintenance operations.
#
# Connect with a base URL and optional credentials:
#
#   db = MongrelDB::Client.new(url: "http://127.0.0.1:8453")
#   db.health  # => true
#
# See https://www.MongrelDB.com for the daemon and full documentation.
module MongrelDB
  # Default daemon address used when none is supplied.
  DEFAULT_BASE_URL = "http://127.0.0.1:8453"

  # Maximum response body size (256 MB). Bodies larger than this are aborted
  # with a {QueryError} to guard client memory against a malicious or buggy
  # server.
  MAX_RESPONSE_BYTES = 268_435_456

  # Base class for every error raised by the client. Rescue this to catch any
  # MongrelDB failure (network, auth, not-found, conflict, query).
  class MongrelDBError < StandardError
  end

  # Raised for HTTP 401 or 403 responses -- bad or missing credentials.
  class AuthError < MongrelDBError
  end

  # Raised for HTTP 404 responses -- a missing table, schema, or resource.
  class NotFoundError < MongrelDBError
  end

  # Raised for HTTP 409 responses -- a unique, foreign-key, check, or trigger
  # constraint violation. Carries the server's structured error code (e.g.
  # +UNIQUE_VIOLATION+) and, when the daemon reports one, the index of the
  # offending operation within the transaction.
  class ConflictError < MongrelDBError
    # The server's structured error code, when present (e.g. +UNIQUE_VIOLATION+,
    # +FK_VIOLATION+). Empty string when the server did not supply one.
    attr_reader :error_code

    # The index of the offending operation within a transaction commit, when
    # the daemon reports one. +nil+ otherwise.
    attr_reader :op_index

    def initialize(message, error_code: "", op_index: nil)
      super(message)
      @error_code = error_code
      @op_index = op_index
    end
  end

  # Raised for HTTP 400 and 5xx responses, and for any request-level failure
  # not covered by the more specific errors (including network/encoding
  # problems).
  class QueryError < MongrelDBError
  end

  # Response wraps one HTTP response from the daemon. It exposes the raw
  # status code and body and a +json+ helper for decoding a JSON body.
  Response = Struct.new(:status, :body, keyword_init: true) do
    # Parse the response body as JSON and return the decoded value (Hash,
    # Array, String, Integer, ...). Returns +nil+ for an empty body. Raises
    # {QueryError} if the body is not valid JSON.
    def json
      return nil if body.nil? || body.empty?

      JSON.parse(body)
    rescue JSON::ParserError => e
      raise QueryError, "Failed to decode JSON response: #{e.message}"
    end

    # True when the HTTP status is in the 2xx success range.
    def success?
      status && status >= 200 && status < 300
    end
  end

  # Client is the MongrelDB HTTP client. Create one with {Client.new} and a
  # base URL, then use its methods for health, table management, CRUD, query,
  # SQL, schema, and maintenance.
  #
  # A Client is safe for concurrent use by multiple threads once configured --
  # each request builds its own +Net::HTTP::Request+.
  class Client
    # The daemon base URL the client was configured with (no trailing slash).
    # @return [String]
    attr_reader :base_url

    # Create a new MongrelDB client.
    #
    # @param url [String] Daemon base URL (e.g. +http://127.0.0.1:8453+).
    #   Defaults to {DEFAULT_BASE_URL} when empty.
    # @param token [String, nil] Bearer token (+--auth-token+ mode). Takes
    #   precedence over basic-auth credentials when set.
    # @param username [String, nil] Username (+--auth-users+ mode).
    # @param password [String, nil] Password (+--auth-users+ mode).
    # @param open_timeout [Numeric] Seconds to wait for the connection to open.
    # @param read_timeout [Numeric] Seconds to wait for one block of the
    #   response body.
    def initialize(url: DEFAULT_BASE_URL, token: nil, username: nil, password: nil,
                   open_timeout: 30, read_timeout: 60)
      @base_url = (url.nil? || url.empty?) ? DEFAULT_BASE_URL : url.to_s
      @base_url = @base_url.sub(%r{/\z}, "")
      @token = token
      @username = username
      @password = password
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    # True when a bearer token or basic-auth username is configured.
    def auth?
      !@token.nil? || !@username.nil?
    end

    # ── Health & tables ──────────────────────────────────────────────────────

    # Check whether the daemon is reachable and healthy. Returns +true+ on a
    # successful +/health+ request, +false+ on any error.
    def health
      get("/health")
      true
    rescue MongrelDBError
      false
    end

    def history_retention_epochs
      get("/history/retention").json.fetch("history_retention_epochs")
    end

    def earliest_retained_epoch
      get("/history/retention").json.fetch("earliest_retained_epoch")
    end

    def set_history_retention_epochs(epochs)
      request(Net::HTTP::Put, "/history/retention", { "history_retention_epochs" => epochs }).json
    end

    # List all table names in the database.
    #
    # @return [Array<String>] Table names (empty array when none).
    def table_names
      data = get("/tables").json
      data.is_a?(Array) ? data : []
    end

    # Create a table with typed columns.
    #
    # @param name [String] Table name.
    # @param columns [Array<Hash>] Column definitions (keys +id+, +name+, +ty+,
    #   +primary_key+, +nullable+, ...).
    # @param constraints [Hash, nil] Optional table constraints.
    # @return [Integer] The assigned table id.
    def create_table(name, columns, constraints: nil)
      payload = { "name" => name, "columns" => columns }
      payload["constraints"] = constraints if constraints
      data = post("/kit/create_table", payload).json
      (data.is_a?(Hash) ? data["table_id"] : nil) || 0
    end

    # Drop a table by name.
    #
    # @param name [String] Table name.
    def drop_table(name)
      http_delete("/tables/#{url_path_escape(name)}")
      nil
    end

    # Get the row count for a table.
    #
    # @param table [String] Table name.
    # @return [Integer] Row count.
    def count(table)
      data = get("/tables/#{url_path_escape(table)}/count").json
      if data.is_a?(Hash) && data["count"].is_a?(Integer)
        data["count"]
      else
        raise MongrelDB::QueryError, "malformed count response from server"
      end
    end

    # ── CRUD (via the Kit typed transaction endpoint) ────────────────────────

    # Insert a row.
    #
    # @param table [String] Table name.
    # @param cells [Hash{Integer=>Object}] Column id -> value pairs
    #   (+{1 => 1, 2 => "Alice"}+). Flattened to the server's
    #   +[col_id, value, ...]+ array before sending.
    # @param idempotency_key [String, nil] When non-empty, makes the commit
    #   safe to retry -- the daemon returns the original result on duplicate
    #   commits.
    # @return [Hash{String=>Object}] The per-operation result object (the first
    #   element of the server's +results+ array). Empty hash when none.
    def put(table, cells, idempotency_key: nil)
      results = commit_one([{ "put" => { "table" => table, "cells" => flatten_cells(cells) } }],
                           idempotency_key)
      results.first || {}
    end

    # Upsert a row (insert or update on a primary-key conflict).
    #
    # @param table [String] Table name.
    # @param cells [Hash{Integer=>Object}] Column id -> value pairs (insert
    #   values).
    # @param update_cells [Hash{Integer=>Object}, nil] Values written on a
    #   primary-key conflict (+nil+ means DO NOTHING).
    # @param idempotency_key [String, nil] Idempotency key for safe retries.
    # @return [Hash{String=>Object}] The per-operation result object with an
    #   +action+ of +"inserted"+, +"updated"+, or +"unchanged"+.
    def upsert(table, cells, update_cells: nil, idempotency_key: nil)
      op = { "table" => table, "cells" => flatten_cells(cells) }
      op["update_cells"] = flatten_cells(update_cells) unless update_cells.nil?
      results = commit_one([{ "upsert" => op }], idempotency_key)
      results.first || {}
    end

    # Delete a row by its internal row id.
    #
    # @param table [String] Table name.
    # @param row_id [Integer] Internal row id.
    def delete(table, row_id)
      commit_one([{ "delete" => { "table" => table, "row_id" => row_id } }], nil)
      nil
    end

    # Delete a row by its primary-key value.
    #
    # @param table [String] Table name.
    # @param pk [Object] Primary-key value.
    def delete_by_pk(table, pk)
      commit_one([{ "delete_by_pk" => { "table" => table, "pk" => pk } }], nil)
      nil
    end

    # ── Query ────────────────────────────────────────────────────────────────

    # Start a fluent {QueryBuilder} against +table+.
    #
    # @param table [String] Table name.
    # @return [QueryBuilder]
    def query(table)
      QueryBuilder.new(self, table)
    end

    # ── SQL ──────────────────────────────────────────────────────────────────

    # Execute a SQL statement via the +/sql+ endpoint, requesting JSON output.
    # The server returns a JSON array of row objects keyed by column name, e.g.
    # +[{"id" => 1, "name" => "Alice", "score" => 95.5}]+. For statements that
    # yield no rows (DDL/DML), an empty array is returned.
    #
    # @param sql [String] SQL statement.
    # @return [Array<Hash{String=>Object}>] Result rows (empty when none).
    def sql(sql)
      response = post("/sql", "sql" => sql, "format" => "json")
      body = response.body.to_s
      trimmed = body.lstrip
      return [] if trimmed.empty?

      # Requested format is JSON; decode the array of row objects.
      parsed = JSON.parse(body)
      parsed.is_a?(Array) ? parsed : []
    rescue JSON::ParserError
      []
    end

    # ── Schema ───────────────────────────────────────────────────────────────

    # Get the full schema catalog.
    #
    # @return [Hash{String=>Hash{String=>Object}}] Table name -> descriptor.
    def schema
      data = get("/kit/schema").json
      (data.is_a?(Hash) ? data["tables"] : nil) || {}
    end

    # Get the descriptor for a single table.
    #
    # @param table [String] Table name.
    # @return [Hash{String=>Object}] Table descriptor.
    def schema_for(table)
      data = get("/kit/schema/#{url_path_escape(table)}").json
      (data.is_a?(Hash) ? data : nil) || {}
    end

    # ── Maintenance ──────────────────────────────────────────────────────────

    # Compact (merge sorted runs) across all tables.
    #
    # @return [Hash{String=>Object}] Compaction summary (e.g. +compacted+,
    #   +skipped+ counts).
    def compact
      post_decode("/compact")
    end

    # Compact a single table.
    #
    # @param name [String] Table name.
    # @return [Hash{String=>Object}] Compaction result.
    def compact_table(name)
      post_decode("/tables/#{url_path_escape(name)}/compact")
    end

    # ── Transactions ─────────────────────────────────────────────────────────

    # Begin a batch transaction. Operations are staged locally and committed
    # atomically in a single +/kit/txn+ request.
    #
    # @return [Transaction]
    def begin_transaction
      Transaction.new(self)
    end

    # Commit a batch of staged operations atomically. Exposed for the
    # {Transaction} type; prefer {Transaction#commit}.
    #
    # @param ops [Array<Hash{String=>Hash}>] Staged operations.
    # @param idempotency_key [String, nil] Optional idempotency key.
    # @return [Array<Hash{String=>Object}>] Per-operation results.
    def commit_txn(ops, idempotency_key = nil)
      return [] if ops.empty?

      payload = { "ops" => ops }
      payload["idempotency_key"] = idempotency_key unless idempotency_key.nil? || idempotency_key.empty?
      decode_results(post("/kit/txn", payload).body)
    end

    # ── Low-level HTTP ───────────────────────────────────────────────────────
    #
    # These are public so that {Transaction} and {QueryBuilder} can share the
    # transport, and so callers can reach endpoints the convenience methods do
    # not yet cover.

    # Perform a GET request and return the {Response}, mapping HTTP errors to
    # typed exceptions.
    def get(path)
      request(Net::HTTP::Get, path)
    end

    # Perform a POST request with a JSON body (Content-Type: application/json)
    # and return the {Response}. A +nil+ body sends an empty request.
    def post(path, body = nil)
      request(Net::HTTP::Post, path, body)
    end

    # Perform a DELETE request and return the {Response}.
    # (Renamed from +delete+ to avoid clobbering the typed CRUD method
    # Client#delete(table, row_id) defined above.)
    def http_delete(path)
      request(Net::HTTP::Delete, path)
    end

    # ── Shared helpers ───────────────────────────────────────────────────────
    #
    # Public so {Transaction} and {QueryBuilder} can flatten cells and decode
    # transaction results without duplicating logic.

    # Convert a column-id-to-value map to the server's flat
    # +[col_id, value, col_id, value, ...]+ array. Pair order is not
    # significant -- each value is preceded by its own column id.
    def self.flatten_cells(cells)
      flat = []
      cells.each do |col_id, value|
        flat << col_id
        flat << value
      end
      flat
    end

    private

    # Build and run one request. The server's JSON extractors require an
    # explicit Content-Type header on any request carrying a JSON body, so one
    # is added whenever the body is non-nil. Non-2xx responses are mapped to
    # typed exceptions via {throw_for_status}.
    def request(req_class, path, body = nil)
      uri = uri_for(path)
      req = req_class.new(uri)
      req["Accept"] = "application/json"

      unless body.nil?
        req.body = encode_json(body)
        req["Content-Type"] = "application/json"
      end

      apply_auth(req)

      response = perform(uri, req)
      resp = Response.new(status: response.code.to_i, body: response.body)
      if resp.body && resp.body.bytesize > MAX_RESPONSE_BYTES
        raise QueryError,
              "Response body exceeds maximum size of #{MAX_RESPONSE_BYTES} bytes"
      end
      return resp if resp.success?

      throw_for_status(resp.status, resp.body)
    rescue MongrelDBError
      raise
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
           Errno::ETIMEDOUT, IOError, SocketError, Net::OpenTimeout,
           Net::ReadTimeout => e
      raise QueryError, "request #{path} failed: #{e.message}"
    end

    # Open the HTTP connection (using the standard Net::HTTP defaults) and send
    # the request. Extracted so timeouts are applied consistently.
    def perform(uri, req)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout
      http.request(req)
    end

    # Build the full URI for a path.
    def uri_for(path)
      URI.join("#{@base_url}/", path.to_s.sub(%r{\A/}, ""))
    end

    # Set the Authorization header according to the configured credentials. A
    # bearer token takes precedence over basic auth.
    def apply_auth(req)
      if @token
        req["Authorization"] = "Bearer #{@token}"
      elsif @username
        creds = "#{@username}:#{@password || ''}"
        req["Authorization"] = "Basic #{[creds].pack('m0')}"
      end
    end

    # JSON-encode a request body. Raises {QueryError} for values with no JSON
    # representation (NaN, Infinity, recursive structures).
    def encode_json(data)
      JSON.generate(data)
    rescue JSON::GeneratorError => e
      raise QueryError,
            "Request payload cannot be JSON-encoded: #{e.message}. " \
            "(NaN, Infinity, and recursive structures have no JSON representation.)"
    end

    # Send a single-op transaction and return the results array.
    def commit_one(ops, idempotency_key)
      commit_txn(ops, idempotency_key)
    end

    # POST with no body and decode the JSON object response.
    def post_decode(path)
      data = post(path).json
      (data.is_a?(Hash) ? data : nil) || {}
    end

    # Flatten cells via the shared class helper.
    def flatten_cells(cells)
      Client.flatten_cells(cells)
    end

    # Decode the results array out of a +/kit/txn+ response.
    def decode_results(body)
      return [] if body.nil? || body.lstrip.empty?

      data = JSON.parse(body)
      results = data.is_a?(Hash) ? data["results"] : nil
      results.is_a?(Array) ? results : []
    rescue JSON::ParserError => e
      raise QueryError, "Failed to decode transaction response: #{e.message}"
    end

    # Map the HTTP status code and body to the appropriate typed exception.
    def throw_for_status(status, body)
      message, error_code, op_index = decode_error_envelope(body)

      raise NotFoundError, message if message&.match?(/\Anot found:/i)

      case status
      when 401, 403
        raise AuthError, message_for(message, "Authentication failed (#{status})")
      when 404
        raise NotFoundError, message_for(message, "Resource not found")
      when 409
        raise ConflictError.new(
          message_for(message, "Constraint violation"),
          error_code: error_code.to_s,
          op_index: op_index
        )
      else
        raise QueryError, message_for(message, "Server error (#{status})")
      end
    end

    def message_for(decoded, fallback)
      decoded.nil? || decoded.empty? ? fallback : decoded
    end

    # Decode the server's JSON error envelope ({error: {message, code,
    # op_index}}) or a flat {message, code} object. Returns [message, code,
    # op_index]; message falls back to the raw body when it is non-JSON.
    def decode_error_envelope(body)
      return [nil, nil, nil] if body.nil? || body.empty?

      trimmed = body.lstrip
      unless trimmed.start_with?("{")
        return [body, nil, nil]
      end

      data = JSON.parse(body)
      return [body, nil, nil] unless data.is_a?(Hash)

      if data["error"].is_a?(Hash)
        err = data["error"]
        return [err["message"], err["code"], err["op_index"]]
      end

      [data["message"], data["code"], nil]
    rescue JSON::ParserError
      [body, nil, nil]
    end

    # Percent-escape a path segment so table names containing '/', '?', '#',
    # or spaces cannot inject extra segments or break routing. Only RFC 3986
    # unreserved characters pass through unescaped.
    def url_path_escape(segment)
      segment.to_s.gsub(/[^A-Za-z0-9\-_.~]/) do |match|
        match.bytes.map { |b| format("%%%02X", b) }.join
      end
    end
  end
end
