-- browser — render a web page (eventually HTML/CSS/JS/React) onto a CC:Tweaked
-- monitor by running a wasm "web engine" through the wasmcraft interpreter and
-- painting the draw protocol it emits (see csrc/web/draw.h).
--
--   Usage:  browser [--jit|--transpile|--auto] [module.wasm]
--           (module defaults to web.wasm; falls back to the terminal when no
--            monitor is attached, and to plain ASCII off CC entirely)
--
-- This is the RENDERING SUBSTRATE for the whole web stack: Stage 0 ships a
-- hand-built page (csrc/web/mvp.c); later stages swap in a real HTML/CSS layout
-- engine and then QuickJS-driven React. None of them change this file — they all
-- speak the same line-based draw protocol, parsed by parse_line() below.
local BUNDLE_URL = "https://github.com/r33drichards/wasmcraft/releases/latest/download/wasmcraft.lua"

local args = { ... }
local mode = "interp"
while true do
  if args[1] == "--interp" then mode = "interp"
  elseif args[1] == "--jit" or args[1] == "--compile" then mode = "jit"
  elseif args[1] == "--transpile" then mode = "transpile"
  elseif args[1] == "--auto" then mode = "auto"
  else break end
  table.remove(args, 1)
end
local MODULE = args[1] or "web.wasm"

-- ---- locate + load the engine (bundle on CC, src/ in the repo) --------------
local on_cc = type(fs) == "table" and fs.open ~= nil

local function find(cands)
  for _, p in ipairs(cands) do
    if on_cc then if fs.exists(p) and not fs.isDir(p) then return p end
    else local f = io.open(p, "rb"); if f then f:close(); return p end end
  end
end

local function load_engine()
  -- in the repo, src/ is on package.path (run via tools/cobalt run.lua-style)
  local ok, w = pcall(require, "wasm")
  if ok then return { load = w.load, instantiate = w.instantiate,
                      wasi = require("wasi"), set_yield = w.set_yield } end
  -- otherwise load the amalgamated bundle (downloading it on CC if missing)
  if on_cc and not fs.exists("wasmcraft") then
    local r = assert(http.get(BUNDLE_URL), "http.get failed: " .. BUNDLE_URL)
    local h = fs.open("wasmcraft", "wb"); h.write(r.readAll()); h.close(); r.close()
  end
  local path = assert(find({ "wasmcraft", "dist/wasmcraft.lua", "wasmcraft.lua" }),
                      "wasmcraft engine bundle not found")
  return assert(loadfile(path))()
end

-- run a WASI command module, routing its stdout to `writefn`. Works off both the
-- bundle and the src/ require path (both expose load/instantiate/wasi).
local function run_wasi(engine, bytes, prog_args, writefn, opts)
  -- under CC, yield to the event loop periodically so long runs don't trip the
  -- "too long without yielding" watchdog (the bundle installs this itself)
  if engine.set_yield and type(os) == "table" and os.queueEvent and os.pullEvent then
    engine.set_yield(function() os.queueEvent("browser_yield"); os.pullEvent("browser_yield") end, 200000)
  end
  local wasi = engine.wasi
  local module = engine.load(bytes)
  local host = wasi.make({ write = writefn, writeerr = writefn, args = prog_args })
  local inst = engine.instantiate(module, { wasi_snapshot_preview1 = host }, opts)
  local ok, err = pcall(function() inst:call("_start") end)
  if ok then return 0 end
  if type(err) == "table" and err[wasi.EXIT] then return err.code or 0 end
  error(err)
end

local function read_bytes(path)
  if on_cc then
    local h = assert(fs.open(path, "rb"), "cannot open " .. path)
    local d = h.readAll(); h.close(); return d
  end
  local f = assert(io.open(path, "rb"), "cannot open " .. path)
  local d = f:read("*a"); f:close(); return d
end

-- ---- the pure renderer (frame buffer + protocol parser) lives in webrender;
-- it carries no CC dependencies so it is shared with the test suite -----------
local WR = (function()
  local ok, m = pcall(require, "webrender")
  if ok then return m end
  local p = assert(find({ "webrender.lua", "dist/webrender.lua" }),
                   "webrender.lua not found (it ships beside browser.lua)")
  return assert(loadfile(p))()
end)()

-- ---- device selection ------------------------------------------------------
local function pick_device()
  if type(peripheral) == "table" and peripheral.find then
    local mon = peripheral.find("monitor")
    if mon then return "monitor", mon end
  end
  if type(term) == "table" and term.blit then return "term", term end
  return "ascii", nil
end

-- reset a monitor's palette to defaults so our indices mean what we expect
local function reset_palette(dev)
  if dev.setPaletteColour and term and term.nativePaletteColour then
    for i = 0, 15 do dev.setPaletteColour(2 ^ i, term.nativePaletteColour(2 ^ i)) end
  end
end

-- ---- run --------------------------------------------------------------------
local engine = load_engine()
local modPath = assert(find({ MODULE, "wasm/" .. MODULE, "dist/" .. MODULE }),
                       MODULE .. " not found (build it with tools/build-fixtures)")
local bytes = read_bytes(modPath)

local kind, dev = pick_device()
if kind == "monitor" then reset_palette(dev) end

local function render(fr)
  if kind == "monitor" then WR.fit_scale(dev, fr); dev.setBackgroundColor(1); dev.clear(); WR.paint_blit(dev, fr)
  elseif kind == "term" then WR.paint_blit(dev, fr)
  else WR.paint_ascii(fr) end
end

local sink = WR.line_sink(WR.make_parser(render))
run_wasi(engine, bytes, { modPath }, sink, { mode = mode })
