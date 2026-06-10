# WASI and persistence

How a database file in Minecraft survives a reboot — and what the
filesystem underneath actually guarantees.

## The shape of the problem

SQLite doesn't know it's in Minecraft. It opens a file, seeks, reads pages,
writes pages, syncs. WASI preview1 gives it that POSIX-ish surface
(`path_open`, `fd_read`, `fd_write`, `fd_seek`, `fd_sync`, filestat,
unlink), and `src/wasi.lua` implements it.

The host, however, may be CC:Tweaked — whose `fs` API has **no random
access writes**. You can read a whole file and you can write a whole file;
you cannot patch byte 4096 in place.

## The solution: in-memory file images

Each open fd holds a `FileImage` — the file's bytes in a Lua table with
random read/write/seek/truncate and a dirty flag. The lifecycle:

1. **Open:** the host file is read whole into the image.
2. **Use:** all fd operations hit the image; SQLite gets correct
   random-access semantics regardless of the host.
3. **Flush:** on `fd_sync`/`fd_datasync`/close, a dirty image is serialized
   and the host file is written whole.

The host backend is pluggable — a table of six whole-file functions
(`read`, `write`, `exists`, `unlink`, `size`, `mkdir`) — with an `io`-backed
implementation for standalone Lua and an `fs`-backed one for CC. Anything
that can store named blobs can be a backend.

## What this buys

- **Correctness over CC's fs:** SQLite's page-level access pattern works on
  an API that only does whole files.
- **Real persistence:** the `.db` on a CC computer is a genuine SQLite
  database file. Copy it out of the save and open it in any sqlite3.
- **Speed:** reads/writes during a transaction are memory operations.

## What it costs

- **Memory:** an open file lives in RAM twice in a sense (Lua byte table +
  the module's own caches). Fine for the in-game scale this targets;
  a multi-hundred-MB database is not the use case.
- **Write amplification:** a one-row insert rewrites the whole db file at
  sync. Again: in-game scale.
- **Crash windows:** durability is "as of the last flush." SQLite syncs at
  commit, so committed transactions are written promptly — but a host
  killed *mid-write* can lose or corrupt the file in ways a real OS's
  rename-and-fsync dance would survive. SQLite is accordingly built with
  WAL omitted and `SQLITE_TEMP_STORE=3` (temp files in memory), keeping
  persistence to a single file.

## Two module flavors

The WASI host boots both kinds of wasi-libc modules:

- **Command modules** (`_start`): run `main` to completion, end via
  `proc_exit` — which unwinds as a Lua error marked with `wasi.EXIT`, since
  there is no `exit()` on a Lua VM. `hello.wasm`, `sqlite.wasm`, and
  `picat.wasm` are commands.
- **Reactor modules** (`_initialize` + exports): initialize once, then serve
  calls indefinitely. `wq.wasm` is a reactor — that's what lets `sql.lua`
  keep a database open across many `exec`/`query` calls with the file image
  warm in between.

## Stdin as a coroutine

One more trick lives here: `wasi.make` accepts a `stdin` reader function,
and reports stdin as a tty when present. The Picat session feature drives
the engine's interactive REPL by running `_start` inside a coroutine whose
stdin reader **yields** when the buffer is empty — the host feeds a line,
resumes, and collects output until the engine parks again. That coroutine
seam is what turns a batch WASI command into a long-lived in-game service.
