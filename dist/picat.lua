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
local BUNDLE_URL = "https://github.com/r33drichards/wasmcraft/releases/latest/download/wasmcraft.lua"

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

local M = { modulePath = "picat.wasm", _engine = wasmcraft, _module = nil, _cache = {} }
-- engine mode is EXPLICIT: "jit" (errors loudly where bytecode is blocked),
-- "transpile", "interp", or opt-in "auto". Set picat.mode or pass opts.mode.
M.mode = "jit"

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
  local inst = wasmcraft.instantiate(module, { wasi_snapshot_preview1 = host }, { mode = opts.mode or M.mode, chunk_cache = M._cache })
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
  local inst = wasmcraft.instantiate(module, { wasi_snapshot_preview1 = host }, { mode = opts.mode or M.mode, chunk_cache = M._cache })
  local ok, err = pcall(function() inst:call("_start") end)
  if not ok and not (type(err) == "table" and err[wasmcraft.wasi.EXIT]) then error(err) end
  return table.concat(out)
end

-- ---- live session: boot Picat ONCE, run many programs --------------------
-- Drives Picat's interactive REPL over a coroutine-fed stdin (our WASI reports
-- stdin as a tty so the REPL engages). Each :run compiles+runs a program in the
-- already-booted engine, so only the FIRST call pays the ~30s boot.
function M.session(opts)
  opts = opts or {}
  local module = load_module(opts)
  local root = opts.root or "."
  local hostfs = wasmcraft.hostfs(root) or wasmcraft.wasi.io_hostfs(root)
  local START, ENDT = "<WCSTART>", "<WCEND>"
  local S = { root = root }

  local PARK = "\0wc_stdin\0" -- sentinel the reader yields when it needs input
  local function boot()
    local out, inbuf, inpos = {}, "", 1
    local function reader(maxlen)
      while inpos > #inbuf do coroutine.yield(PARK) end  -- park until fed
      local c = inbuf:sub(inpos, inpos + maxlen - 1); inpos = inpos + #c; return c
    end
    local host = wasmcraft.wasi.make({
      fs = hostfs, root = root, args = { "picat" }, stdin = reader,
      write = function(s) out[#out + 1] = s end, writeerr = function(s) out[#out + 1] = s end,
    })
    local inst = wasmcraft.instantiate(module, { wasi_snapshot_preview1 = host }, { mode = opts.mode or M.mode, chunk_cache = M._cache })
    -- NB: no pcall here — Lua 5.1 forbids yielding across a pcall, and the reader
    -- yields. proc_exit (on halt) surfaces as a resume error handled below.
    local co = coroutine.create(function() inst:call("_start") end)
    -- Resume the engine until it parks for stdin (or dies). On CC the compiled
    -- code also yields for the watchdog (os.pullEvent via __tick); those yields
    -- carry an event filter, not PARK — forward them to CC's scheduler and resume.
    local function pump()
      local args = {}
      while true do
        local res = { coroutine.resume(co, (table.unpack or unpack)(args)) }
        if coroutine.status(co) == "dead" then
          S._dead = true
          if not res[1] and not (type(res[2]) == "table" and res[2][wasmcraft.wasi.EXIT]) then
            error("picat session error: " .. tostring(res[2]))
          end
          return
        end
        if not res[1] then error("picat session error: " .. tostring(res[2])) end
        if res[2] == PARK then return end                  -- waiting for next input
        args = { os.pullEventRaw(res[2]) }                 -- forward a CC event yield
      end
    end
    S._feed = function(line)
      inbuf, inpos = line, 1
      for i = #out, 1, -1 do out[i] = nil end
      pump()
      return table.concat(out)
    end
    S._dead = false
    pump() -- boot to the first prompt (banner discarded)
  end
  boot()

  -- run a Picat program string; returns ONLY its own stdout (REPL noise stripped).
  -- The interactive REPL echoes the command line, so the markers are built with
  -- Picat string-concat (++) — the literal <WCSTART>/<WCEND> then appears only in
  -- the program's actual output, never in the echoed command.
  function S:run(program, name)
    if S._dead then boot() end
    name = name or "_sess.pi"; hostfs.write(name, program)
    local raw = S._feed('cl("' .. name .. '"), print("<WCST"++"ART>"), ' ..
      'catch((main->true;true),E,printf("ERR %w",E)), print("<WCE"++"ND>").\n')
    local a = raw:find(START, 1, true)
    local b = raw:find(ENDT, 1, true)
    if a and b then return (raw:sub(a + #START, b - 1):gsub("^\n", "")) end
    return raw -- compile error etc. — hand back the raw REPL output
  end

  -- run a raw Picat goal/query (e.g. "X=2+3, println(X).")
  function S:query(goal) if S._dead then boot() end return S._feed(goal .. "\n") end
  -- discard this engine and boot a fresh one (clears all loaded/asserted state)
  function S:reset() pcall(function() S._feed("halt.\n") end); boot() end
  function S:close() pcall(function() S._feed("halt.\n") end); S._dead = true end
  return S
end

return M
