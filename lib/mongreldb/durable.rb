# frozen_string_literal: true

module MongrelDB
  # Structural HLC from durable recovery (0.64+).
  # Struct (not Data.define) so the client stays loadable on Ruby 3.0, the
  # supported minimum in the gemspec and CI matrix.
  CommitHlc = Struct.new(:physical_micros, :logical, :node_tiebreaker, keyword_init: true) do
    def self.from_hash(raw)
      return nil if raw.nil? || !raw.is_a?(Hash) || raw["physical_micros"].nil?

      new(
        physical_micros: Integer(raw["physical_micros"]),
        logical: Integer(raw.fetch("logical", 0)),
        node_tiebreaker: Integer(raw.fetch("node_tiebreaker", 0))
      )
    end
  end

  # Nested durable recovery payload (server outcome / durable JSON).
  DurableOutcome = Struct.new(
    :committed,
    :committed_statements,
    :last_commit_epoch,
    :last_commit_epoch_text,
    :last_commit_hlc,
    :first_commit_statement_index,
    :last_commit_statement_index,
    :completed_statements,
    :statement_index,
    :serialization,
    :serialization_state,
    :terminal_state,
    keyword_init: true
  ) do
    def self.from_hash(raw)
      raw = {} unless raw.is_a?(Hash)
      hlc = CommitHlc.from_hash(raw["last_commit_hlc"])
      new(
        committed: raw.key?("committed") ? raw["committed"] : nil,
        committed_statements: raw["committed_statements"],
        last_commit_epoch: raw["last_commit_epoch"],
        last_commit_epoch_text: raw["last_commit_epoch_text"],
        last_commit_hlc: hlc,
        first_commit_statement_index: raw["first_commit_statement_index"],
        last_commit_statement_index: raw["last_commit_statement_index"],
        completed_statements: raw["completed_statements"],
        statement_index: raw["statement_index"],
        serialization: raw["serialization"].to_s,
        serialization_state: raw["serialization_state"],
        terminal_state: raw["terminal_state"]
      )
    end
  end

  # GET /queries/{query_id} decoded status.
  class QueryStatus
    attr_reader :query_id, :status, :state, :server_state, :terminal_state,
                :committed, :outcome, :durable, :last_commit_hlc, :raw

    def initialize(raw)
      @raw = raw.is_a?(Hash) ? raw : {}
      @query_id = @raw["query_id"].to_s
      @status = @raw["status"].to_s
      @state = @raw["state"].to_s
      @server_state = (@raw["server_state"] || @raw["state"]).to_s
      @terminal_state = @raw["terminal_state"]
      @committed = @raw.key?("committed") ? @raw["committed"] : nil
      @outcome = DurableOutcome.from_hash(@raw["outcome"])
      @durable = @raw["durable"].is_a?(Hash) ? DurableOutcome.from_hash(@raw["durable"]) : nil
      @last_commit_hlc = CommitHlc.from_hash(@raw["last_commit_hlc"])
    end

    def commit_hlc
      durable&.last_commit_hlc || outcome.last_commit_hlc || last_commit_hlc
    end

    def serialization_state
      durable&.serialization_state ||
        outcome.serialization_state ||
        durable&.serialization ||
        outcome.serialization ||
        ""
    end
  end
end
