# Run a Picat daemon over rednet

Goal: one computer hosts warm Picat engines; any computer on the rednet
network (including wireless pocket computers) runs Picat programs against it
with no boot cost and no local `picat.wasm`.

## Set up the server

You need a CC computer with a modem attached and `picat.wasm` reachable
(typically a floppy at `/disk/picat.wasm` — see
[Run Picat programs](run-picat.md)). Install and run:

```
wget https://github.com/r33drichards/wasmcraft/releases/latest/download/picatd.lua picatd
picatd --install [name]
```

(`--install` writes a `startup.lua` so the daemon relaunches after
chunk-unload reboots; omit it for a one-off run.)

`name` defaults to the computer's label (else `"picat"`). The daemon:

- fetches the interpreter bundle and picat library on first run, and
  self-heals stale cached copies,
- pre-boots and warms a default `main` session,
- serves named sessions over rednet protocol `wcpicat` — each session is its
  own isolated Picat engine with its own queue, and sessions time-slice so
  one long solve doesn't block the others.

Leave it running. Label the computer (`label set solver1`) so clients can
find it by name.

## Use it from a client

On any computer with a modem (a wireless pocket computer works great):

```
wget https://github.com/r33drichards/wasmcraft/releases/latest/download/pic.lua pic
```

```
pic solver1 myprogram.pi          run a program file
pic solver1 -e "X=2+3, println(X)."   run a raw goal
pic solver1 -i                    interactive remote Picat> shell
pic solver1                       type a program, end with a "." line
```

While a job waits you get interim notes (`booting`, `queued at position N`).

## Sessions

Without `-n` you share the default `main` session. Name your own to get an
isolated engine (own loaded modules, own asserted facts, own queue):

```
pic solver1 -n alice myprogram.pi
pic solver1 -n alice --reset      fresh engine for session "alice"
pic solver1 -n alice --cancel     cancel that session's jobs (kills running)
pic solver1 --jobs                live status: sessions, jobs, queues
```

## Talking to it without `pic`

Any rednet message on protocol `wcpicat` works:

```lua
rednet.send(id, { action = "run",   program = "main => ...", session = "foo", id = "x1" }, "wcpicat")
rednet.send(id, { action = "query", goal = "X=2+3, println(X).", session = "foo", id = "x2" }, "wcpicat")
rednet.send(id, { action = "reset", session = "foo" }, "wcpicat")
rednet.send(id, { action = "ping" }, "wcpicat")   -- daemon name + live session list
```

Replies look like `{ ok = bool, output = str, id = <echoed> }`.

## A worked example: the planner demo

`dist/planner.lua` renders Picat's `best_plan` against a naive strategy side
by side on a monitor, and prefers a reachable daemon (falling back to local
Picat only if one exists):

```
planner [daemon]        solve via the network when possible
planner --install       re-run on every boot (writes startup.lua)
planner --fresh         discard the cached solve and recompute
```

Finished solves are cached to `.planner_result`, so after a chunk
unload/reboot the animation resumes instantly.
