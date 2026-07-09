#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Example: query builder conditions with the MongrelDB Ruby client.
#
# Run: ruby -Ilib examples/query_builder.rb
# Requires: mongreldb-server running on http://127.0.0.1:8453
#
# Creates a table, inserts five rows with varying scores, then uses the native
# query builder to fetch rows by a range condition and by an exact primary-key
# match. Cleans up by dropping the table.

require "mongreldb"
require "securerandom"

URL = "http://127.0.0.1:8453"
# Unique suffix per run so repeated/concurrent runs don't collide.
TABLE = "example_query_#{Time.now.to_i}_#{SecureRandom.hex(4)}"

db = MongrelDB::Client.new(url: URL)

unless db.health
  warn "daemon not reachable at #{URL}"
  exit 1
end
puts "Connected to MongrelDB"

begin
  db.create_table(TABLE, [
    { "id" => 1, "name" => "id", "ty" => "int64", "primary_key" => true, "nullable" => false },
    { "id" => 2, "name" => "name", "ty" => "varchar", "primary_key" => false, "nullable" => false },
    { "id" => 3, "name" => "score", "ty" => "float64", "primary_key" => false, "nullable" => false },
  ])
  puts "Created table #{TABLE}"

  # Five rows with varying scores. Wrap the cells in braces: Client#put takes
  # keyword args (idempotency_key:), and Ruby 3 treats a trailing braceless hash
  # ambiguously with keyword args.
  db.put(TABLE, { 1 => 1, 2 => "Alice", 3 => 40.0 })
  db.put(TABLE, { 1 => 2, 2 => "Bob", 3 => 65.0 })
  db.put(TABLE, { 1 => 3, 2 => "Carol", 3 => 82.0 })
  db.put(TABLE, { 1 => 4, 2 => "Dave", 3 => 91.0 })
  db.put(TABLE, { 1 => 5, 2 => "Eve", 3 => 12.5 })
  puts "Inserted 5 rows"

  # Range condition: scores in [60.0, 90.0]. "column" maps to column_id, so pass
  # the numeric column id (3), not the name. The "score" column is float64, so use
  # the range_f64 condition (plain "range" expects an i64 bound and rejects
  # floats); range_f64 also requires the inclusivity flags (min_inclusive/
  # max_inclusive -> lo_inclusive/hi_inclusive).
  rng = db.query(TABLE)
    .where("range_f64", "column" => 3, "min" => 60.0, "max" => 90.0,
                         "min_inclusive" => true, "max_inclusive" => true)
    .execute
  puts "Range query (score in [60,90]) returned #{rng.length} rows:"
  rng.each { |row| puts "  #{row.inspect}" }

  # Primary-key condition: fetch the single row with id == 4.
  pk = db.query(TABLE).where("pk", "value" => 4).execute
  puts "PK query (id == 4) returned #{pk.length} rows:"
  pk.each { |row| puts "  #{row.inspect}" }
ensure
  # Always drop the table, even if an earlier step raised.
  db.drop_table(TABLE) rescue nil
  puts "Dropped table #{TABLE}"
end
