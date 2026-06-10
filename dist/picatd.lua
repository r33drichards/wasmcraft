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
local BUNDLE_URL   = "https://github.com/r33drichards/wasmcraft/releases/latest/download/wasmcraft.lua"
local PICATLIB_URL = "https://github.com/r33drichards/wasmcraft/releases/latest/download/picat.lua"
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
local ENGINE_VERSION = 3
local picat = load_lib()
-- self-heal: ensure() keeps pre-existing files, so an old picat.lua/wasmcraft
-- (without session support, or an outdated engine) may load. Refresh + reload.
local function stale(p)
  return not p.session or ((p._engine and p._engine.version or 0) < ENGINE_VERSION)
end
if stale(picat) and type(fs) == "table" then
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
local sessions = {} -- sname -> { queue, s = engine|nil, busy, state, current, done, task }
local tasks = {}    -- scheduler coroutines
local started_at = os.clock()
local total_jobs = 0
local function spawn(fn)
  local t = { co = coroutine.create(fn) }
  tasks[#tasks + 1] = t
  return t
end

-- log to the terminal AND a ring buffer the monitor dashboard shows
local LOG, LOGMAX = {}, 40
local function dlog(msg)
  print(msg)
  LOG[#LOG + 1] = msg
  if #LOG > LOGMAX then table.remove(LOG, 1) end
end

local function respond(sender, reply, id)
  reply.id = id
  if sender then rednet.send(sender, reply, PROTO) end
end

-- benchmark: one full end-to-end Picat run (engine boot + fib(N)) in the given
-- engine mode, timed here on the daemon so rednet/queue latency isn't counted.
-- Used by the picbench client; runs as a normal queued job on its session.
local benchmod
local function run_bench(mode, n)
  local wc = assert(picat._engine, "picat lib lacks _engine")
  if not benchmod then
    local f = assert(io.open(picat.modulePath, "rb")); local b = f:read("*a"); f:close()
    benchmod = wc.load(b)
  end
  if mode == "jit" and wc.can_jit and not wc.can_jit() then
    return "jit unavailable: this CC build refuses to load Lua bytecode (CC:T >= 1.109?)"
  end
  local prog = ("main => printf(\"fib(%d)=%%w\\n\", fib(%d)).\n"):format(n, n) ..
    "table\nfib(0)=0.\nfib(1)=1.\nfib(F)=R, F>1 => R=fib(F-1)+fib(F-2).\n"
  local hostfs = wc.hostfs and wc.hostfs(".") or wc.wasi.io_hostfs(".")
  hostfs.write("_bench.pi", prog)
  local out = {}
  local host = wc.wasi.make({
    fs = hostfs, root = ".", args = { "picat", "_bench.pi" },
    write = function(s) out[#out + 1] = s end, writeerr = function(s) out[#out + 1] = s end,
  })
  local inst = wc.instantiate(benchmod, { wasi_snapshot_preview1 = host }, { mode = mode })
  local t0 = os.clock()
  local ok, err = pcall(function() inst:call("_start") end)
  local dt = os.clock() - t0
  pcall(function() hostfs.unlink("_bench.pi") end)
  if not ok and not (type(err) == "table" and err[(wc.wasi).EXIT]) then
    error(mode .. " run failed: " .. tostring(err))
  end
  local answer = table.concat(out):match("fib%(%d+%)=%d+") or "?"
  return ("%s in %.1fs [%s]"):format(answer, dt, mode), dt
end

local function handle(sess, msg, sname)
  if msg.action == "reset" then sess.s:reset(); return { ok = true, output = "reset" }
  elseif msg.action == "bench" then
    local ok, out, dt = pcall(run_bench, msg.mode or "jit", tonumber(msg.n) or 10)
    return { ok = ok, output = ok and out or tostring(out), took = dt }
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
        sess.state = sess.s and "idle" or "empty"
        os.pullEvent("wcpicat_work")
      else
        local job = table.remove(sess.queue, 1)
        if not sess.s and job.msg.action ~= "bench" then -- bench builds its own engines
          sess.state = "booting"
          dlog("picatd: booting session '" .. sname .. "'...")
          sess.s = picat.session({ root = "." })
          dlog("picatd: session '" .. sname .. "' ready.")
        end
        if job.sender then
          dlog(("[%s] %s from %s started"):format(sname, tostring(job.msg.action), tostring(job.sender)))
        end
        sess.busy = true
        sess.state = "busy"
        sess.current = { action = job.msg.action, sender = job.sender, id = job.msg.id, started = os.clock() }
        local reply = handle(sess, job.msg, sname)
        local took = os.clock() - sess.current.started
        sess.busy = false
        sess.current = nil
        sess.done = (sess.done or 0) + 1
        total_jobs = total_jobs + 1
        respond(job.sender, reply, job.msg.id)
        if job.sender then
          dlog(("[%s] %s from %s -> %s in %ds%s"):format(sname, tostring(job.msg.action),
            tostring(job.sender), reply.ok and "ok" or "err", took,
            #sess.queue > 0 and (" (" .. #sess.queue .. " queued)") or ""))
        else
          dlog(("picatd: session '%s' warmed (%ds) - ready."):format(sname, took))
        end
      end
    end
  end
end

local function getsession(sname)
  local sess = sessions[sname]
  if not sess then
    sess = { queue = {}, busy = false, state = "empty", done = 0 }
    sessions[sname] = sess
    sess.task = spawn(worker(sname, sess))
  end
  return sess
end

-- Cancel everything on a session. A RUNNING job can't be interrupted
-- mid-instruction, so we abandon the session's worker coroutine (the engine
-- with it) and respawn fresh: the job dies, the session's Picat state is lost,
-- and the next job boots a new engine (fast-ish via the shared chunk cache).
local function cancel_session(sname, why)
  local sess = sessions[sname]
  if not sess then return false, "no session '" .. tostring(sname) .. "'" end
  local n = 0
  for i = #sess.queue, 1, -1 do
    local j = table.remove(sess.queue, i)
    respond(j.sender, { ok = false, output = "cancelled (" .. why .. ")" }, j.msg.id)
    n = n + 1
  end
  local had_running = sess.busy and sess.current
  if had_running then
    respond(sess.current.sender, { ok = false, output = "cancelled (" .. why .. ")" }, sess.current.id)
    n = n + 1
  end
  if sess.task then sess.task.dead = true end
  sess.s, sess.busy, sess.current, sess.state = nil, false, nil, "empty"
  sess.task = spawn(worker(sname, sess))
  dlog(("[%s] CANCELLED %d job(s) via %s%s"):format(sname, n, why,
    had_running and " (engine reset - session state lost)" or ""))
  return true, ("cancelled %d job(s) on '%s'"):format(n, sname)
end

-- one-line status per session (used by the dashboard and pic --jobs)
local function status_lines()
  local lines = {}
  local names = {}
  for sn in pairs(sessions) do names[#names + 1] = sn end
  table.sort(names)
  for _, sn in ipairs(names) do
    local s = sessions[sn]
    local d = s.state or "?"
    if s.state == "busy" and s.current then
      d = ("busy %ds on %s from %s"):format(os.clock() - s.current.started,
        tostring(s.current.action), tostring(s.current.sender))
    end
    lines[#lines + 1] = ("%s: %s | %d done | %d queued"):format(sn, d, s.done or 0, #s.queue)
  end
  return lines
end

local function receiver()
  while true do
    local sender, msg = rednet.receive(PROTO)
    if type(msg) ~= "table" then
      respond(sender, { ok = false, output = "bad request" }, nil)
    elseif msg.action == "ping" then
      local names = {}
      for sn in pairs(sessions) do names[#names + 1] = sn end
      respond(sender, { ok = true, output = name .. " sessions: " .. table.concat(names, ",") }, msg.id)
    elseif msg.action == "status" then
      -- answered instantly by the receiver, never queued
      local up = os.clock() - started_at
      local out = ("%s up %dm%02ds, %d jobs served\n"):format(name, up / 60, up % 60, total_jobs)
        .. table.concat(status_lines(), "\n")
      respond(sender, { ok = true, output = out }, msg.id)
    elseif msg.action == "cancel" then
      local sname = tostring(msg.session or "main"):gsub("[^%w_%-]", "_")
      local ok, out = cancel_session(sname, "pic from #" .. tostring(sender))
      respond(sender, { ok = ok, output = out }, msg.id)
    else
      local sname = tostring(msg.session or "main"):gsub("[^%w_%-]", "_")
      local sess = getsession(sname)
      -- a client that rebooted (chunk unload) or was Ctrl+T'd re-sends its job;
      -- its OLD queued job will never be awaited — drop it so the queue doesn't
      -- fill with orphans. (A RUNNING job is only stopped by an explicit cancel.)
      for i = #sess.queue, 1, -1 do
        if sess.queue[i].sender == sender then
          table.remove(sess.queue, i)
          dlog(("[%s] dropped stale queued job from %s (client re-sent)"):format(sname, tostring(sender)))
        end
      end
      sess.queue[#sess.queue + 1] = { sender = sender, msg = msg }
      local note
      if not sess.s then note = "booting session '" .. sname .. "' (~30-60s)"
      elseif sess.busy or #sess.queue > 1 then note = "queued at position " .. #sess.queue end
      if note then respond(sender, { ok = true, status = note }, msg.id) end
      os.queueEvent("wcpicat_work")
    end
  end
end

-- ---- monitor dashboard: live job/session view + touch-to-cancel -------------
-- Re-renders every second. On an Advanced (gold) monitor, each session row has
-- a red [CANCEL] button; touching it cancels that session's jobs.
local function dashboard(mon)
  local C = colors or colours
  pcall(function() mon.setTextScale(0.5) end)
  local function render()
    local W, H = mon.getSize()
    local buttons = {}
    mon.setBackgroundColor(C.black); mon.clear()
    local up = os.clock() - started_at
    mon.setCursorPos(1, 1); mon.setTextColor(C.yellow)
    mon.write(("picatd '%s'  up %dm%02ds  jobs %d"):format(name, up / 60, up % 60, total_jobs))
    local y = 3
    local names = {}
    for sn in pairs(sessions) do names[#names + 1] = sn end
    table.sort(names)
    for _, sn in ipairs(names) do
      if y >= H - 1 then break end
      local s = sessions[sn]
      mon.setCursorPos(1, y)
      if s.state == "busy" then mon.setTextColor(C.lime)
      elseif s.state == "booting" then mon.setTextColor(C.orange)
      else mon.setTextColor(C.lightGray) end
      local desc = s.state or "?"
      if s.state == "busy" and s.current then
        desc = ("busy %ds <- #%s"):format(os.clock() - s.current.started, tostring(s.current.sender))
      end
      local label = ("%-8s %s  q%d d%d"):format(sn:sub(1, 8), desc, #s.queue, s.done or 0)
      mon.write(label:sub(1, W - 9))
      if s.state == "busy" or s.state == "booting" or #s.queue > 0 then
        local bx = W - 7
        mon.setCursorPos(bx, y); mon.setBackgroundColor(C.red); mon.setTextColor(C.white)
        mon.write("[CANCEL]")
        mon.setBackgroundColor(C.black)
        buttons[#buttons + 1] = { y = y, x1 = bx, x2 = W, sname = sn }
      end
      y = y + 1
    end
    -- recent log lines fill the rest
    y = y + 1
    if y < H then
      mon.setCursorPos(1, y); mon.setTextColor(C.gray); mon.write(string.rep("-", W))
      local avail = H - y
      mon.setTextColor(C.white)
      for i = math.max(1, #LOG - avail + 1), #LOG do
        y = y + 1
        mon.setCursorPos(1, y); mon.write(LOG[i]:sub(1, W))
      end
    end
    return buttons
  end
  local buttons = render()
  local timer = os.startTimer(1)
  while true do
    local ev, p1, p2, p3 = os.pullEvent()
    if ev == "timer" and p1 == timer then
      buttons = render()
      timer = os.startTimer(1)
    elseif ev == "monitor_touch" then
      for _, b in ipairs(buttons) do
        if p3 == b.y and p2 >= b.x1 and p2 <= b.x2 then
          cancel_session(b.sname, "monitor touch")
        end
      end
      buttons = render()
    end
  end
end

if not served then
  print("picatd: no modem attached — attach one and restart to serve over rednet.")
  return
end
rednet.host(PROTO, name)
print("picatd: serving as '" .. name .. "' on protocol '" .. PROTO .. "'.")

-- ---- scheduler: like parallel, but coroutines can be added at runtime -------
-- The receiver starts FIRST, then 'main' warms up as a normal (self-queued)
-- job: requests arriving during the warm-up are queued instead of silently
-- dropped (the bios answers lookups before the receiver runs, so clients can
-- find the daemon while it's still warming).
spawn(receiver)
dlog("picatd: accepting requests; warming session 'main' (~30-60s)...")
do
  local mainsess = getsession("main")
  mainsess.queue[#mainsess.queue + 1] = { sender = nil, msg = { action = "run", program = "main => println(warm)." } }
  os.queueEvent("wcpicat_work")
end
local mon = peripheral.find and peripheral.find("monitor")
if mon then
  dlog("picatd: monitor found - dashboard on (touch a [CANCEL] to kill a session's jobs)")
  spawn(function() dashboard(mon) end)
else
  dlog("picatd: no monitor attached (attach one + restart for the dashboard)")
end
local ev = {}
while true do
  for i = #tasks, 1, -1 do
    local t = tasks[i]
    if t.dead then
      table.remove(tasks, i)
    elseif t.filter == nil or t.filter == ev[1] or ev[1] == "terminate" then
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
