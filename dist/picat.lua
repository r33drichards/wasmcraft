-- picat — run Picat programs on the pure-Lua wasm interpreter, as a library.
--
--   local picat = require("picat")        -- or: local picat = dofile("picat.lua")
--   picat.modulePath = "picat.wasm"       -- where the 5.3 MB engine lives (default)
--   local out = picat.run([[
--   main => println("hi"), X = 2+3, printf("2+3=%w\n", X).
--   ]])
--   print(out)
--
-- picat.wasm is a WASI command module; this writes your program to a temp .pi
-- file on the WASI filesystem, runs the engine, and returns its stdout.
-- The interpreter bundle is auto-fetched on CC; picat.wasm must be on disk
-- (it is large and engine-specific, so set picat.modulePath if not "picat.wasm").
local BUNDLE_URL = "https://paste-production.up.railway.app/wasmcraft-bundle"

local function ensure(file, url)
  if type(fs) == "table" and fs.open and not fs.exists(file) then
    local r = assert(http.get(url), "http.get failed: " .. url)
    local h = fs.open(file, "wb"); h.write(r.readAll()); h.close(); r.close()
  end
end
local function find(cands)
  for _, p in ipairs(cands) do local f = io.open(p, "rb"); if f then f:close(); return p end end
end
local function read_bytes(path)
  if type(fs) == "table" and fs.open then local h = fs.open(path, "rb"); local d = h.readAll(); h.close(); return d end
  local f = assert(io.open(path, "rb")); local d = f:read("*a"); f:close(); return d
end

ensure("wasmcraft", BUNDLE_URL)
local bundlePath = assert(find({ "wasmcraft", "dist/wasmcraft.lua", "wasmcraft.lua" }), "interpreter bundle not found")
local wasmcraft = assert(loadfile(bundlePath))()

local M = { modulePath = "picat.wasm", _engine = wasmcraft, _module = nil }

local function load_module(opts)
  if opts.module then return wasmcraft.load(opts.module) end
  if not M._module then
    local path = opts.modulePath or M.modulePath
    M._module = wasmcraft.load(read_bytes(assert(find({ path, "wasm/picat.wasm" }), "picat.wasm not found (set picat.modulePath)")))
  end
  return M._module
end

-- Run a Picat source string; returns its stdout as a string.
function M.run(program, opts)
  opts = opts or {}
  local module = load_module(opts)
  local root = opts.root or "."
  local hostfs = wasmcraft.hostfs(root) or wasmcraft.wasi.io_hostfs(root)
  local fname = opts.file or "__picat_prog.pi"
  hostfs.write(fname, program)

  local out = {}
  local host = wasmcraft.wasi.make({
    fs = hostfs, root = root,
    args = { "picat", fname },
    write = function(s) out[#out + 1] = s end,
    writeerr = function(s) out[#out + 1] = s end,
  })
  local inst = wasmcraft.instantiate(module, { wasi_snapshot_preview1 = host }, { mode = "jit" })
  local ok, err = pcall(function() inst:call("_start") end)
  if not ok and not (type(err) == "table" and err[wasmcraft.wasi.EXIT]) then error(err) end
  pcall(function() hostfs.unlink(fname) end)
  return table.concat(out)
end

-- Run a Picat program already on disk (path relative to opts.root).
function M.runfile(path, opts)
  opts = opts or {}
  local module = load_module(opts)
  local root = opts.root or "."
  local hostfs = wasmcraft.hostfs(root) or wasmcraft.wasi.io_hostfs(root)
  local out = {}
  local host = wasmcraft.wasi.make({
    fs = hostfs, root = root, args = { "picat", path },
    write = function(s) out[#out + 1] = s end, writeerr = function(s) out[#out + 1] = s end,
  })
  local inst = wasmcraft.instantiate(module, { wasi_snapshot_preview1 = host }, { mode = "jit" })
  local ok, err = pcall(function() inst:call("_start") end)
  if not ok and not (type(err) == "table" and err[wasmcraft.wasi.EXIT]) then error(err) end
  return table.concat(out)
end

return M
