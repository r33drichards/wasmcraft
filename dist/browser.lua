-- browser — render a web page (HTML/CSS now; JS/React in later stages) onto a
-- CC:Tweaked monitor. It runs the wasm "web engine" (web.wasm) through the
-- wasmcraft interpreter and paints the draw protocol it emits (csrc/web/draw.h).
--
--   Usage:  browser [--jit|--transpile|--auto] [--scale N] [--engine M.wasm] [page]
--           page    an .html file or a directory (default: index.html in cwd);
--                   the page's directory is mounted so the engine can fopen
--                   linked .css/.js by relative path.
--           --scale monitor text scale (0.5..5, default 1); larger = bigger text
--           --engine override the engine module (defaults to web.wasm)
--   Falls back to the CC terminal when no monitor is attached, and to plain
--   ASCII off CC entirely.
--
-- This is the RENDERING SUBSTRATE for the whole web stack: the engine grows from
-- HTML/CSS to QuickJS-driven React, but it always speaks the same draw protocol,
-- so this file does not change as the engine gains features.
local BUNDLE_URL = "https://github.com/r33drichards/wasmcraft/releases/latest/download/wasmcraft.lua"

local args = { ... }
local mode, scale, engineMod = "interp", 1, "web.wasm"
local positional = {}
local i = 1
while i <= #args do
  local a = args[i]
  if a == "--interp" then mode = "interp"
  elseif a == "--jit" or a == "--compile" then mode = "jit"
  elseif a == "--transpile" then mode = "transpile"
  elseif a == "--auto" then mode = "auto"
  elseif a == "--scale" then i = i + 1; scale = tonumber(args[i]) or 1
  elseif a == "--engine" then i = i + 1; engineMod = args[i] or engineMod
  else positional[#positional + 1] = a end
  i = i + 1
end
local PAGE_ARG = positional[1]   -- file, dir, or nil

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

-- Instantiate the web engine as a REACTOR (mount `root`, route stdout=draw
-- protocol to `writefn`, stderr=console.log to `errfn`), call _initialize, and
-- return the live instance so the caller can drive web_init / web_event across
-- many frames (interactivity). stdout and stderr MUST be separate so console
-- output can't corrupt the frame the parser is building.
local function start_engine(engine, bytes, writefn, errfn, root, opts)
  if engine.set_yield and type(os) == "table" and os.queueEvent and os.pullEvent then
    engine.set_yield(function() os.queueEvent("browser_yield"); os.pullEvent("browser_yield") end, 200000)
  end
  local wasi = engine.wasi
  local module = engine.load(bytes)
  -- the bundle's hostfs is CC fs-backed (in-game); off CC fall back to wasi's
  -- io-based hostfs. Passing fs explicitly avoids wasi.make building an io_hostfs
  -- that would fail on CC (which has no io.open).
  local hostfs = (engine.hostfs and engine.hostfs(root or "."))
              or (wasi.io_hostfs and wasi.io_hostfs(root or "."))
  local host = wasi.make({ write = writefn, writeerr = errfn or function() end, args = { "web.wasm" },
                           fs = hostfs, root = root or "." })
  local inst = engine.instantiate(module, { wasi_snapshot_preview1 = host }, opts)
  inst:call("_initialize")
  return inst
end

-- marshal a Lua string into the module's memory as a NUL-terminated C string
local function wstr(inst, s)
  local p = inst:call("web_malloc", #s + 1)
  inst.memory:storestr(p, s); inst.memory:set8(p + #s, 0)
  return p
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

-- resolve the page argument into a (root dir, page filename) pair. The engine
-- runs with `root` mounted and fopens `page` (plus any linked files) from it.
local function resolve_page(arg)
  if not arg then return ".", "index.html" end
  local isdir = on_cc and fs.isDir(arg)
  if not on_cc then  -- off CC: a trailing slash or no .html extension => treat as dir
    isdir = arg:sub(-1) == "/" or (not arg:match("%.html?$") and not arg:match("%.%w+$"))
  end
  if isdir then return (arg:gsub("/$", "")), "index.html" end
  local dir, file = arg:match("^(.*)[/\\]([^/\\]+)$")
  if dir then return dir, file end
  return ".", arg
end

-- ---- run --------------------------------------------------------------------
local engine = load_engine()
local enginePath = assert(find({ engineMod, "wasm/" .. engineMod, "dist/" .. engineMod }),
                          engineMod .. " not found (build it with tools/build-fixtures)")
local bytes = read_bytes(enginePath)

local root, page = resolve_page(PAGE_ARG)

local kind, dev = pick_device()
if kind == "monitor" then reset_palette(dev) end

-- the layout width is the device's character width: set the monitor scale first,
-- then read its size; the engine lays the page out to exactly that many columns.
local cols, drows = 51, nil
if kind == "monitor" then
  dev.setTextScale(scale); cols, drows = dev.getSize()
elseif kind == "term" then
  cols, drows = dev.getSize()
end

local function render(fr)
  if kind == "monitor" or kind == "term" then
    dev.setBackgroundColor(1); dev.clear()
    WR.paint_blit(dev, fr, drows)   -- clip to the device height (page may scroll)
  else
    WR.paint_ascii(fr)
  end
end

-- console.log (engine stderr) is collected separately from the draw protocol;
-- shown only in ASCII mode so it can't disturb a monitor/terminal frame.
local console = {}
local function errfn(s) console[#console + 1] = s end

local sink = WR.line_sink(WR.make_parser(render))
local inst = start_engine(engine, bytes, sink, errfn, root, { mode = mode })

-- first frame
local pp = wstr(inst, page); inst:call("web_init", pp, cols); inst:call("web_free", pp)

-- interactive loop (CC only): route monitor/terminal taps into the engine as
-- click events; each event re-renders and repaints. Quit with Q or Ctrl+T.
if (kind == "monitor" or kind == "term") and type(os) == "table" and os.pullEvent then
  if kind == "monitor" then print("browser: tap the monitor to interact; press Q (or Ctrl+T) to quit") end
  while true do
    local ev = { os.pullEvent() }
    local e = ev[1]
    if e == "monitor_touch" or e == "mouse_click" then
      local x, y = ev[3], ev[4]                       -- 1-based cell; layout is 0-based
      local tp = wstr(inst, "click"); inst:call("web_event", tp, x - 1, y - 1); inst:call("web_free", tp)
    elseif (e == "char" and ev[2] == "q") or e == "terminate" then
      break
    end
  end
elseif kind == "ascii" and #console > 0 then
  io.write("\n[console] " .. table.concat(console))
end
