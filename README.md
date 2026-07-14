<p align="center">
  <img src="assets/mongrel.png" alt="MongrelDB logo" width="250" />
</p>

<h1 align="center">MongrelDB Ruby Client</h1>

<p align="center">
  <b>Pure Ruby client for MongrelDB - embedded+server database with SQL, vector search, full-text search, and AI-native retrieval.</b>
  <br />
  No external gems required at runtime - built on the standard-library <code>net/http</code>. The API mirrors the MongrelDB PHP, Go, and Java clients.
</p>

<p align="center">
  <a href="https://rubygems.org/gems/mongreldb"><img src="https://img.shields.io/gem/v/mongreldb.svg" alt="Gem Version" /></a>
  <a href="https://www.ruby-lang.org/"><img src="https://img.shields.io/badge/Ruby-%3E%3D3.0-CC342D.svg" alt="Ruby" /></a>
  <a href="https://github.com/visorcraft/MongrelDB-Ruby/actions/workflows/ci.yml"><img src="https://github.com/visorcraft/MongrelDB-Ruby/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="#license"><img src="https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg" alt="License" /></a>
</p>

## Package

| Surface | Package | Install |
|---|---|---|
| Ruby client | `mongreldb` | `gem install mongreldb` |

## Requirements

- **Ruby 3.0 or newer**
- A running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB) daemon

## What It Provides

- **Typed CRUD** over the Kit transaction endpoint: `put`, `upsert` (insert-or-update on PK conflict), `delete` by row id or primary key, all with optional idempotency keys for safe retries.
- **Fluent query builder** that pushes conditions down to the engine's specialized indexes for sub-millisecond lookups: bitmap equality/IN, learned-range, null checks, FM-index full-text search, HNSW vector similarity (`ann`), and sparse vector match. Friendly aliases (`column` → `column_id`, `min`/`max` → `lo`/`hi`) are translated to the server's on-wire keys.
- **Idempotent batch transactions** - operations staged locally and committed atomically, with the engine enforcing unique, foreign-key, and check constraints at commit time. Idempotency keys return the original response on duplicate commits, even after a crash.
- **Full SQL access** through the DataFusion-backed `/sql` endpoint: recursive CTEs, window functions, `CREATE TABLE AS SELECT`, materialized views, and multi-statement execution.
- **Schema management**: typed table creation, full schema catalog, and per-table descriptors.
- **User/role/credentials management** via SQL: Argon2id-hashed catalog users, roles, and `GRANT`/`REVOKE` table-level permissions, all executed through `sql`.
- **Maintenance**: compaction (all tables or per-table).
- **Auth**: Bearer token (`--auth-token` mode) and HTTP Basic (`--auth-users` mode), with the bearer token taking precedence.
- **Typed exception hierarchy**: `MongrelDBError` (base), `AuthError` (401/403), `NotFoundError` (404), `ConflictError` (409, with error code + op index), and `QueryError` (everything else, including network failures).
- **Robust JSON handling**: NaN and Infinity raise a clear `QueryError` instead of corrupting data; the `/sql` endpoint's Arrow IPC bodies are tolerated gracefully.

## Install

```sh
gem install mongreldb
```

Or add it to your Gemfile:

```ruby
gem "mongreldb"
```

Then `bundle install`.

## Examples

Task-focused, commented guides live in [`docs/`](docs):

- [Quickstart](docs/quickstart.md) - install, start the daemon, write and run a complete program.
- [Transactions](docs/transactions.md) - batch commits, idempotency keys, constraint handling.
- [Queries](docs/queries.md) - every native condition type and the index it pushes down to.
- [SQL](docs/sql.md) - recursive CTEs, window functions, advanced SQL.
- [Authentication](docs/auth.md) - Bearer token, HTTP Basic, and open modes.
- [Errors](docs/errors.md) - the exception hierarchy and recovery patterns.

## Quick Example

