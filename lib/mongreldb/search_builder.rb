# frozen_string_literal: true

module MongrelDB
  # SearchBuilder builds a request for the daemon's +/kit/search+ endpoint:
  # multi-retriever hybrid search with reciprocal-rank fusion and optional
  # exact-vector rerank. Wire format matches KitSearchRequest (flattened
  # retrievers).
  class SearchBuilder
    def initialize(client, table)
      @client = client
      @table = table
      @must = []
      @retrievers = []
      @fusion = { "reciprocal_rank" => { "constant" => 60 } }
      @rerank = nil
      @limit = 10
      @projection = nil
      @explain = false
      @cursor = nil
    end

    # Hard filter (same condition shapes as {QueryBuilder#where}).
    def must(type, params = {})
      @must << { type => QueryBuilder.normalize_condition(type, params) }
      self
    end

    def ann_retriever(name, column_id, query, k: 64, weight: 1.0)
      @retrievers << {
        "name" => name,
        "weight" => weight,
        "ann" => {
          "column_id" => column_id,
          "query" => query.map(&:to_f),
          "k" => k
        }
      }
      self
    end

    # +terms+ is an Array of +[token_id, weight]+ pairs.
    def sparse_retriever(name, column_id, terms, k: 64, weight: 1.0)
      pairs = terms.map { |t, w| [t.to_i, w.to_f] }
      @retrievers << {
        "name" => name,
        "weight" => weight,
        "sparse" => {
          "column_id" => column_id,
          "query" => pairs,
          "k" => k
        }
      }
      self
    end

    def min_hash_retriever(name, column_id, members, k: 64, weight: 1.0)
      @retrievers << {
        "name" => name,
        "weight" => weight,
        "min_hash" => {
          "column_id" => column_id,
          "members" => members,
          "k" => k
        }
      }
      self
    end

    def fusion(constant = 60)
      @fusion = { "reciprocal_rank" => { "constant" => [constant.to_i, 1].max } }
      self
    end

    # +metric+ is +"cosine"+, +"dot_product"+, or +"euclidean"+.
    def exact_rerank(embedding_column, query, metric: "cosine", candidate_limit: 64, weight: 1.0)
      @rerank = {
        "exact_vector" => {
          "embedding_column" => embedding_column,
          "query" => query.map(&:to_f),
          "metric" => metric,
          "candidate_limit" => candidate_limit,
          "weight" => weight
        }
      }
      self
    end

    def limit(limit)
      @limit = limit
      self
    end

    def projection(column_ids)
      @projection = column_ids
      self
    end

    def explain(on = true)
      @explain = on
      self
    end

    def cursor(cursor)
      @cursor = cursor
      self
    end

    def build
      raise ArgumentError, "search requires at least one retriever" if @retrievers.empty?
      raise ArgumentError, "search limit must be positive" if @limit.nil? || @limit <= 0

      payload = {
        "table" => @table,
        "retrievers" => @retrievers,
        "fusion" => @fusion,
        "limit" => @limit
      }
      payload["must"] = @must unless @must.empty?
      payload["rerank"] = @rerank unless @rerank.nil?
      payload["projection"] = @projection unless @projection.nil?
      payload["explain"] = true if @explain
      payload["cursor"] = @cursor if @cursor && !@cursor.empty?
      payload
    end

    # @return [Hash] response with +"hits"+, optional +"next_cursor"+ / +"trace"+
    def execute
      data = @client.post("/kit/search", build).json
      data.is_a?(Hash) ? data : { "hits" => [] }
    end
  end
end
