# frozen_string_literal: true

# Offline wire-shape conformance spec for the history-retention API.
#
# These specs do NOT touch the network. They build a Client subclass whose
# transport is stubbed to capture the outgoing request and return a canned
# response, then assert the exact frozen GET/PUT contract:
#
#   GET /history/retention
#     -> {"history_retention_epochs": <u64>, "earliest_retained_epoch": <u64>}
#   PUT /history/retention
#     -> {"history_retention_epochs": <u64>}
#     <- {"history_retention_epochs": <u64>, "earliest_retained_epoch": <u64>}
#
# Run with:
#   ruby -Ilib spec/history_retention_wire_spec.rb

require "minitest/autorun"
require "minitest/spec"
require "json"

require_relative "../lib/mongreldb"

module MongrelDB
  module HistoryRetentionWireShape
    # Test-only Client whose private `perform` returns a canned response and
    # captures the request body, path, method, and Content-Type.
    class CapturingClient < MongrelDB::Client
      attr_reader :captured_method, :captured_path, :captured_body, :captured_content_type

      def initialize
        super(url: "http://127.0.0.1:1") # never actually contacted
        @captured_method = nil
        @captured_path = nil
        @captured_body = nil
        @captured_content_type = nil
      end

      private

      def perform(uri, req)
        @captured_method = req.method
        @captured_path = uri.request_uri
        @captured_content_type = req["Content-Type"]
        @captured_body = req.body
        Struct.new(:code, :body).new("200", '{"history_retention_epochs":100,"earliest_retained_epoch":7}')
      end
    end

    # Client that returns a non-2xx response so we can verify error mapping.
    class FailingClient < MongrelDB::Client
      def initialize(status:, body:)
        super(url: "http://127.0.0.1:1")
        @status = status
        @body = body
      end

      private

      def perform(_uri, _req)
        Struct.new(:code, :body).new(@status.to_s, @body)
      end
    end
  end
end

describe MongrelDB::Client, "history retention wire shape" do
  let(:client) { MongrelDB::HistoryRetentionWireShape::CapturingClient.new }

  it "GETs /history/retention and returns history_retention_epochs" do
    assert_equal 100, client.history_retention_epochs
    assert_equal "GET", client.captured_method
    assert_equal "/history/retention", client.captured_path
  end

  it "GETs /history/retention and returns earliest_retained_epoch" do
    assert_equal 7, client.earliest_retained_epoch
    assert_equal "GET", client.captured_method
    assert_equal "/history/retention", client.captured_path
  end

  it "PUTs exactly history_retention_epochs to /history/retention" do
    resp = client.set_history_retention_epochs(200)

    assert_equal "PUT", client.captured_method
    assert_equal "/history/retention", client.captured_path
    assert_equal "application/json", client.captured_content_type

    body = JSON.parse(client.captured_body)
    assert_equal 200, body["history_retention_epochs"]
    refute body.key?("earliest_retained_epoch")

    assert_equal 100, resp["history_retention_epochs"]
    assert_equal 7, resp["earliest_retained_epoch"]
  end

  it "rejects negative or non-integer epochs before sending a request" do
    assert_raises(MongrelDB::QueryError) { client.set_history_retention_epochs(-1) }
    assert_raises(MongrelDB::QueryError) { client.set_history_retention_epochs("100") }
  end

  it "propagates a non-2xx response as a typed error" do
    bad = MongrelDB::HistoryRetentionWireShape::FailingClient.new(
      status: 400,
      body: '{"error":{"message":"history_retention_epochs must be a u64"}}'
    )
    assert_raises(MongrelDB::QueryError) { bad.set_history_retention_epochs(1) }
  end
end