```ruby
require "mongreldb"

# Connect to a running mongreldb-server daemon.
db = MongrelDB::Client.new(url: "http://127.0.0.1:8453")

# Create a table. Column ids are stable on-wire identifiers.
db.create_table("orders", [
  { "id" => 1, "name" => "id",       "ty" => "int64",   "primary_key" => true,  "nullable" => false },
  { "id" => 2, "name" => "customer", "ty" => "varchar", "primary_key" => false, "nullable" => false },
  { "id" => 3, "name" => "amount",   "ty" => "float64", "primary_key" => false, "nullable" => false },
], constraints: {
  "checks" => [{
    "id" => 1,
    "name" => "ck_status",
    "expr" => { "IsNotNull" => 2 },
  }],
})

# Insert rows (cells map column id -> value).
db.put("orders", { 1 => 1, 2 => "Alice", 3 => 99.50 })
db.put("orders", { 1 => 2, 2 => "Bob",   3 => 150.00 })

# Upsert (insert or update on PK conflict).
db.upsert("orders", { 1 => 1, 2 => "Alice", 3 => 120.00 }, update_cells: { 3 => 120.00 })

# Query with a native index condition (learned-range index). amount is a
# float64 column, so use the float range condition ("range_f64"), not "range"
# (which targets i64 columns).
rows = db.query("orders")
  .where("range_f64", "column" => 3, "min" => 100.0)
  .projection([1, 2])
  .limit(100)
  .execute

puts db.count("orders") # 2

# Run SQL.
db.sql("UPDATE orders SET amount = 200.0 WHERE customer = 'Bob'")
```

## Typed columns: enums and defaults

The `columns` array passed to `create_table` is forwarded to the daemon
verbatim, so any column-level constraints the engine supports are passed in
the column hash. Two useful keys:

- `enum_variants` (`Array<String>`) - restricts an `enum` column to a fixed set
  of string values. The engine rejects writes that fall outside the set.
- `default_value` (`String`, `Integer`, etc.) - the value written into the
  column when a row omits it. The engine-side default is applied before any
  client-side default.
- `default_expr` (`"now"` or `"uuid"`) - a dynamic server-side default.

Literal `"now"` and `"uuid"` strings are expressed through `default_value`
like any other static string; use `default_expr` only when you want the dynamic
server-side behavior.

```ruby
db.create_table("orders", [
  { "id" => 1, "name" => "id",     "ty" => "int64",   "primary_key" => true,  "nullable" => false },
  { "id" => 2, "name" => "status", "ty" => "enum",
    "enum_variants" => ["draft", "active", "archived"],
    "default_value" => "draft",
    "nullable" => false },
  { "id" => 3, "name" => "amount", "ty" => "float64", "default_value" => 0,
    "primary_key" => false, "nullable" => false },
])

# Omitting the status column falls back to the engine-side default.
db.put("orders", { 1 => 1, 3 => 99.50 })
```

Keys that are not set on a column are omitted from the request body - no
`null` placeholders are sent. See
[`spec/create_table_wire_shape_spec.rb`](spec/create_table_wire_shape_spec.rb)
for the wire-shape conformance test that guards these keys.

## Authentication

```ruby
# Bearer token (--auth-token mode)
db = MongrelDB::Client.new(url: "http://127.0.0.1:8453", token: "my-secret-token")

# HTTP Basic (--auth-users mode)
db = MongrelDB::Client.new(url: "http://127.0.0.1:8453",
                           username: "admin", password: "s3cret")

# Keyword args are optional; the daemon address defaults to 127.0.0.1:8453.
db = MongrelDB::Client.new
```

## Batch transactions

Operations are staged locally and committed atomically. The engine enforces
unique, foreign-key, and check constraints at commit time.

```ruby
txn = db.begin_transaction
txn.put("orders", { 1 => 10, 2 => "Dave", 3 => 50.00 })
txn.put("orders", { 1 => 11, 2 => "Eve",  3 => 75.00 })
txn.delete_by_pk("orders", 2)

begin
  results = txn.commit              # atomic - all or nothing
  puts "Staged #{txn.count} operations"
rescue MongrelDB::ConflictError => e
  puts "Constraint violated: #{e.error_code} - #{e.message}"
  txn.rollback
end

# Idempotent commit - safe to retry; the daemon returns the original response.
txn2 = db.begin_transaction
txn2.put("orders", { 1 => 20, 2 => "Frank", 3 => 100.00 })
txn2.commit(idempotency_key: "order-20-create")
```

## Native query builder

Conditions push down to the engine's specialized indexes. The builder accepts
friendly aliases that are translated to the server's on-wire keys: `column`
(→ `column_id`), `min`/`max` (→ `lo`/`hi`). The canonical keys are also
accepted directly.

