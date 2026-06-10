# SQL API

SQLite support has three layers. All return the same database handle (`Db`),
documented at the bottom.

## `wcsql` (`dist/wcsql.lua`)

Self-bootstrapping CC-friendly wrapper. On CC it downloads the interpreter
bundle and `wq.wasm` on first use; standalone it locates them on disk.

### `wcsql.open(path) → db`

Open (or create) a database file. The path persists to the computer's disk.

### `wcsql.NULL`

Sentinel for SQL `NULL` in query results (same object as `sql.NULL`).

### `wcsql._engine`

The underlying bundle API table, for advanced use.

## `wasmcraft.opendb` (bundle)

```lua
wasmcraft.opendb({
  modulePath = "wq.wasm",   -- or module = <bytes>; default "wq.wasm"
  path = "dir/my.db",       -- slash-containing paths split into root + filename
  root = nil,               -- override the fs root explicitly
  fs   = nil,               -- override the hostfs (default: CC fs in-game, else io)
}) → db
```

## `sql` (`src/sql.lua`)

### `sql.open(opts) → db`

| Option | Required | Meaning |
|---|---|---|
| `module` | yes | raw bytes of `wq.wasm` |
| `path` | | database filename SQLite opens (relative to the preopened root) |
| `fs` | | hostfs backend (see the [WASI reference](wasi.md#host-filesystems)) |
| `root` | | if no `fs`: directory for an `io`-backed hostfs (default `"."`) |
| `write` | | stdout sink for the module (default `io.write`) |
| `mode` | | execution mode, default `"jit"` |

### `sql.NULL`

Unique sentinel table representing SQL `NULL` in rows (its `tostring` is
`"NULL"`). Used instead of `nil` so rows remain dense arrays.

## The `Db` handle

### `db:exec(sql) → db`

Run SQL, discarding rows. Raises a Lua error `"sqlite error: <message>"` on
failure. Chains.

### `db:query(sql) → { columns, rows }`

Run SQL and collect results.

- `columns` — array of column names
- `rows` — array of rows; each row is keyed by **both** 1-based column index
  and column name (`row[1] == row.id`)
- `NULL` fields are `sql.NULL`
- all values arrive as strings (SQLite's text representation)

### `db:changes() → n`

Rows affected by the most recent statement.

### `db:version() → string`

The SQLite library version.

### `db:close() → db`

Close the database and flush the file to the host. Call it — this is when
persistence is guaranteed.

## The wq reactor (`csrc/wq.c`)

The wasm side of all of the above: SQLite plus a thin export surface, built
as a WASI **reactor** (`-mexec-model=reactor`, exported memory). Exports:
`wq_open`, `wq_exec`, `wq_result`, `wq_errmsg`, `wq_log`, `wq_changes`,
`wq_version`, `wq_close`, and `wq_malloc`/`wq_free` for string marshalling. Results come
back as a single string using ASCII separators — `0x1f` between fields,
`0x1e` between rows (first row = column names), `0x1d` for NULL — which
`sql.lua` decodes. SQLite is compiled single-threaded, WAL omitted.
