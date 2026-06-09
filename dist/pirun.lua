-- pirun — run a Picat program through the wasmcraft compiler on Cobalt/CC.
--   Usage:  pirun [program.pi]        (no arg → built-in planner demo)
-- Auto-downloads the interpreter bundle + picat library. The 5.3 MB Picat engine
-- (picat.wasm) must be reachable on disk — typically a floppy at /disk/picat.wasm
-- (get it from https://tinyurl.com/2cladfgs). Runs in jit (compiled) mode.
local BUNDLE_URL   = "https://paste-production.up.railway.app/wasmcraft-bundle"
local PICATLIB_URL = "https://paste-production.up.railway.app/wc-picat.lua"

local function ensure(file, url)
  if type(fs) == "table" and fs.open and not fs.exists(file) then
    io.write("fetching " .. file .. " ... ")
    local r = assert(http.get(url), "http.get failed: " .. url)
    local h = fs.open(file, "wb"); h.write(r.readAll()); h.close(); r.close(); print("ok")
  end
end
local function find(cands)
  for _, p in ipairs(cands) do local f = io.open(p, "rb"); if f then f:close(); return p end end
end

ensure("wasmcraft", BUNDLE_URL)
ensure("picat.lua", PICATLIB_URL)

local picat = assert(loadfile(find({ "picat.lua", "dist/picat.lua" }) or error("picat.lua missing")))()
local wasmpath = find({ "disk/picat.wasm", "picat.wasm", "wasm/picat.wasm",
  "/Users/robertwendt/picat-cc/third_party/picat/emu/picat.wasm" })
if not wasmpath then
  print("picat.wasm (5.3 MB) not found.")
  print("Put it on a floppy disk (mounts at /disk/picat.wasm) — get it from:")
  print("  https://tinyurl.com/2cladfgs")
  return
end
picat.modulePath = wasmpath

local DEMO = [[
import planner.
main =>
  println("Picat planner (compiled wasm on Cobalt):"),
  best_plan({{0,0},[{4,4},{4,0}],[{2,1},{2,2},{2,3}]}, P),
  printf("shortest path around the wall = %w moves\n", len(P)),
  foreach(Step in P) printf(" %w", Step) end, nl.
final({_,Gs,_}) => Gs=[].
action(F,T,A,C) ?=> F={{X,Y},Gs,W}, member({Dx,Dy},[{-1,0},{1,0},{0,-1},{0,1}]),
  Tx=X+Dx,Ty=Y+Dy, member(Tx,0..4),member(Ty,0..4), not member({Tx,Ty},W),
  T={{Tx,Ty},Gs,W}, A=move, C=1.
action(F,T,A,C) ?=> F={Pos,Gs,W}, member(Pos,Gs), T={Pos,delete(Gs,Pos),W}, A=mark, C=1.
]]

local args = { ... }
if args[1] then
  local dir, name = args[1]:match("^(.*)/([^/]+)$")
  io.write(picat.runfile(name or args[1], { root = dir or "." }))
else
  print("(no .pi given — running the planner demo; first run compiles Picat, ~30-60s)")
  io.write(picat.run(DEMO, { root = "." }))
end