```ruby
# Bitmap equality (low-cardinality columns).
db.query("orders").where("bitmap_eq", "column" => 2, "value" => "Alice").execute

# Range query on a float64 column (learned-range index). Use "range_f64" for
# float64 columns and "range" for i64 columns.
db.query("orders")
  .where("range_f64", "column" => 3, "min" => 50.0, "max" => 150.0,
         "max_inclusive" => false)
  .limit(100).execute

# Full-text search (FM-index).
db.query("documents")
  .where("fm_contains", "column" => 2, "pattern" => "database performance")
  .limit(10).execute

# Vector similarity search (HNSW).
db.query("embeddings")
  .where("ann", "column" => 2, "query" => [0.1, 0.2, 0.3], "k" => 10)
  .execute

# Check whether a result was capped by the limit.
q = db.query("orders").where("range_f64", "column" => 3, "min" => 0).limit(100)
rows = q.execute
if q.truncated
  # result set hit the limit; more matches exist on the server
end
```

## SQL

```ruby
db.sql("INSERT INTO orders (id, customer, amount) VALUES (99, 'Zoe', 999.0)")
db.sql("CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500")

# Recursive CTEs and window functions.
db.sql("WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<10) SELECT n FROM r")
db.sql("SELECT id, ROW_NUMBER() OVER (PARTITION BY customer ORDER BY amount DESC) FROM orders")
```

## User & role management

User, role, and permission management is performed through SQL against the
daemon's catalog. Passwords are Argon2id-hashed server-side.

```ruby
db.sql("CREATE USER admin WITH PASSWORD 's3cret-pw'")
db.sql("ALTER USER admin SET ADMIN TRUE")

db.sql("CREATE ROLE analyst")
db.sql("GRANT select ON orders TO analyst") # table-level permission
db.sql("GRANT analyst TO alice")

db.sql("SELECT username FROM catalog.users") # list users
db.sql("SELECT name FROM catalog.roles")     # list roles
```

## Error handling

Every non-2xx response is mapped to a typed exception. Rescue the specific
class for the category, or `MongrelDBError` for any client failure.

```ruby
begin
  db.put("orders", { 1 => 1 }) # duplicate PK (with a UNIQUE constraint)
rescue MongrelDB::ConflictError => e
  puts "Constraint: #{e.error_code}"   # UNIQUE_VIOLATION
  puts "Op index: #{e.op_index}"        # offending op in the transaction
rescue MongrelDB::AuthError => e
  puts "Not authorized: #{e.message}"
rescue MongrelDB::NotFoundError => e
  puts "Not found: #{e.message}"
rescue MongrelDB::QueryError => e
  puts "Query/server error: #{e.message}"
rescue MongrelDB::MongrelDBError => e
  puts "Error: #{e.message}"
end
```

## API reference

### `MongrelDB::Client`

| Method | Description |
|--------|-------------|
| `Client.new(url:, token:, username:, password:, open_timeout:, read_timeout:)` | Construct a client (`url` defaults to `http://127.0.0.1:8453`) |
| `health` → `Boolean` | Check daemon health |
| `table_names` → `Array<String>` | List table names |
| `create_table(name, columns, constraints: nil)` → `Integer` | Create a table; returns the table id |
| `drop_table(name)` → `nil` | Drop a table |
| `count(table)` → `Integer` | Row count |
| `put(table, cells, idempotency_key:)` → `Hash` | Insert a row |
| `upsert(table, cells, update_cells:, idempotency_key:)` → `Hash` | Upsert a row |
| `delete(table, row_id)` → `nil` | Delete by row id |
| `delete_by_pk(table, pk)` → `nil` | Delete by primary key |
| `query(table)` → `QueryBuilder` | Start a native query |
| `sql(sql)` → `Array<Hash>` | Execute SQL |
| `schema` → `Hash<String,Hash>` | Full schema catalog |
| `schema_for(table)` → `Hash` | Single-table descriptor |
| `compact` → `Hash` | Compact all tables |
| `compact_table(name)` → `Hash` | Compact one table |
| `history_retention_epochs` → `Integer` | Current history-retention window |
| `earliest_retained_epoch` → `Integer` | Oldest epoch still readable with `AS OF EPOCH` |
| `set_history_retention_epochs(epochs)` → `Hash` | Set the durable MVCC window |
| `begin_transaction` → `Transaction` | Start a batch |
| `get(path)`, `post(path, body)`, `http_delete(path)` → `Response` | Low-level HTTP (for endpoints not yet wrapped) |

