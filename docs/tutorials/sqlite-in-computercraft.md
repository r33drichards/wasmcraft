# SQLite in ComputerCraft

In this tutorial you will get a working SQLite shell on a ComputerCraft
computer in Minecraft, create a database, and verify that it survives the
computer rebooting. No mods beyond CC:Tweaked are required — SQLite runs as
WebAssembly inside the pure-Lua engine.

You need a CC:Tweaked computer on a server with the HTTP API enabled
(`http.enabled=true`, the default in single-player).

## 1. Get sqlsh onto the computer

Copy `dist/sqlsh.lua` onto the computer as `sqlsh`. Any method works —
`pastebin get`, `wget`, or dropping the file into the computer's folder in
your save. For example, if you host the file somewhere reachable:

```
wget <your-url>/sqlsh.lua sqlsh
```

## 2. First run — it bootstraps itself

```
sqlsh
```

On first run, sqlsh downloads its two dependencies into the computer's root:

- `wasmcraft` — the amalgamated interpreter bundle (all of `src/` in one file)
- `wq.wasm` — SQLite compiled to a wasm reactor with a generic query API

Then it opens the default database file `data.db` and gives you a prompt.

## 3. Create a table and query it

Type SQL at the prompt; statements execute through real SQLite:

```
sql> CREATE TABLE deliveries(id INTEGER PRIMARY KEY, item TEXT, qty INT);
sql> INSERT INTO deliveries(item, qty) VALUES('iron ingot', 64), ('redstone', 32);
sql> SELECT * FROM deliveries;
```

Results print as a table. The shell also understands a few dot-commands:

```
.tables     list tables
.schema     show CREATE statements
.help       list commands
.exit       quit
```

## 4. Verify persistence

Data is written through the WASI filesystem to a real file on the
computer's disk. Prove it:

1. Type `.exit`.
2. Reboot the computer (hold Ctrl+R).
3. Run `sqlsh` again and `SELECT * FROM deliveries;` — your rows are back.

You can also see the file from the CC shell: `ls` shows `data.db`.

## 5. Use it from a program

The same engine is available as a library. Create `stock.lua`:

```lua
local sql = require("wcsql")     -- needs dist/wcsql.lua on the computer as wcsql.lua
local db = sql.open("data.db")
local r = db:query("SELECT item, qty FROM deliveries ORDER BY qty DESC")
for _, row in ipairs(r.rows) do
  print(row.item .. ": " .. row.qty)
end
db:close()
```

`wcsql` bootstraps the same two dependencies automatically, so a fresh
computer only needs the one file.

## Where to go next

- The full database API (`exec`, `query`, `changes`, NULL handling):
  [SQL API reference](../reference/sql.md)
- Opening databases in subdirectories, custom filesystems:
  [Use SQLite from Lua](../how-to/use-sqlite-from-lua.md)
- Why writes flush whole files (and what that means for big databases):
  [WASI and persistence](../explanation/wasi-and-persistence.md)
