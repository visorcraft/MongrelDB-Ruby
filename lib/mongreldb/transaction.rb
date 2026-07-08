# frozen_string_literal: true

module MongrelDB
  # Transaction stages operations locally and commits them atomically in a
  # single +/kit/txn+ request. The engine enforces unique, foreign-key, check,
  # and trigger constraints at commit time; on any violation all operations
  # roll back and {#commit} raises a {ConflictError}.
  #
  # A Transaction is single-use -- call {#commit} or {#rollback} once, then
  # create a new one with {Client#begin_transaction}.
  #
  # Example:
  #
  #   txn = db.begin_transaction
  #   txn.put("orders", 1 => 1, 2 => "Alice")
  #   txn.put("orders", 1 => 2, 2 => "Bob")
  #   txn.delete_by_pk("orders", 99)
  #   results = txn.commit # atomic - all or nothing
  class Transaction
    # Initialize a new Transaction. Normally created via {Client#begin_transaction}.
    #
    # @param client [Client] The HTTP client.
    def initialize(client)
      @client = client
      @ops = []
      @committed = false
    end

    # Stage a put (insert) operation.
    #
    # @param table [String] Table name.
    # @param cells [Hash{Integer=>Object}] Column id -> value pairs
    #   (+{1 => 1, 2 => "Alice"}+).
    # @param returning [Boolean] Whether to return the row in the result.
    # @return [self] self, for chaining.
    def put(table, cells, returning: false)
      @ops << {
        "put" => {
          "table" => table,
          "cells" => Client.flatten_cells(cells),
          "returning" => returning
        }
      }
      self
    end

    # Stage an upsert (insert-or-update) operation.
    #
    # @param table [String] Table name.
    # @param cells [Hash{Integer=>Object}] Column id -> value pairs (insert
    #   values).
    # @param update_cells [Hash{Integer=>Object}, nil] Update values on a
    #   primary-key conflict (+nil+ means DO NOTHING).
    # @param returning [Boolean] Whether to return the row.
    # @return [self] self, for chaining.
    def upsert(table, cells, update_cells: nil, returning: false)
      op = {
        "table" => table,
        "cells" => Client.flatten_cells(cells),
        "returning" => returning
      }
      op["update_cells"] = Client.flatten_cells(update_cells) unless update_cells.nil?
      @ops << { "upsert" => op }
      self
    end

    # Stage a delete by the internal row id.
    #
    # @param table [String] Table name.
    # @param row_id [Integer] Internal row id.
    # @return [self] self, for chaining.
    def delete(table, row_id)
      @ops << {
        "delete" => {
          "table" => table,
          "row_id" => row_id
        }
      }
      self
    end

    # Stage a delete by primary-key value.
    #
    # @param table [String] Table name.
    # @param pk [Object] Primary-key value.
    # @return [self] self, for chaining.
    def delete_by_pk(table, pk)
      @ops << {
        "delete_by_pk" => {
          "table" => table,
          "pk" => pk
        }
      }
      self
    end

    # The number of staged operations.
    #
    # @return [Integer]
    def count
      @ops.length
    end

    # Commit all staged operations atomically.
    #
    # @param idempotency_key [String, nil] Optional idempotency key for safe
    #   retries -- the daemon returns the original response on duplicate
    #   commits, even after a crash.
    # @return [Array<Hash{String=>Object}>] Per-operation results.
    # @raise [ConflictError] On a constraint violation (all ops rolled back).
    # @raise [MongrelDBError] On other errors.
    # @raise [RuntimeError] If called twice on the same transaction.
    def commit(idempotency_key: nil)
      raise "transaction already committed" if @committed

      @committed = true
      return [] if @ops.empty?

      @client.commit_txn(@ops, idempotency_key)
    end

    # Rollback (discard all staged operations).
    #
    # @return [void]
    # @raise [RuntimeError] If the transaction was already committed.
    def rollback
      raise "cannot rollback a committed transaction" if @committed

      @ops = []
      nil
    end
  end
end
