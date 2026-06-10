# Rebuild fixtures and the bundle

Goal: regenerate the checked-in build products — the `.wasm` test fixtures in
`wasm/` and the amalgamated `dist/wasmcraft.lua` bundle — after changing
their sources.

## Rebuild the wasm fixtures

```sh
tools/build-fixtures
```

Run it from anywhere; it works out the repo root itself. If `wat2wasm` and
`zig` aren't on your PATH it re-execs itself under `nix shell` with both.
It does, in order:

1. **Fetch SQLite** — downloads the amalgamation (3.53.2) into `vendor/` and
   copies `sqlite3.c/h` into `csrc/`, skipped if `csrc/sqlite3.c` exists.
2. **Assemble `.wat` fixtures** — every `test/wat/*.wat` →
   `wasm/<name>.wasm` via `wat2wasm`.
3. **Compile the C fixtures** with `zig cc -target wasm32-wasi`:
   - `wasm/hello.wasm`, `wasm/compute.wasm` (`-Os`)
   - `wasm/sqlite.wasm` — SQLite demo command module (`-O2`, ~15 s)
   - `wasm/sqlite-min.wasm` — same, size-optimized (`-Oz`)
   - `wasm/wq.wasm` — the SQLite **reactor** (`-mexec-model=reactor`,
     `-Wl,--export-memory`) that `sql.lua` drives

SQLite is built single-threaded with WAL omitted
(`-DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_WAL ...`) — there are no threads or
mmap under this WASI host.

Add a new fixture by dropping a `.wat` in `test/wat/` or wiring a new
`zig cc` line into the `build()` function.

## Rebuild the bundle

```sh
tools/amalgamate
```

Produces `dist/wasmcraft.lua`: every module in `src/` inlined into one file
with a tiny `require` shim, so it can be dropped onto a CC computer (which
has no `package.path`). Notes:

- Module order matters and is hardcoded in the script; new `src/` modules
  must be added to its list.
- `bit_native.lua` uses Lua 5.3+ operators a 5.1 parser would reject, so it
  is embedded as a *string* and `load()`-ed lazily — never executed on
  Cobalt/CC (which has `bit32`), compiled fine on Lua 5.4.
- If deployed computers cache the bundle, bump `wasmcraft.version` (set near
  the end of the runner section in `tools/amalgamate`) so self-healing
  loaders like `picatd` know to refresh.

## Publish (optional)

The CC-side loaders fetch from a paste store; overwrite the slots to ship a
new build:

```sh
curl -X PUT --data-binary @dist/wasmcraft.lua https://paste-production.up.railway.app/wasmcraft-bundle
curl -X PUT --data-binary @wasm/wq.wasm      https://paste-production.up.railway.app/wc-wq.wasm
curl -X PUT --data-binary @dist/picat.lua    https://paste-production.up.railway.app/wc-picat.lua
```

## Verify

```sh
nix-shell --run "tools/test"
tools/cobalt dist/wasmcraft.lua --jit wasm/hello.wasm   # bundle smoke test
```
