-- planner — Picat's best_plan, two ways, side by side on a CC monitor, looping.
-- LEFT: visit goals IN ORDER.  RIGHT: visit them in ANY order (shortest).
-- Same goals; the planner picks the cheaper order on the right, so it's shorter.
-- (after Hillel Wayne's "Planner programming blows my mind")
--   Usage: planner [daemon]
-- Solves via a picatd daemon on the network when one is reachable (fast, warm,
-- and this computer needs NO picat.wasm) — else boots Picat locally (needs
-- picat.wasm, e.g. on a floppy at /disk/).
local BUNDLE_URL   = "https://paste-production.up.railway.app/wasmcraft-bundle"
local PICATLIB_URL = "https://paste-production.up.railway.app/wc-picat.lua"
-- Durability: 'planner --install' re-runs on every boot. A finished solve is
-- cached to .planner_result, so after a reboot (chunk unload) the animation
-- resumes instantly; an interrupted solve restarts FROM THE BEGINNING (there is
-- no mid-solve checkpoint) and says so. 'planner --fresh' discards the cache.
local PROTO = "wcpicat"
local args = { ... }
local fresh, install = false, false
for i = #args, 1, -1 do
  if args[i] == "--fresh" then fresh = true; table.remove(args, i)
  elseif args[i] == "--install" then install = true; table.remove(args, i) end
end

local STATE, RESULT = ".planner_state", ".planner_result"
local function fexists(p) local f = io.open(p, "r"); if f then f:close(); return true end return false end
local function fread(p) local f = io.open(p, "r"); if not f then return nil end local d = f:read("*a"); f:close(); return d end
local function fwrite(p, s) local f = assert(io.open(p, "w")); f:write(s); f:close() end
local function fdel(p)
  if type(fs) == "table" and fs.delete then pcall(fs.delete, p) else pcall(os.remove, p) end
end

if install and type(fs) == "table" then
  fwrite("startup.lua", 'shell.run("planner")\n')
  print("planner: installed to startup.lua - re-runs on every boot")
  print("planner: (cached solves re-render instantly; interrupted solves restart)")
end

-- ONE Picat program solves BOTH plans (mode carried in the planner state), so
-- Picat boots only once. Goals chosen so the in-order route is much longer.
local PROGRAM = [[
import planner.
main =>
  Origin={0,0}, Goals=[{4,4},{2,0},{0,3}],
  printf("BOUNDS 4 4\n"), printf("START 0 0\n"),
  foreach({Gx,Gy} in Goals) printf("GOAL %w %w\n",Gx,Gy) end,
  best_plan({Origin,Goals,ordered}, P1),
  printf("PLAN ordered\n"), printf("PATH 0 0\n"), walk(Origin,P1),
  best_plan({Origin,Goals,free}, P2),
  printf("PLAN free\n"), printf("PATH 0 0\n"), walk(Origin,P2).
final({_Pos,Gs,_}) => Gs=[].
action(F,T,A,C) ?=>
  F={{X,Y},Gs,M}, member({Dx,Dy},[{-1,0},{1,0},{0,-1},{0,1}]),
  Tx=X+Dx,Ty=Y+Dy, member(Tx,0..4),member(Ty,0..4),
  T={{Tx,Ty},Gs,M}, A={move,{Tx,Ty}}, C=1.
action(F,T,A,C) ?=> F={Pos,[Pos|Rest],ordered}, T={Pos,Rest,ordered}, A={mark,Pos}, C=1.
action(F,T,A,C) ?=> F={Pos,Gs,free}, member(Pos,Gs), T={Pos,delete(Gs,Pos),free}, A={mark,Pos}, C=1.
walk(_,[]) => true.
walk(_,[{move,{Tx,Ty}}|R]) => printf("PATH %w %w\n",Tx,Ty), walk({Tx,Ty},R).
walk(P,[{mark,_}|R]) => walk(P,R).
]]

-- ---- solve via a picatd daemon on the network (preferred: warm, no floppy) --
local function daemon_solve()
  if type(peripheral) ~= "table" or not peripheral.find or not rednet then return nil end
  local opened = false
  peripheral.find("modem", function(n) rednet.open(n); opened = true end)
  if not opened then
    print("(no modem attached - can't reach a picatd daemon)")
    return nil
  end
  -- a daemon that is mid-boot answers lookups slowly (it only processes events
  -- between engine yields), so a single 2s lookup can miss it: retry a few times
  local id
  for attempt = 1, 4 do
    if args[1] then id = rednet.lookup(PROTO, args[1])
    else local hosts = { rednet.lookup(PROTO) }; id = hosts[1] end
    if id then break end
    print("(no picatd answered lookup " .. attempt .. "/4 - daemon may still be booting)")
  end
  if not id then return nil end
  local mid = "planner:" .. tostring(os.getComputerID and os.getComputerID() or 0) ..
    ":" .. tostring(os.epoch and os.epoch("utc") or os.clock())
  print("solving on picatd #" .. id .. " (session 'planner', job " .. mid:sub(1, 24) .. ")")
  rednet.send(id, { action = "run", program = PROGRAM, session = "planner", id = mid }, PROTO)
  -- LIVENESS-BASED deadline: a long solve is fine as long as status polls show
  -- the daemon working. We only give up when the daemon stops answering, or it
  -- goes idle without our reply twice (job lost, e.g. daemon rebooted) — in
  -- which case the job is re-sent once. Hard cap 30 min.
  local t0 = os.clock()
  local lastbeat, lastpoll, statid = t0, t0, nil
  local deadline, hard = t0 + 240, t0 + 1800
  local last_status_reply = t0
  local idle_polls, resent = 0, false
  while os.clock() < deadline and os.clock() < hard do
    local _, r = rednet.receive(PROTO, 5)
    local now = os.clock()
    if r == nil then
      if now - lastpoll >= 30 then
        lastpoll = now
        statid = mid .. ":st" .. math.floor(now)
        rednet.send(id, { action = "status", id = statid }, PROTO)
      elseif now - lastbeat >= 15 then
        lastbeat = now
        print(("(still waiting on daemon... %ds elapsed)"):format(now - t0))
      end
      if now - last_status_reply > 90 and now - t0 > 90 then
        print("(daemon stopped answering status polls - it is gone)")
        break
      end
    elseif type(r) == "table" and r.id == statid then
      last_status_reply = now
      local line = tostring(r.output or ""):match("planner:[^\n]*") or "status ok"
      print(("(daemon alive: %s) [%ds]"):format(line, now - t0))
      local queued = tonumber(line:match("(%d+) queued")) or 0
      if line:find("busy") or line:find("booting") or queued > 0 then
        idle_polls = 0
        deadline = now + 240 -- actively working: keep waiting
      else
        idle_polls = idle_polls + 1
        if idle_polls >= 2 then
          if not resent then
            resent, idle_polls = true, 0
            print("(daemon idle but our reply never came - job lost; re-sending it)")
            rednet.send(id, { action = "run", program = PROGRAM, session = "planner", id = mid }, PROTO)
            deadline = now + 240
          else
            print("(job lost twice - giving up on the daemon)")
            break
          end
        end
      end
    elseif type(r) == "table" and (r.id == mid or r.id == nil) then
      if r.status then
        print(("(daemon: %s) [%ds]"):format(tostring(r.status), now - t0))
        deadline = now + 240
      elseif r.ok then
        print(("(daemon answered in %ds)"):format(now - t0))
        return r.output
      else print("daemon error: " .. tostring(r.output)); return nil end
    end
  end
  print("(giving up on the daemon - trying a local boot instead)")
  return nil
end

-- ---- fallback: boot Picat on THIS computer (needs picat.wasm) ---------------
local function ensure(file, url)
  if type(fs) == "table" and fs.open and not fs.exists(file) then
    io.write("fetching " .. file .. " ... ")
    local r = assert(http.get(url), "http.get failed: " .. url)
    local h = fs.open(file, "wb"); h.write(r.readAll()); h.close(); r.close(); print("ok")
  end
end
local function find(c) for _, p in ipairs(c) do local f = io.open(p, "rb"); if f then f:close(); return p end end end
local function local_solve()
  ensure("wasmcraft", BUNDLE_URL); ensure("picat.lua", PICATLIB_URL)
  local picat = assert(loadfile(find({ "picat.lua", "dist/picat.lua" }) or error("picat.lua missing")))()
  local wasmpath = find({ "disk/picat.wasm", "picat.wasm", "wasm/picat.wasm",
    "/Users/robertwendt/picat-cc/third_party/picat/emu/picat.wasm" })
  if not wasmpath then
    print("No picatd daemon on the network AND no local picat.wasm.")
    print("Either start a daemon somewhere ('picatd --install' on a computer with")
    print("the engine), or put picat.wasm (https://tinyurl.com/2cladfgs) on a")
    print("floppy here (/disk/picat.wasm).")
    error("no way to run Picat", 0)
  end
  picat.modulePath = wasmpath
  print("booting Picat locally + solving both plans (~30-60s)...")
  return picat.run(PROGRAM, { root = "." })
end

-- one combined run -> shared grid + two paths (ordered, free)
local function parse_both(out)
  local bounds, start, goals, gset = { x = 4, y = 4 }, { x = 0, y = 0 }, {}, {}
  local pathO, pathF, cur = {}, {}, nil
  for line in out:gmatch("[^\n]+") do
    if line == "PLAN ordered" then cur = pathO
    elseif line == "PLAN free" then cur = pathF
    else
      local k, a, b = line:match("(%u+)%s+(%-?%d+)%s+(%-?%d+)")
      if k == "BOUNDS" then bounds = { x = tonumber(a), y = tonumber(b) }
      elseif k == "START" then start = { x = tonumber(a), y = tonumber(b) }
      elseif k == "GOAL" then goals[#goals + 1] = { x = tonumber(a), y = tonumber(b) }; gset[a .. "," .. b] = true
      elseif k == "PATH" and cur then cur[#cur + 1] = { x = tonumber(a), y = tonumber(b) } end
    end
  end
  local function plan(path) return { bounds = bounds, start = start, goals = goals, gset = gset, path = path } end
  return plan(pathO), plan(pathF)
end

-- ---- durable solve: cache results, restart interrupted solves ---------------
if fresh then fdel(RESULT); fdel(STATE); print("planner: --fresh, discarded cached solution") end
local out = fread(RESULT)
if out and #out > 0 then
  print("planner: using cached solution from a previous run ('planner --fresh' re-solves)")
else
  if fexists(STATE) then
    local attempt = (tonumber(fread(STATE)) or 1) + 1
    print("planner: previous solve did NOT complete (reboot/chunk unload or error)")
    print("planner: restarting from the beginning (attempt " .. attempt .. ") - no mid-solve checkpoint")
    fwrite(STATE, tostring(attempt))
  else
    fwrite(STATE, "1")
  end
  out = daemon_solve() or local_solve()
  fwrite(RESULT, out)
  fdel(STATE)
  print("planner: solution cached to " .. RESULT)
end
local A, B = parse_both(out)
if #A.path == 0 or #B.path == 0 then
  print("could not parse plans; raw output:"); print(out)
  fdel(RESULT) -- don't cache garbage
  return
end
print(string.format("in order: %d moves   shortest: %d moves", #A.path - 1, #B.path - 1))

-- a short problem/solution blurb shown under the grids (<=3 sentences)
local BLURB = string.format(
  "Goal: from S, visit every goal G in the fewest steps. Left visits the goals " ..
  "in the order given (%d moves); right lets Picat's planner pick the order (%d). " ..
  "Same goals, but choosing the order finds the shorter route.", #A.path - 1, #B.path - 1)

local function wrap(text, width)
  local out, line = {}, ""
  for word in text:gmatch("%S+") do
    if #line + #word + 1 > width then out[#out + 1] = line; line = word
    elseif line == "" then line = word else line = line .. " " .. word end
  end
  if line ~= "" then out[#out + 1] = line end
  return out
end

-- ---- monitor: two grids side by side, animation loops, blurb beneath --------
local function render_monitor(mon)
  local C = colors or colours
  local gw, gh = A.bounds.x + 1, A.bounds.y + 1
  -- one text scale serves the whole monitor, and it sizes the blurb text: use
  -- the LARGEST scale that still fits both grids (>=2 chars/cell) + the blurb
  local W, H, blurb
  for _, s in ipairs({ 3, 2.5, 2, 1.5, 1, 0.5 }) do
    mon.setTextScale(s)
    W, H = mon.getSize()
    blurb = wrap(BLURB, W)
    if W - 3 >= 2 * gw * 2 and H - 2 - #blurb >= gh * 2 then break end
  end
  local gridrows = H - 1 - #blurb - 1            -- title row + blurb (+gap) reserved
  local cw = math.max(1, math.floor((W - 3) / (2 * gw)))
  local ch = math.max(1, math.floor(gridrows / gh))
  local ox1, ox2, oy = 0, cw * gw + 3, 2
  local function fill(ox, gx, gy, bg, label, fg)
    local sx, sy = ox + gx * cw, oy + (A.bounds.y - gy) * ch
    mon.setBackgroundColor(bg)
    for r = 0, ch - 1 do mon.setCursorPos(sx + 1, sy + 1 + r); mon.write(string.rep(" ", cw)) end
    if label then mon.setTextColor(fg or C.white); mon.setCursorPos(sx + math.floor(cw / 2) + 1, sy + math.floor(ch / 2) + 1); mon.write(label) end
  end
  local function base(ox, p)
    for gy = 0, p.bounds.y do for gx = 0, p.bounds.x do fill(ox, gx, gy, C.gray) end end
    for _, g in ipairs(p.goals) do fill(ox, g.x, g.y, C.orange, "G", C.black) end
    fill(ox, p.start.x, p.start.y, C.lime, "S", C.black)
  end
  local function text(x, y, s, col) mon.setBackgroundColor(C.black); mon.setTextColor(col); mon.setCursorPos(x, y); mon.write(s) end
  while true do
    mon.setBackgroundColor(C.black); mon.clear()
    text(ox1 + 1, 1, "in order: " .. (#A.path - 1), C.yellow)
    text(ox2 + 1, 1, "shortest: " .. (#B.path - 1), C.lime)
    base(ox1, A); base(ox2, B)
    for i, l in ipairs(blurb) do text(1, H - #blurb + i, l, C.white) end
    -- paint a path cell, keeping the S/G labels visible when passing over them
    local function mark(ox, p, x, y, bg)
      local label, fg
      if x == p.start.x and y == p.start.y then label, fg = "S", C.black
      elseif p.gset[x .. "," .. y] then label, fg = "G", C.black end
      fill(ox, x, y, bg, label, fg)
    end
    for i = 1, math.max(#A.path, #B.path) do
      for _, pr in ipairs({ { ox1, A, C.yellow }, { ox2, B, C.cyan } }) do
        local ox, p, tc = pr[1], pr[2], pr[3]
        if i <= #p.path then
          if i > 1 then
            local v = p.path[i - 1]
            mark(ox, p, v.x, v.y, p.gset[v.x .. "," .. v.y] and C.red or tc)
          end
          mark(ox, p, p.path[i].x, p.path[i].y, C.white)
        end
      end
      if sleep then sleep(0.18) end
    end
    if sleep then sleep(1.2) end
  end
end

local function render_ascii(p, label)
  print(label .. ": " .. (#p.path - 1) .. " moves")
  local vis = {}; for _, q in ipairs(p.path) do vis[q.x .. "," .. q.y] = true end
  print("+" .. string.rep("-", p.bounds.x + 1) .. "+")
  for y = p.bounds.y, 0, -1 do
    local row = {}
    for x = 0, p.bounds.x do
      local c = vis[x .. "," .. y] and "*" or " "
      if p.gset[x .. "," .. y] then c = "G" end
      if x == p.start.x and y == p.start.y then c = "O" end
      row[#row + 1] = c
    end
    print("|" .. table.concat(row) .. "|")
  end
  print("+" .. string.rep("-", p.bounds.x + 1) .. "+")
end

local mon = (type(peripheral) == "table") and peripheral.find and peripheral.find("monitor")
if mon then
  print("monitor found — animating (hold Ctrl+T to stop).")
  render_monitor(mon)
else
  print("NO MONITOR — drawing to terminal (computer must touch the monitor to use it).")
  render_ascii(A, "in order"); render_ascii(B, "shortest")
  print(BLURB)
end
