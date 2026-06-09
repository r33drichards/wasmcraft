-- planner — Picat's best_plan, two ways, side by side on a CC monitor, looping.
-- LEFT: visit goals IN ORDER.  RIGHT: visit them in ANY order (shortest).
-- Same goals; the planner picks the cheaper order on the right, so it's shorter.
-- (after Hillel Wayne's "Planner programming blows my mind")
--   Usage: planner   (auto-finds picat.wasm on a floppy at /disk/)
local BUNDLE_URL   = "https://paste-production.up.railway.app/wasmcraft-bundle"
local PICATLIB_URL = "https://paste-production.up.railway.app/wc-picat.lua"

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

-- ---- bootstrap -------------------------------------------------------------
local function ensure(file, url)
  if type(fs) == "table" and fs.open and not fs.exists(file) then
    io.write("fetching " .. file .. " ... ")
    local r = assert(http.get(url), "http.get failed: " .. url)
    local h = fs.open(file, "wb"); h.write(r.readAll()); h.close(); r.close(); print("ok")
  end
end
local function find(c) for _, p in ipairs(c) do local f = io.open(p, "rb"); if f then f:close(); return p end end end
ensure("wasmcraft", BUNDLE_URL); ensure("picat.lua", PICATLIB_URL)
local picat = assert(loadfile(find({ "picat.lua", "dist/picat.lua" }) or error("picat.lua missing")))()
picat.modulePath = (({ ... })[1]) or find({ "disk/picat.wasm", "picat.wasm", "wasm/picat.wasm",
  "/Users/robertwendt/picat-cc/third_party/picat/emu/picat.wasm" }) or "disk/picat.wasm"

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

print("booting Picat + solving both plans (~30-60s, one boot)...")
local A, B = parse_both(picat.run(PROGRAM, { root = "." }))
print(string.format("in order: %d moves   shortest: %d moves", #A.path - 1, #B.path - 1))

-- cells each route visits that the OTHER does not -> these get bordered
local visA, visB = {}, {}
for _, q in ipairs(A.path) do visA[q.x .. "," .. q.y] = true end
for _, q in ipairs(B.path) do visB[q.x .. "," .. q.y] = true end
local function onlyA(x, y) return visA[x .. "," .. y] and not visB[x .. "," .. y] end
local function onlyB(x, y) return visB[x .. "," .. y] and not visA[x .. "," .. y] end

-- ---- monitor: two grids side by side, animation loops -----------------------
local function render_monitor(mon)
  local C = colors or colours
  mon.setTextScale(1)
  local W, H = mon.getSize()
  local gw, gh = A.bounds.x + 1, A.bounds.y + 1
  local cw = math.max(1, math.floor((W - 3) / (2 * gw)))
  local ch = math.max(1, math.floor((H - 2) / gh))
  local ox1, ox2, oy = 0, cw * gw + 3, 2
  local function fill(ox, gx, gy, bg, label, fg, border)
    local sx, sy = ox + gx * cw, oy + (A.bounds.y - gy) * ch
    mon.setBackgroundColor(bg)
    for r = 0, ch - 1 do mon.setCursorPos(sx + 1, sy + 1 + r); mon.write(string.rep(" ", cw)) end
    if border and cw >= 2 and ch >= 2 then -- frame divergent cells
      mon.setBackgroundColor(border)
      mon.setCursorPos(sx + 1, sy + 1); mon.write(string.rep(" ", cw))
      mon.setCursorPos(sx + 1, sy + ch); mon.write(string.rep(" ", cw))
      for r = 0, ch - 1 do mon.setCursorPos(sx + 1, sy + 1 + r); mon.write(" "); mon.setCursorPos(sx + cw, sy + 1 + r); mon.write(" ") end
    end
    if label then mon.setTextColor(fg or C.white); mon.setCursorPos(sx + math.floor(cw / 2) + 1, sy + math.floor(ch / 2) + 1); mon.write(label) end
  end
  local function base(ox, p, diff)
    for gy = 0, p.bounds.y do for gx = 0, p.bounds.x do fill(ox, gx, gy, C.gray, nil, nil, diff(gx, gy) and C.magenta or nil) end end
    for _, g in ipairs(p.goals) do fill(ox, g.x, g.y, C.orange, "G", C.black) end
    fill(ox, p.start.x, p.start.y, C.lime, "S", C.black)
  end
  local function title(ox, text, col)
    mon.setBackgroundColor(C.black); mon.setTextColor(col); mon.setCursorPos(ox + 1, 1); mon.write(text)
  end
  while true do
    mon.setBackgroundColor(C.black); mon.clear()
    title(ox1, "in order: " .. (#A.path - 1), C.yellow)
    title(ox2, "shortest: " .. (#B.path - 1), C.lime)
    base(ox1, A, onlyA); base(ox2, B, onlyB)
    for i = 1, math.max(#A.path, #B.path) do
      for _, pr in ipairs({ { ox1, A, C.yellow, onlyA }, { ox2, B, C.cyan, onlyB } }) do
        local ox, p, tc, diff = pr[1], pr[2], pr[3], pr[4]
        if i <= #p.path then
          if i > 1 then
            local v = p.path[i - 1]
            fill(ox, v.x, v.y, p.gset[v.x .. "," .. v.y] and C.red or tc, nil, nil, diff(v.x, v.y) and C.magenta or nil)
          end
          local h = p.path[i]
          fill(ox, h.x, h.y, C.white, nil, nil, diff(h.x, h.y) and C.magenta or nil)
        end
      end
      if sleep then sleep(0.18) end
    end
    if sleep then sleep(1.2) end
  end
end

-- magenta-bordered cells above become "#" here (cells unique to this route)
local function render_ascii(p, label, diff)
  print(label .. ": " .. (#p.path - 1) .. " moves   (# = only this route visits)")
  local vis = {}; for _, q in ipairs(p.path) do vis[q.x .. "," .. q.y] = true end
  print("+" .. string.rep("-", p.bounds.x + 1) .. "+")
  for y = p.bounds.y, 0, -1 do
    local row = {}
    for x = 0, p.bounds.x do
      local c = vis[x .. "," .. y] and (diff(x, y) and "#" or "*") or " "
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
  print("monitor found — animating (hold Ctrl+T to stop). magenta border = cells unique to that route.")
  render_monitor(mon)
else
  print("NO MONITOR — drawing to terminal (computer must touch the monitor to use it).")
  render_ascii(A, "in order", onlyA); render_ascii(B, "shortest", onlyB)
end
