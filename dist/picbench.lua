-- picbench — benchmark a picatd daemon FROM ANY computer on the network:
-- the daemon runs the same Picat fib(N) program end-to-end (engine boot + solve)
-- through the tree-walking INTERPRETER and through the wasm->Lua-bytecode
-- COMPILER (jit), times each on its own clock (rednet latency excluded), and
-- this client reports both + the speedup. Jobs queue on the daemon's 'main'
-- session, so a busy daemon finishes its current work first.
--   Usage: picbench [daemon] [N] [mode]   (default: first daemon, fib(10), jit)
-- mode = the compiled leg (jit|transpile|auto), always compared vs interp.
-- jit is STRICT: on a CC build that refuses bytecode it FAILS LOUDLY - rerun
-- with mode transpile there.
-- NOTE: the interpreted leg can take MANY minutes in-game. That gap is the result.
local PROTO = "wcpicat"
local args = { ... }
local daemon_name = args[1]
if tonumber(args[1]) then table.insert(args, 1, false); daemon_name = nil end
local N = tonumber(args[2]) or 10
local CMODE = args[3] or "jit"

local opened = false
if type(peripheral) == "table" and peripheral.find then
  peripheral.find("modem", function(n) rednet.open(n); opened = true end)
end
if not opened then print("picbench: no modem attached."); return end

-- find the daemon: cached id first (busy daemons answer dns too slowly), then lookup
local function fread(p) local f = io.open(p, "r"); if not f then return nil end local d = f:read("*a"); f:close(); return d end
local id
local cached = tonumber(fread(".pic_daemon_" .. (daemon_name or "any")) or "")
if cached then
  local pid = "bench:ping:" .. tostring(os.epoch and os.epoch("utc") or os.clock())
  rednet.send(cached, { action = "ping", id = pid }, PROTO)
  local t = os.clock()
  while os.clock() - t < 15 do
    local s, r = rednet.receive(PROTO, 15 - (os.clock() - t))
    if s == cached and type(r) == "table" and r.id == pid then id = cached; break end
  end
end
if not id then
  for attempt = 1, 4 do
    if daemon_name then id = rednet.lookup(PROTO, daemon_name, 5)
    else local hosts = { rednet.lookup(PROTO, nil, 5) }; id = hosts[1] end
    if id then break end
    print("(no picatd answered lookup " .. attempt .. "/4)")
  end
end
if not id then print("picbench: no picatd daemon reachable."); return end
local h = io.open(".pic_daemon_" .. (daemon_name or "any"), "w")
if h then h:write(tostring(id)); h:close() end
print("benchmarking on picatd #" .. id .. " (fib(" .. N .. "), jobs run on its 'main' session)")

local reqn = 0
local function bench(mode, patience)
  reqn = reqn + 1
  local mid = "bench:" .. tostring(os.getComputerID and os.getComputerID() or 0) .. ":" .. reqn
  rednet.send(id, { action = "bench", mode = mode, n = N, id = mid }, PROTO)
  local t0 = os.clock()
  local deadline, lastpoll, statid = t0 + 300, t0, nil
  local hard = t0 + (patience or 1800)
  while os.clock() < deadline and os.clock() < hard do
    local s, r = rednet.receive(PROTO, 5)
    if s == nil then
      if os.clock() - lastpoll >= 30 then
        lastpoll = os.clock()
        statid = mid .. ":st" .. math.floor(lastpoll)
        rednet.send(id, { action = "status", id = statid }, PROTO)
      end
    elseif s == id and type(r) == "table" and r.id == statid then
      local line = tostring(r.output or ""):match("main:[^\n]*") or "status ok"
      print(("(daemon alive: %s) [%ds]"):format(line, os.clock() - t0))
      if line:find("busy") or line:find("booting") or (tonumber(line:match("(%d+) queued")) or 0) > 0 then
        deadline = os.clock() + 300
      end
    elseif s == id and type(r) == "table" and r.id == mid then
      if r.status then print("(" .. tostring(r.status) .. ")"); deadline = os.clock() + 300
      elseif r.ok then return r.took, r.output
      else
        print(mode .. " FAILED: " .. tostring(r.output))
        if tostring(r.output):find("jit unavailable") then
          print("")
          print("this server refuses Lua bytecode; benchmark the transpiler instead:")
          print("  picbench " .. (daemon_name or "") .. " " .. N .. " transpile")
          error("jit unavailable here", 0)
        end
        if tostring(r.output):find("unknown action") then
          print("")
          print("this daemon runs an OLD picatd without the bench action. On it:")
          print("  rm picatd")
          print("  wget https://github.com/r33drichards/wasmcraft/releases/latest/download/picatd.lua picatd")
          print("  reboot")
          error("daemon outdated", 0)
        end
        return nil
      end
    end
  end
  print(mode .. " timed out"); return nil
end

print(("\n-- fib(%d), compiled (%s) --"):format(N, CMODE))
local tj, oj = bench(CMODE, 1800)
if oj then print(oj) end

print(("\n-- fib(%d), interpreted -- (slow; the daemon's dashboard shows it busy)"):format(N))
local ti, oi = bench("interp", 3600)
if oi then print(oi) end

if tj and ti then
  print("\n==== results (daemon-measured, rednet excluded) ====")
  print(("interpreted : %8.1fs"):format(ti))
  print(("compiled    : %8.1fs"):format(tj))
  print(("speedup     : %8.1fx"):format(ti / tj))
  if oj and oj:find("%[interp%]") then
    print("NOTE: the compiled leg actually ran interpreted - the speedup above")
    print("is meaningless. Pick an explicit mode: picbench <daemon> <N> transpile")
  end
end
