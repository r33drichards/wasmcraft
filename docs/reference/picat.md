# Picat API

`dist/picat.lua` — run [Picat](http://picat-lang.org/) programs on the wasm
engine. On CC it auto-fetches the interpreter bundle; `picat.wasm` (the
5.3 MB engine, a WASI command module) must be on disk.

```lua
local picat = require("picat")   -- or dofile("picat.lua")
```

## Module fields

| Field | Default | Meaning |
|---|---|---|
| `picat.modulePath` | `"picat.wasm"` | where to find the engine (also tries `wasm/picat.wasm`) |
| `picat._cache` | `{}` | shared jit chunk cache — repeat runs skip recompilation |

## `picat.run(program, opts) → stdout`

Run a Picat source string through a fresh engine; returns everything the
program wrote to stdout/stderr as one string.

Writes the program to a temp `.pi` file on the WASI filesystem, runs
`picat <file>` in jit mode, deletes the temp file.

| Option | Default | Meaning |
|---|---|---|
| `opts.module` | — | raw `picat.wasm` bytes (overrides path lookup) |
| `opts.modulePath` | `picat.modulePath` | engine path |
| `opts.root` | `"."` | filesystem root the program sees |
| `opts.file` | `"__picat_prog.pi"` | temp filename |

## `picat.runfile(path, opts) → stdout`

Same, for a `.pi` file already on disk (`path` relative to `opts.root`).

## `picat.session(opts) → S`

Boot the Picat REPL **once** (over a coroutine-fed stdin), then run many
programs in the warm engine. Only the first call pays the boot (~30 s on a
CC computer). `opts` as for `run` (no `file`).

### `S:run(program, name) → stdout`

Write `program` to `name` (default `"_sess.pi"`), `cl()` it in the REPL, run
`main`. Returns only the program's own output — REPL echo and prompts are
stripped via sentinel markers. On compile errors the raw REPL output is
returned instead, so the error message is visible.

State (loaded modules, asserted facts) persists across calls.

### `S:query(goal) → raw output`

Feed a raw goal line (e.g. `"X = 2+3, println(X)."`) and return the REPL's
output unfiltered.

### `S:reset()`

Halt and boot a fresh engine — clears all loaded/asserted state.

### `S:close()`

Halt the engine. A later `S:run`/`S:query` on a dead session re-boots
automatically.

## CC integration notes

- Sessions pump CC event yields (the compiled code yields for the watchdog)
  transparently via `os.pullEventRaw`.
- `picatd` (the rednet daemon) is built on `picat.session`; see
  [Run a Picat daemon](../how-to/run-a-picat-daemon.md) and the
  [CLI reference](cli.md) for its wire protocol.
