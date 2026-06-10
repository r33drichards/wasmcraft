# Command-line tools

## Development tools (`tools/`, run from the repo)

### `tools/cobalt <script.lua> [args...]`

Run a Lua script on the standalone Cobalt VM (the engine CC:Tweaked uses).
Compiles `tools/CobaltRunner.java` once against `vendor/Cobalt-0.7.3.jar`
(cached in `tools/classes/`); uses the system JDK or pulls one via nix.

### `tools/test [pattern]`

Run every `test/*_test.lua` on both Lua 5.4 and Cobalt. `pattern` is a
substring filter. Exit 0 and `== all green ==` on success.

### `tools/build-fixtures`

Regenerate every `.wasm` fixture: assemble `test/wat/*.wat` with `wat2wasm`,
compile the C programs and SQLite with `zig cc -target wasm32-wasi`.
Fetches the SQLite amalgamation into `vendor/`/`csrc/` if missing. Pulls
toolchains via `nix shell` when not on PATH.

### `tools/amalgamate`

Produce `dist/wasmcraft.lua` — all of `src/` inlined into one file with a
`require` shim, deployable to CC.

### `run.lua` — `[lua|tools/cobalt] run.lua [mode] <module.wasm> [args...]`

Run a WASI command module from the repo. Mode flags are mutually exclusive
(last one wins):

- `--interp` — tree-walking interpreter (default; runs anywhere)
- `--transpile` — compile to Lua *source* (text chunks load on every CC build)
- `--jit` (alias `--compile`) — Lua 5.1 bytecode. STRICT: errors loudly on VMs
  that refuse binary chunks (CC:Tweaked >= 1.109) instead of substituting
- `--auto` — opt-in fastest-available: jit if loadable, else transpile, else
  interp (the instance reports what ran via `inst.mode`)

## Deployable programs (`dist/`, run on a CC computer)

All of these self-bootstrap over HTTP on first run (interpreter bundle, and
where needed `wq.wasm` / the picat library) — except `picat.wasm`, which is
large and must be provided (typically a floppy at `/disk/picat.wasm`).

### `wasmcraft [--interp|--transpile|--jit] <module.wasm> [args]`

The bundle as a runner program. Loaded via `loadfile` instead, it returns
the [library API](lua-api.md#bundle-extras-distwasmcraftlua).

### `sqlsh [dbfile]`

Interactive SQLite shell. Default db `data.db`. Dot-commands: `.tables`,
`.schema`, `.help`, `.exit`. Data is saved to the db file as you go.

### `pirun [program.pi]`

Run a Picat program (jit mode). No argument runs a built-in planner demo.

### `picatd [name]`

Resident multi-session Picat daemon on rednet protocol `wcpicat`. `name`
defaults to the computer label, else `"picat"`. Message format:

```lua
{ action = "run",   program = "...", session = "foo", id = "x1" }
{ action = "query", goal = "...",    session = "foo", id = "x2" }
{ action = "reset", session = "foo" }
{ action = "ping" }
-- reply: { ok = bool, output = str, id = <echoed> }
-- interim: { status = "booting" | "queued at position N" }
```

`session` defaults to `"main"` (pre-booted at startup).

### `pic <name> [-n session] [...]`

Client for `picatd`:

```
pic <name> [-n sess] <file.pi>     run a program file
pic <name> [-n sess] -e "Goal."    run a raw goal/query
pic <name> [-n sess] -i            interactive remote shell
pic <name> [-n sess] --reset       fresh engine for that session
pic <name> [-n sess] --cancel      cancel that session's jobs
pic <name> --jobs                  daemon status: sessions, jobs, queues
pic <name> [-n sess]               type a program; end with a "." line
```

Caches the daemon's computer id in `.pic_daemon_<name>` after first contact
(busy daemons answer DNS lookups too slowly for rednet's 2 s window).

### `planner [daemon] [--install] [--fresh]`

Demo: Picat's `best_plan` vs. a naive strategy, animated side by side on a
monitor. Prefers a reachable `picatd`; falls back to local Picat.
`--install` writes `startup.lua` to re-run on boot; finished solves cache to
`.planner_result`; `--fresh` discards the cache.

## Library files (not programs)

- `wcsql.lua` — SQLite library, see the [SQL API](sql.md)
- `picat.lua` — Picat library, see the [Picat API](picat.md)
