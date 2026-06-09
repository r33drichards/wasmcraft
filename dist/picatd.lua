-- picatd — a resident multi-session Picat daemon. Serves named sessions over
-- rednet: each session is its own warm Picat engine with its own request queue,
-- and sessions time-slice against each other (one session's long run doesn't
-- block another's). Boot is paid once per session, not per command.
--   Usage: picatd [name]     (name defaults to the computer label, else "picat")
-- Talk to it with the `pic` client, or any rednet message on protocol "wcpicat":
--   { action="run",   program="main => ...", session="foo", id="x1" }
--   { action="query", goal="X=2+3, println(X).", session="foo", id="x2" }
--   { action="reset", session="foo" }      -> fresh engine for THAT session
--   { action="ping" }                      -> daemon name + live session list
-- Replies: { ok=bool, output=str, id=<echoed> }; interim { status="..."} notes
-- (booting / queued at position N) are sent while a job waits. session defaults
-- to "main", which is pre-booted and warmed at startup.
local BUNDLE_URL   = "https://paste-production.up.railway.app/wasmcraft-bundle"
local PICATLIB_URL = "https://paste-production.up.railway.app/wc-picat.lua"
local PROTO = "wcpicat"

local function ensure(file, url)
  if type(fs) == "table" and fs.open and not fs.exists(file) then
    io.write("fetching " .. file .. " ... ")
    local r = assert(http.get(url), "http.get failed: " .. url)
    local h = fs.open(file, "wb"); h.write(r.readAll()); h.close(); r.close(); print("ok")
  end
end
local function find(c) for _, p in ipairs(c) do local f = io.open(p, "rb"); if f then f:close(); return p end end end

ensure("wasmcraft", BUNDLE_URL); ensure("picat.lua", PICATLIB_URL)
local function load_lib()
  return assert(loadfile(find({ "picat.lua", "dist/picat.lua" }) or error("picat.lua missing")))()
end
local picat = load_lib()
-- self-heal: ensure() keeps pre-existing files, so an old picat.lua/wasmcraft
-- (without session support) may have been loaded. Refresh both and reload.
if not picat.session and type(fs) == "table" then
  print("picatd: picat.lua/wasmcraft out of date - refreshing...")
  for f, u in pairs({ ["picat.lua"] = PICATLIB_URL, ["wasmcraft"] = BUNDLE_URL }) do
    if fs.exists(f) then fs.delete(f) end
    ensure(f, u)
  end
  picat = load_lib()
end
assert(picat.session, "picat.lua still lacks session() after refresh")
picat.modulePath = find({ "disk/picat.wasm", "picat.wasm", "wasm/picat.wasm",
  "/Users/robertwendt/picat-cc/third_party/picat/emu/picat.wasm" }) or "disk/picat.wasm"

local args = { ... }
-- picatd --install [name]: run on every boot via startup.lua. A daemon computer
-- reboots when its chunk unloads or the server restarts, which kills the daemon
-- and drops its rednet hostname; installing makes it come back by itself.
if args[1] == "--install" and type(fs) == "table" then
  local h = fs.open("startup.lua", "w")
  h.write('shell.run("picatd"' .. (args[2] and (', "' .. args[2] .. '"') or "") .. ')\n')
  h.close()
  print("picatd: installed to startup.lua — will start on every boot.")
  print("picatd: starting now...")
  table.remove(args, 1)
end
local name = args[1]
if not name and os and os.getComputerLabel then name = os.getComputerLabel() end
name = name or "picat"

-- open every modem so rednet can host/serve
local served = false
if type(peripheral) == "table" and peripheral.find then
  peripheral.find("modem", function(n) rednet.open(n); served = true end)
end

-- ---- multi-session control plane -------------------------------------------
-- Each named session (pic -n foo) gets its OWN Picat engine and its OWN request
-- queue, run by its own worker coroutine. The compiled engines yield to the
-- event loop at loop back-edges, so two sessions' long runs genuinely time-slice
-- against each other instead of head-of-line blocking. Within a session,
-- requests run in order. The shared chunk cache means extra sessions boot
-- without re-compiling any wasm functions (they only re-execute the bootstrap).
local sessions = {} -- sname -> { queue = {jobs}, s = engine|nil, busy = bool }
local tasks = {}    -- scheduler coroutines
local function spawn(fn) tasks[#tasks + 1] = { co = coroutine.create(fn) } end

local function respond(sender, reply, id)
  reply.id = id
  if sender then rednet.send(sender, reply, PROTO) end
end

local function handle(sess, msg, sname)
  if msg.action == "reset" then sess.s:reset(); return { ok = true, output = "reset" }
  elseif msg.action == "run" then
    -- per-session temp file: sessions share the fs root, and interleaved runs
    -- must not clobber each other's program file
    local ok, out = pcall(function() return sess.s:run(msg.program or "", "_sess_" .. sname .. ".pi") end)
    return { ok = ok, output = ok and out or tostring(out) }
  elseif msg.action == "query" then
    local ok, out = pcall(function() return sess.s:query(msg.goal or "") end)
    return { ok = ok, output = ok and out or tostring(out) }
  end
  return { ok = false, output = "unknown action: " .. tostring(msg.action) }
end

local function worker(sname, sess)
  return function()
    while true do
      if #sess.queue == 0 then
        os.pullEvent("wcpicat_work")
      else
        local job = table.remove(sess.queue, 1)
        if not sess.s then
          print("picatd: booting session '" .. sname .. "'...")
          sess.s = picat.session({ root = "." })
          print("picatd: session '" .. sname .. "' ready.")
        end
        if job.sender then
          print(("[%s] %s from %s started"):format(sname, tostring(job.msg.action), tostring(job.sender)))
        end
        sess.busy = true
        local reply = handle(sess, job.msg, sname)
        sess.busy = false
        respond(job.sender, reply, job.msg.id)
        if job.sender then
          print(("[%s] %s from %s -> %s%s"):format(sname, tostring(job.msg.action),
            tostring(job.sender), reply.ok and "ok" or "err",
            #sess.queue > 0 and (" (" .. #sess.queue .. " queued)") or ""))
        end
      end
    end
  end
end

local function getsession(sname)
  local sess = sessions[sname]
  if not sess then
    sess = { queue = {}, busy = false }
    sessions[sname] = sess
    spawn(worker(sname, sess))
  end
  return sess
end

local function receiver()
  while true do
    local sender, msg = rednet.receive(PROTO)
    if type(msg) == "table" and msg.action == "ping" then
      local names = {}
      for sn in pairs(sessions) do names[#names + 1] = sn end
      respond(sender, { ok = true, output = name .. " sessions: " .. table.concat(names, ",") }, msg.id)
    elseif type(msg) == "table" then
      local sname = tostring(msg.session or "main"):gsub("[^%w_%-]", "_")
      local sess = getsession(sname)
      -- a client that rebooted (chunk unload) or was Ctrl+T'd re-sends its job;
      -- its OLD queued job will never be awaited — drop it so the queue doesn't
      -- fill with orphans. (A job already RUNNING can't be stopped; it finishes
      -- and its reply goes nowhere, which is harmless.)
      for i = #sess.queue, 1, -1 do
        if sess.queue[i].sender == sender then
          table.remove(sess.queue, i)
          print(("[%s] dropped stale queued job from %s (client re-sent)"):format(sname, tostring(sender)))
        end
      end
      sess.queue[#sess.queue + 1] = { sender = sender, msg = msg }
      local note
      if not sess.s then note = "booting session '" .. sname .. "' (~30-60s)"
      elseif sess.busy or #sess.queue > 1 then note = "queued at position " .. #sess.queue end
      if note then respond(sender, { ok = true, status = note }, msg.id) end
      os.queueEvent("wcpicat_work")
    else
      respond(sender, { ok = false, output = "bad request" }, nil)
    end
  end
end

if not served then
  print("picatd: no modem attached — attach one and restart to serve over rednet.")
  return
end
rednet.host(PROTO, name)
print("picatd: serving as '" .. name .. "' on protocol '" .. PROTO .. "'.")

-- warm the default session before serving: boot + a throwaway run so the first
-- real command (and every later session, via the shared chunk cache) is fast.
print("picatd: booting session 'main' (~30-60s)...")
local mainsess = getsession("main")
mainsess.s = picat.session({ root = "." })
pcall(function() mainsess.s:run('main => println(warm).') end)
print("picatd: ready.")

-- ---- scheduler: like parallel, but coroutines can be added at runtime -------
spawn(receiver)
local ev = {}
while true do
  for i = #tasks, 1, -1 do
    local t = tasks[i]
    if t.filter == nil or t.filter == ev[1] or ev[1] == "terminate" then
      local ok, f = coroutine.resume(t.co, (table.unpack or unpack)(ev))
      if not ok then
        print("picatd: task error: " .. tostring(f))
        table.remove(tasks, i)
      elseif coroutine.status(t.co) == "dead" then
        table.remove(tasks, i)
      else
        t.filter = f
      end
    end
  end
  ev = { os.pullEventRaw() }
  if ev[1] == "terminate" then print("picatd: stopped.") return end
end