### `MongrelDB::QueryBuilder`

| Method | Description |
|--------|-------------|
| `where(type, params)` → `self` | Add a native condition (AND-ed) |
| `projection(column_ids)` → `self` | Set column projection |
| `limit(limit)` → `self` | Set row limit |
| `offset(offset)` → `self` | Skip matching rows before the limit |
| `build` → `Hash` | Build the request payload |
| `execute` → `Array<Hash>` | Run the query |
| `truncated` → `Boolean` | Whether the last `execute` result hit the limit |

### `MongrelDB::Transaction`

| Method | Description |
|--------|-------------|
| `put(table, cells, returning:)` → `self` | Stage an insert |
| `upsert(table, cells, update_cells:, returning:)` → `self` | Stage an upsert |
| `delete(table, row_id)` → `self` | Stage a delete by row id |
| `delete_by_pk(table, pk)` → `self` | Stage a delete by primary key |
| `count` → `Integer` | Number of staged operations |
| `commit(idempotency_key:)` → `Array<Hash>` | Commit atomically |
| `rollback` → `nil` | Discard all operations |

### Exceptions

| Class | HTTP status | Notes |
|-------|-------------|-------|
| `MongrelDB::MongrelDBError` | - | Base class for all client errors |
| `MongrelDB::AuthError` | 401, 403 | Bad or missing credentials |
| `MongrelDB::NotFoundError` | 404 | Missing table, schema, or resource |
| `MongrelDB::ConflictError` | 409 | Constraint violation; carries `error_code` and `op_index` |
| `MongrelDB::QueryError` | 400, 5xx, network | Everything else |

## Building and testing

The test suite uses Minitest. It is split into two layers:

- **Offline unit tests** - exception hierarchy, query-builder alias
  translation, cells flattening, and an in-process stub for auth/transport
  checks. No daemon needed.
- **Live integration tests** - boots a real `mongreldb-server` daemon and
  exercises the full client surface. Skips automatically when no binary is
  available.

```sh
bundle install
bundle exec rake test            # runs the whole suite (live tests skip without a daemon)
bundle exec ruby test/live_test.rb   # equivalent, standalone
```

Fetch a prebuilt server binary from the [MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases)
and place it at `./bin/mongreldb-server`, set `MONGRELDB_SERVER`, or install it
on `PATH`:

```sh
mkdir -p bin
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.53.3/mongreldb-server-linux-x64
chmod +x bin/mongreldb-server
```

The live harness resolves the binary in this order: the `MONGRELDB_SERVER` env
var, `./bin/mongreldb-server`, `mongreldb-server` on `PATH`. Or point it at an
already-running daemon with `MONGRELDB_URL`.

## Contributing

Contributions are welcome. Please:

1. Open an issue first for non-trivial changes.
2. Add focused tests near your change - the suite must stay green.
3. Run `bundle exec rake test` before submitting.
4. Keep the client dependency-free (standard library only at runtime).

## History retention

Use `history_retention_epochs`, `set_history_retention_epochs`, and
`earliest_retained_epoch` with MongrelDB 0.48.0+. The retention window controls
how far back `AS OF EPOCH` time-travel queries can read; increasing it cannot
bring back history that has already been pruned.

```ruby
# Inspect the current durable MVCC window.
puts db.history_retention_epochs   # => 100
puts db.earliest_retained_epoch    # => 3

# Widen the window. The setter returns the updated response from the server.
resp = db.set_history_retention_epochs(1_000)
puts resp["history_retention_epochs"]   # => 1000
puts resp["earliest_retained_epoch"]    # => 3

# Query a past epoch. Columns omitted from the INSERT get their engine-side
# defaults, and updates committed after the chosen epoch are not visible.
rows = db.sql("SELECT id, amount FROM orders AS OF EPOCH 5")
```

## License

Dual-licensed under the **MIT License** or the **Apache License, Version 2.0**,
at your option. See [MIT](LICENSE-MIT) OR [Apache-2.0](LICENSE-APACHE) for the full text.

`SPDX-License-Identifier: MIT OR Apache-2.0`
