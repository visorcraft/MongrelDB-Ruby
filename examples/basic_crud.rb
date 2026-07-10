#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Example: basic CRUD operations with the MongrelDB Ruby client.
#
# Run: ruby -Ilib examples/basic_crud.rb
# Requires: mongreldb-server running on http://127.0.0.1:8453
#
# Creates a table, inserts three rows, counts them, queries all rows, upserts
# (updates) one row by primary key, deletes one row, then drops the table.
# Progress is printed at every step.

require "mongreldb"
require "securerandom"

URL = "http://127.0.0.1:8453"
# Unique suffix per run so concurrent/ repeated runs don't collide on the same
# table name, and the table can always be dropped in the ensure block.
TABLE = "example_crud_#{Time.now.to_i}_#{SecureRandom.hex(4)}"

db = MongrelDB::Client.new(url: URL)

# Health check; bail out if the daemon is unreachable.
unless db.health
  warn "daemon not reachable at #{URL}"
  exit 1
end
puts "Connected to MongrelDB"

begin
  # Create the table. Schema: id (int64 PK), role (enum with default), name
  # (varchar), score (float64 with default). Column-level keys (enum_variants,
  # default_value) are forwarded to the daemon verbatim - see
  # spec/create_table_wire_shape_spec.rb for the wire-shape conformance test.
  tid = db.create_table(TABLE, [
    { "id" => 1, "name" => "id", "ty" => "int64", "primary_key" => true, "nullable" => false },
    { "id" => 2, "name" => "role", "ty" => "enum",
      "enum_variants" => ["admin", "member", "guest"],
      "default_value" => "member",
      "primary_key" => false, "nullable" => false },
    { "id" => 3, "name" => "name", "ty" => "varchar", "primary_key" => false, "nullable" => false },
    { "id" => 4, "name" => "score", "ty" => "float64",
      "default_value" => 0,
      "primary_key" => false, "nullable" => false },
  ])
  puts "Created table #{TABLE} (id #{tid})"

  # Insert three rows. Cells map column id -> value. Wrap the cells in braces:
  # Client#put takes keyword args (idempotency_key:), and Ruby 3 treats a trailing
  # braceless hash ambiguously with keyword args.
  db.put(TABLE, { 1 => 1, 2 => "admin",  3 => "Alice", 4 => 95.5 })
  db.put(TABLE, { 1 => 2, 3 => "Bob",   4 => 82.0 })  # role defaults to "member"
  db.put(TABLE, { 1 => 3, 2 => "guest", 3 => "Carol", 4 => 78.3 })
  puts "Inserted 3 rows"

  puts "Total rows: #{db.count(TABLE)}"

  # Query all rows (no conditions).
  all = db.query(TABLE).execute
  puts "Query returned #{all.length} rows:"
  all.each { |row| puts "  #{row.inspect}" }

  # Upsert (update) Alice's row. update_cells supplies the values written on a
  # primary-key conflict. Score is bumped from 95.5 to 100.0; role and name
  # are echoed back unchanged.
  db.upsert(TABLE, { 1 => 1, 2 => "admin", 3 => "Alice", 4 => 100.0 },
            update_cells: { 2 => "admin", 3 => "Alice", 4 => 100.0 })
  puts "Upserted Alice's score to 100.0"
  puts "Total rows after upsert: #{db.count(TABLE)}"

  # Delete Carol (primary key 3).
  db.delete_by_pk(TABLE, 3)
  puts "Deleted Carol; remaining rows: #{db.count(TABLE)}"
ensure
  # Always drop the table, even if an earlier step raised.
  db.drop_table(TABLE) rescue nil
  puts "Dropped table #{TABLE}"
end
