# Run the tests

Goal: verify the engine on both VMs it targets.

## The whole suite

```sh
nix-shell --run "tools/test"
```

Every `test/*_test.lua` runs twice:

- `lua54:` — Lua 5.4 from the dev shell (fast feedback)
- `cobalt:` — the standalone Cobalt jar via `tools/cobalt` (the VM
  CC:Tweaked actually uses)

A test passes when its output contains `ALL_PASS` and no `FAILED`. The run
ends with `== all green ==` (exit 0) or `== FAILURES ==` (exit 1) with the
failing test's output indented below it.

## A subset

The argument is a substring filter on the test path:

```sh
nix-shell --run "tools/test sql"        # sql_test.lua + sqlite_test.lua
nix-shell --run "tools/test compiler"
```

## One test, one VM

```sh
nix-shell --run "lua test/int64_test.lua"
nix-shell --run "tools/cobalt test/int64_test.lua"
```

`tools/cobalt` compiles its Java harness on first use (cached in
`tools/classes/`).

## Differential testing against wasmtime

The dev shell ships wasmtime as a reference oracle. When a fixture
misbehaves, compare:

```sh
wasmtime wasm/i64ops.wasm
lua run.lua wasm/i64ops.wasm
```

## Writing a new test

Drop `test/<name>_test.lua` in place — `tools/test` picks it up
automatically. Use `test/harness.lua` for assertions, and make the script
print `ALL_PASS` on success. Two rules keep it honest:

1. Stick to the Lua 5.1 subset Cobalt supports (no integer division
   operator, no goto, no 5.3+ bitwise operators — use the `bit` shim).
2. It must pass on **both** VMs; green on Lua 5.4 alone doesn't count.
