# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "../lib/mongreldb"

class DurableRetrieveSpec < Minitest::Test
  FIXTURE = {
    "query_id" => "abcdefabcdefabcdefabcdefabcdefab",
    "status" => "committed",
    "state" => "completed",
    "server_state" => "completed",
    "terminal_state" => "committed",
    "committed" => true,
    "last_commit_epoch" => 17,
    "last_commit_epoch_text" => "17",
    "last_commit_hlc" => {
      "physical_micros" => 1_700_000_000_000_000,
      "logical" => 3,
      "node_tiebreaker" => 7
    },
    "outcome" => {
      "committed" => true,
      "committed_statements" => 1,
      "last_commit_epoch" => 17,
      "last_commit_epoch_text" => "17",
      "last_commit_hlc" => {
        "physical_micros" => 1_700_000_000_000_000,
        "logical" => 3,
        "node_tiebreaker" => 7
      },
      "first_commit_statement_index" => 0,
      "last_commit_statement_index" => 0,
      "completed_statements" => 1,
      "statement_index" => 0,
      "serialization" => "succeeded",
      "serialization_state" => "succeeded"
    },
    "durable" => {
      "committed" => true,
      "committed_statements" => 1,
      "last_commit_epoch" => 17,
      "last_commit_epoch_text" => "17",
      "last_commit_hlc" => {
        "physical_micros" => 1_700_000_000_000_000,
        "logical" => 3,
        "node_tiebreaker" => 7
      },
      "first_commit_statement_index" => 0,
      "last_commit_statement_index" => 0,
      "completed_statements" => 1,
      "statement_index" => 0,
      "serialization" => "succeeded",
      "serialization_state" => "succeeded"
    }
  }.freeze

  def test_query_status_parses_structural_hlc
    status = MongrelDB::QueryStatus.new(FIXTURE)
    assert_equal true, status.committed
    hlc = status.commit_hlc
    refute_nil hlc
    assert_equal 1_700_000_000_000_000, hlc.physical_micros
    assert_equal 3, hlc.logical
    assert_equal 7, hlc.node_tiebreaker
    assert_equal "succeeded", status.serialization_state
    assert_equal 17, status.outcome.last_commit_epoch
  end

  def test_multi_retriever_search_build_has_two_retrievers
    client = MongrelDB::Client.new(url: "http://127.0.0.1:9")
    builder = client.search("docs")
      .ann_retriever("ann", 3, [0.1, 0.2], k: 10, weight: 1.0)
      .sparse_retriever("sparse", 4, [[1, 0.5]], k: 10, weight: 0.5)
      .fusion(60)
      .limit(5)
    payload = builder.build
    assert_equal 2, payload["retrievers"].length
    assert payload.key?("fusion")
  end
end
