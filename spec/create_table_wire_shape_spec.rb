# frozen_string_literal: true

# Offline wire-shape conformance spec for Client#create_table.
#
# These specs do NOT touch the network. They build a Client subclass whose
# transport is stubbed to capture the outgoing request body and return a canned
# 200 response, then assert that the `enum_variants` and `default_value` column
# keys survive the JSON round-trip verbatim. This guards against silent key
# renames or omissions that would break the wire contract with the daemon (the
# engine reads both keys directly out of the column hash).
#
# Transport stubbing is stdlib only: it does not require WebMock or any other
# third-party gem. The base URL points at an unreachable address so even an
# accidental real call would fail loudly rather than succeed silently.
#
# Run with:
#   ruby -Ilib spec/create_table_wire_shape_spec.rb

require "minitest/autorun"
require "minitest/spec"
require "json"

require_relative "../lib/mongreldb"

module MongrelDB
  module CreateTableWireShape
    # Test-only Client whose private `perform` returns a canned 200 response and
    # captures the request body, path, and Content-Type. The real Net::HTTP
    # transport is never touched.
    class CapturingClient < MongrelDB::Client
      attr_reader :captured_body, :captured_path, :captured_content_type

      def initialize
        super(url: "http://127.0.0.1:1") # never actually contacted
        @captured_body = nil
        @captured_path = nil
        @captured_content_type = nil
      end

      private

      def perform(uri, req)
        @captured_path = uri.request_uri
        @captured_content_type = req["Content-Type"]
        @captured_body = req.body
        Struct.new(:code, :body).new("200", %({"table_id": 7}))
      end
    end
  end
end

describe MongrelDB::Client, "create_table wire shape" do
  let(:client) { MongrelDB::CreateTableWireShape::CapturingClient.new }

  it "POSTs to /kit/create_table with application/json" do
    client.create_table("wire_test", [
      { "id" => 1, "name" => "id", "ty" => "int64", "primary_key" => true, "nullable" => false },
    ])

    assert_equal "/kit/create_table", client.captured_path
    assert_equal "application/json", client.captured_content_type
    refute_nil client.captured_body
  end

  it "passes column options and table checks through verbatim" do
    client.create_table("orders", [
      { "id" => 1, "name" => "id",     "ty" => "int64", "primary_key" => true, "nullable" => false },
      { "id" => 2, "name" => "status", "ty" => "enum",
        "enum_variants" => ["draft", "active", "archived"],
        "default_value" => "draft",
        "nullable" => false },
      { "id" => 3, "name" => "retries", "ty" => "int64", "default_value" => 7 },
      { "id" => 4, "name" => "created_at", "ty" => "timestamp", "default_expr" => "now" },
      { "id" => 5, "name" => "enabled", "ty" => "bool", "default_value" => true },
      { "id" => 6, "name" => "optional", "ty" => "varchar", "default_value" => nil },
      { "id" => 7, "name" => "now_literal", "ty" => "varchar", "default_value" => "now" },
      { "id" => 8, "name" => "uuid_literal", "ty" => "varchar", "default_value" => "uuid" },
    ], constraints: {
      "checks" => [{
        "id" => 1,
        "name" => "ck_status",
        "expr" => { "IsNotNull" => 2 },
      }],
    })

    payload = JSON.parse(client.captured_body)
    status_col = payload["columns"].find { |c| c["name"] == "status" }

    # Keys must appear with the exact names the engine reads on the wire.
    assert status_col.key?("enum_variants"),
           "expected enum_variants key on status column"
    assert status_col.key?("default_value"),
           "expected default_value key on status column"

    # Values must survive serialization unchanged: array, not joined string;
    # string, not coerced to a number or symbol.
    assert_equal ["draft", "active", "archived"], status_col["enum_variants"]
    assert_equal "draft", status_col["default_value"]
    assert_equal 7, payload["columns"].find { |c| c["name"] == "retries" }["default_value"]
    assert_equal "now", payload["columns"].find { |c| c["name"] == "created_at" }["default_expr"]
    refute payload["columns"].find { |c| c["name"] == "created_at" }.key?("default_value")
    assert_equal true, payload["columns"].find { |c| c["name"] == "enabled" }["default_value"]
    assert_nil payload["columns"].find { |c| c["name"] == "optional" }["default_value"]
    assert_equal "now", payload["columns"].find { |c| c["name"] == "now_literal" }["default_value"]
    assert_equal "uuid", payload["columns"].find { |c| c["name"] == "uuid_literal" }["default_value"]
    assert_equal "ck_status", payload.dig("constraints", "checks", 0, "name")
    assert_equal({ "IsNotNull" => 2 }, payload.dig("constraints", "checks", 0, "expr"))
  end

  it "omits enum_variants and default_value when not provided" do
    client.create_table("orders", [
      { "id" => 1, "name" => "id",   "ty" => "int64",   "primary_key" => true,  "nullable" => false },
      { "id" => 2, "name" => "name", "ty" => "varchar", "primary_key" => false, "nullable" => false },
    ])

    payload = JSON.parse(client.captured_body)
    name_col = payload["columns"].find { |c| c["name"] == "name" }

    # Regression: a column that doesn't set these keys must not serialize them
    # (no accidental `null` literals that the engine would later reject).
    refute name_col.key?("enum_variants"),
           "enum_variants must be absent when not set"
    refute name_col.key?("default_value"),
           "default_value must be absent when not set"
  end

  it "passes all indexes and embedding source through verbatim" do
    client.create_table("search_docs", [
      { "id" => 1, "name" => "id", "ty" => "int64", "primary_key" => true },
      { "id" => 2, "name" => "embedding", "ty" => "embedding(384)",
        "embedding_source" => { "kind" => "configured_model", "provider_id" => "docs",
                                "model_id" => "model", "model_version" => "1" } },
    ], indexes: [
      { "name" => "bm", "column_id" => 1, "kind" => "bitmap" },
      { "name" => "fm", "column_id" => 1, "kind" => "fm_index" },
      { "name" => "ann", "column_id" => 2, "kind" => "ann",
        "predicate" => "embedding IS NOT NULL",
        "options" => { "ann" => { "m" => 24, "ef_construction" => 96,
                                    "ef_search" => 48, "quantization" => "dense" } } },
      { "name" => "range", "column_id" => 1, "kind" => "learned_range" },
      { "name" => "minhash", "column_id" => 1, "kind" => "minhash" },
      { "name" => "sparse", "column_id" => 1, "kind" => "sparse" },
    ])

    payload = JSON.parse(client.captured_body)
    assert_equal "configured_model", payload.dig("columns", 1, "embedding_source", "kind")
    assert_equal %w[bitmap fm_index ann learned_range minhash sparse],
                 payload["indexes"].map { |index| index["kind"] }
    assert_equal "dense", payload.dig("indexes", 2, "options", "ann", "quantization")
    assert_equal "embedding IS NOT NULL", payload.dig("indexes", 2, "predicate")
  end
end
