#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Example: basic CRUD operations with the MongrelDB Ruby client.
#
# Run: ruby examples/basic_crud.rb
# Requires: mongreldb-server running on http://127.0.0.1:8453
#
# Creates a table, inserts three rows, counts them, queries all rows, upserts
# (updates) one row by primary key, deletes one row, then drops the table.
# Progress is printed at every step.

require "mongreldb"

URL = "http://127.0.0.1:8453"
TABLE = "example_crud"

db = MongrelDB::Client.new(url: URL)

# Health check; bail out if the daemon is unreachable.
unless db.health
  warn "daemon not reachable at #{URL}"
  exit 1
end
puts "Connected to MongrelDB"

# Create the table. Schema: id (int64 PK), name (varchar), score (float64).
tid = db.create_table(TABLE, [
  { "id" => 1, "name" => "id", "ty" => "int64", "primary_key" => true, "nullable" => false },
  { "id" => 2, "name" => "name", "ty" => "varchar", "primary_key" => false, "nullable" => false },
  { "id" => 3, "name" => "score", "ty" => "float64", "primary_key" => false, "nullable" => false },
])
puts "Created table #{TABLE} (id #{tid})"

# Insert three rows. Cells map column id -> value. Wrap the cells in braces:
# Client#put takes keyword args (idempotency_key:), and Ruby 3 treats a trailing
# braceless hash ambiguously with keyword args.
db.put(TABLE, { 1 => 1, 2 => "Alice", 3 => 95.5 })
db.put(TABLE, { 1 => 2, 2 => "Bob", 3 => 82.0 })
db.put(TABLE, { 1 => 3, 2 => "Carol", 3 => 78.3 })
puts "Inserted 3 rows"

puts "Total rows: #{db.count(TABLE)}"

# Query all rows (no conditions).
all = db.query(TABLE).execute
puts "Query returned #{all.length} rows:"
all.each { |row| puts "  #{row.inspect}" }

# Upsert (update) Alice's score. update_cells supplies the values written on a
# primary-key conflict.
db.upsert(TABLE, { 1 => 1, 2 => "Alice", 3 => 100.0 }, update_cells: { 2 => "Alice", 3 => 100.0 })
puts "Upserted Alice's score to 100.0"
puts "Total rows after upsert: #{db.count(TABLE)}"

# Delete Carol (primary key 3).
db.delete_by_pk(TABLE, 3)
puts "Deleted Carol; remaining rows: #{db.count(TABLE)}"

# Cleanup.
db.drop_table(TABLE)
puts "Dropped table #{TABLE}"
