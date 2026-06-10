# Use SQLite from Lua

Goal: open, query, and persist a SQLite database from your own Lua program.
There are three layers; pick the highest one that fits.

## Easiest: `wcsql` (ComputerCraft-friendly)

`dist/wcsql.lua` is a self-bootstrapping library — on CC it downloads the
interpreter bundle and `wq.wasm` on first use; standalone it finds them on
disk:

```lua
local sql = require("wcsql")
local db  = sql.open("data.db")
db:exec("CREATE TABLE IF NOT EXISTS t(id INTEGER PRIMARY KEY, name TEXT)")
db:exec("INSERT INTO t(name) VALUES('alice')")
local r = db:query("SELECT id, name FROM t")
for _, row in ipairs(r.rows) do print(row.id, row.name) end
db:close()                      -- flushes the file
```

Rows are keyed by **both** column index and column name. SQL `NULL` comes
back as the sentinel `sql.NULL` (never `nil`, so rows stay dense).

## Mid-level: `wasmcraft.opendb`

If you already loaded the bundle, `opendb` handles paths with directories —
it splits `path` into a filesystem root and a bare filename:

```lua
local wasmcraft = loadfile("wasmcraft")()
local db = wasmcraft.opendb({
  modulePath = "wq.wasm",          -- or module = <wq.wasm bytes>
  path = "databases/inventory.db", -- nested/absolute paths just work
})
```

It picks the right filesystem backend automatically: CC's `fs` API in-game,
Lua `io` standalone.

## Low-level: `sql.open`

Direct access from `src/sql.lua`, with every knob exposed:

```lua
package.path = "src/?.lua;" .. package.path
local sql = require("sql")

local db = sql.open({
  module = wqBytes,        -- required: raw bytes of wq.wasm
  path   = "test.db",      -- filename SQLite opens (relative to root)
  root   = "/tmp/dbdir",   -- preopened dir; or pass fs = <custom hostfs>
  mode   = "jit",          -- default; "interp" for portability
})
```

A custom `fs` lets you persist anywhere — it's a plain table of
`read/write/exists/unlink/size/mkdir` functions
(see the [WASI reference](../reference/wasi.md#host-filesystems)).

## Flushing — when data actually hits disk

The WASI layer keeps each open file as an in-memory image and writes the
host file **whole** on sync/close (that is all CC's `fs` API supports). So:

- `db:close()` when you're done — that's the flush.
- SQLite itself syncs at transaction commit, so committed data is written
  promptly; but don't kill the computer mid-`exec` and expect the journal
  dance to save you the way it would on a real OS.

## Checking results

```lua
db:changes()      -- rows affected by the last statement
db:version()      -- SQLite version string
local r = db:query("SELECT ...")
r.columns         -- { "id", "name", ... }
r.rows            -- array of rows; row.name == row[i]
```

Errors (bad SQL, constraint violations) raise Lua errors with SQLite's
message — wrap calls in `pcall` if you need to recover.
