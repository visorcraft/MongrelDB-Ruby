# frozen_string_literal: true

module MongrelDB
  # QueryBuilder builds a request for the daemon's +/kit/query+ endpoint, where
  # conditions push down to the engine's specialized indexes for sub-millisecond
  # lookups.
  #
  # Condition parameters accept friendly aliases that are translated to the
  # server's exact on-wire keys before sending (see {#where}):
  #
  #   - column        -> column_id
  #   - min / max     -> lo / hi
  #   - min_inclusive -> lo_inclusive
  #   - max_inclusive -> hi_inclusive
  #
  # The server's canonical keys are accepted directly too.
  #
  # Example:
  #
  #   rows = db.query("orders")
  #     .where("bitmap_eq", "column" => 2, "value" => "electronics")
  #     .where("range", "column" => 3, "min" => 100.0)
  #     .projection([1, 2, 3])
  #     .limit(50)
  #     .execute
  #
  #   if db.query("orders").truncated
  #     # result set hit the limit; more matches exist on the server
  #   end
  class QueryBuilder
    # Initialize a new QueryBuilder. Normally created via {Client#query}.
    #
    # @param client [Client] The HTTP client.
    # @param table [String] Table name.
    def initialize(client, table)
      @client = client
      @table = table
      @conditions = [] # each entry is {type => {normalized params}}
      @projection = nil
      @limit = nil
      @last_truncated = false
    end

    # Add a native condition (AND-ed). Available condition types include:
    #
    #   - pk               exact primary-key match ({"value" => pk})
    #   - bitmap_eq        equality on a bitmap-indexed column
    #   - bitmap_in        IN predicate on a bitmap-indexed column
    #   - range            integer range predicate (lo/hi, inclusive)
    #   - range_f64        float range predicate (lo/hi + lo_inclusive/hi_inclusive)
    #   - is_null          null check
    #   - is_not_null      non-null check
    #   - fm_contains      full-text substring search (FM-index)
    #   - fm_contains_all  multiple substring patterns (all must match)
    #   - ann              dense vector similarity search (HNSW)
    #   - sparse_match     sparse vector match
    #   - min_hash_similar MinHash similarity search
    #
    # Friendly aliases (+column+ -> +column_id+, +min+/+max+ -> +lo+/+hi+) are
    # accepted; the server's canonical keys are also accepted as-is.
    #
    # @param type [String] Condition type.
    # @param params [Hash{Symbol,String=>Object}] Condition parameters.
    # @return [self] self, for chaining.
    def where(type, params)
      @conditions << { type => self.class.normalize_condition(type, params) }
      self
    end

    # Set the column projection (column ids to return). +nil+ means all columns.
    #
    # @param column_ids [Array<Integer>, nil] Column ids to project.
    # @return [self] self, for chaining.
    def projection(column_ids)
      @projection = column_ids
      self
    end

    # Cap the number of rows returned.
    #
    # @param limit [Integer, nil] Maximum number of rows.
    # @return [self] self, for chaining.
    def limit(limit)
      @limit = limit
      self
    end

    # Build the request payload that will be sent to +/kit/query+.
    #
    # @return [Hash{String=>Object}] The request payload.
    def build
      payload = { "table" => @table }
      # The daemon expects externally-tagged conditions: [{type: {...}}, ...]
      payload["conditions"] = @conditions unless @conditions.empty?
      payload["projection"] = @projection unless @projection.nil?
      payload["limit"] = @limit unless @limit.nil?
      payload
    end

    # Run the query and return the matching rows. Also records whether the
    # result was truncated by the limit; check it with {#truncated}.
    #
    # @return [Array<Hash{String=>Object}>] Matching rows.
    def execute
      data = @client.post("/kit/query", build).json
      data = data.is_a?(Hash) ? data : {}

      @last_truncated = data["truncated"] ? true : false
      rows = data["rows"]
      rows.is_a?(Array) ? rows : []
    end

    # Whether the most recent {#execute} result was capped by the limit.
    # Returns +false+ until {#execute} has been called.
    #
    # @return [Boolean]
    def truncated
      @last_truncated
    end

    # ── Internal helpers ─────────────────────────────────────────────────────

    # Translate friendly parameter aliases to the server's canonical on-wire
    # keys. Both spellings are accepted, so callers may use whichever is clearer.
    #
    # Generic aliases (applied to all condition types):
    #
    #   column         -> column_id
    #   min            -> lo
    #   max            -> hi
    #   min_inclusive  -> lo_inclusive
    #   max_inclusive  -> hi_inclusive
    #
    # Type-specific aliases:
    #
    #   fm_contains:      value -> pattern
    #   fm_contains_all:  value -> patterns
    #   (other types like pk/bitmap_eq use "value" as their canonical key, so
    #   the value->pattern alias must NOT apply globally)
    #
    # @param type [String] Condition type.
    # @param params [Hash{Symbol,String=>Object}] Condition parameters.
    # @return [Hash{String=>Object}] Normalized parameters with string keys.
    def self.normalize_condition(type, params)
      aliases = {
        "column"        => "column_id",
        "min"           => "lo",
        "max"           => "hi",
        "min_inclusive" => "lo_inclusive",
        "max_inclusive" => "hi_inclusive"
      }

      # The docs historically used "value" for the FTS pattern. The server's
      # fm_contains key is "pattern" (singular), while fm_contains_all expects
      # "patterns" (array). Only apply this for FTS conditions, since
      # pk/bitmap_eq use "value" canonically.
      if type == "fm_contains"
        aliases["value"] = "pattern"
      elsif type == "fm_contains_all"
        aliases["value"] = "patterns"
      end

      normalized = {}
      params.each do |key, value|
        canon = aliases[key.to_s] || key.to_s
        normalized[canon] = value
      end
      normalized
    end
  end
end
