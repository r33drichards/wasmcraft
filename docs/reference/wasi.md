# WASI host

`src/wasi.lua` implements a minimal WASI preview1 host in two tiers:

1. stdio / clock / args — enough to boot a wasi-libc "command" module;
2. a real filesystem — preopened dir, `path_open`, `fd_read`, `fd_write`,
   `fd_seek`, filestat, unlink, … backed by host files, so programs like
   SQLite persist on-disk files through ordinary WASI calls.

## `wasi.make(opts) → host`

Build an import module to pass as `imports.wasi_snapshot_preview1`.

| Option | Type | Default | Meaning |
|---|---|---|---|
| `write` | `function(s)` | `io.write` | stdout sink |
| `writeerr` | `function(s)` | same as `write` | stderr sink |
| `args` | `{string,...}` | `{}` | WASI argv; `args[1]` is the program name |
| `fs` | hostfs table | — | filesystem backend (see below) |
| `root` | string | — | if no `fs` given, build an `io`-backed hostfs rooted here; the root becomes the preopened directory |
| `stdin` | `function(maxlen) → string` | — | stdin reader; when present, stdin reports as a tty (this is how the Picat REPL is driven) |
| `debug` | `true` \| `function(s)` | off | trace WASI calls |

## Exit unwinding

`wasi.EXIT` is a unique marker table.

`proc_exit(code)` raises a Lua error whose value is a table marked with the
unique key `wasi.EXIT` and carrying `code`:

```lua
local ok, err = pcall(function() inst:call("_start") end)
if not ok and type(err) == "table" and err[wasi.EXIT] then
  -- normal program exit; err.code is the exit code
end
```

## Host filesystems

A hostfs is a plain table of six functions — implement them over anything:

```lua
{
  read   = function(path) → string | nil,   -- whole file, nil if absent
  write  = function(path, data),            -- whole file
  exists = function(path) → bool,
  unlink = function(path),
  size   = function(path) → n | nil,
  mkdir  = function(path),
}
```

Provided backends:

- `wasi.io_hostfs(root)` — standard Lua `io`, rooted at a directory
  (built automatically from `opts.root`).
- `wasmcraft.hostfs(root)` (bundle) — CC:Tweaked's `fs` API in-game.

## File model

Each open fd holds an **in-memory image** of the file supporting random
read/write/seek/truncate. The host file is read whole on open and written
whole on `fd_sync`/`fd_datasync`/close — whole-file replace is the only write
primitive CC's `fs` API offers. Consequences are discussed in
[WASI and persistence](../explanation/wasi-and-persistence.md).

## i64 arguments

WASI functions taking 64-bit arguments (offsets, timestamps) accept both the
interpreter's `{h, l}` representation and plain Lua numbers from the jit
path.

## Not implemented

No sockets, no threads, no `poll_oneoff` beyond what wasi-libc startup needs,
no mmap. Modules requiring those will trap with an unimplemented-import
error naming the missing function.
