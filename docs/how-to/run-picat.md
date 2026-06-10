# Run Picat programs

Goal: execute [Picat](http://picat-lang.org/) constraint/planning programs on
the wasm engine — one-shot or in a warm session.

## Prerequisite: picat.wasm

The Picat engine compiled to WASI is **5.3 MB** and is not auto-downloaded.
Put it where the loaders look:

- In ComputerCraft: on a floppy disk, so it mounts at `/disk/picat.wasm`
  (a floppy holds it; computer storage may not). Get it from
  <https://tinyurl.com/2cladfgs>.
- Standalone: `picat.wasm` or `wasm/picat.wasm` in the working directory,
  or set `picat.modulePath` explicitly.

## One-shot: the `pirun` program

With `dist/pirun.lua` on a CC computer (it fetches the bundle and the picat
library itself):

```
pirun myprogram.pi
pirun                  -- no arg: runs a built-in planner demo
```

Runs in jit (compiled) mode. Expect a noticeable boot time — Picat is a big
module — then fast execution.

## As a library: `picat.run`

```lua
local picat = require("picat")        -- dist/picat.lua
picat.modulePath = "/disk/picat.wasm" -- if not at a default location

local out = picat.run([[
  main => println("hi"), X = 2+3, printf("2+3=%w\n", X).
]])
print(out)                            -- the program's stdout, as a string
```

`picat.runfile(path, opts)` runs a `.pi` file already on disk (relative to
`opts.root`, default `"."`).

Every `picat.run` boots the engine from scratch. Fine for occasional calls;
for anything interactive, use a session.

## Boot once, run many: `picat.session`

A session boots the Picat REPL **once** (~30 s on a CC computer) and then
compiles and runs each program in the warm engine:

```lua
local S = picat.session()

print(S:run([[
  main => println("first run pays the boot").
]]))

print(S:run([[
  main => println("this one is fast").
]]))

print(S:query('X = 2+3, println(X).'))  -- raw goal, REPL semantics

S:reset()   -- discard the engine, boot fresh (clears asserted facts)
S:close()   -- halt the engine
```

`S:run` returns only the program's own stdout (REPL echo and prompts are
stripped). If the program fails to compile you get the raw REPL output back —
look there for the error message.

Loaded modules and asserted facts persist across `S:run` calls within a
session. That's a feature (build up state) and a hazard (stale predicates) —
`S:reset()` when you need a clean slate.

## Multiple users / no local picat.wasm?

Run the engine once on a server computer and talk to it over rednet:
[Run a Picat daemon](run-a-picat-daemon.md). Client computers then need
**no** picat.wasm at all.
