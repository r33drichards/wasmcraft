-- planner — solve a Picat planner (grid pathfinding around a wall) on the
-- wasmcraft compiler and VISUALIZE it on a CC:Tweaked monitor.
--   Usage: planner            (auto-finds picat.wasm on a floppy at /disk/)
--          planner <picat.wasm path>
-- Picat's best_plan finds the shortest order-free path visiting every goal.
local BUNDLE_URL   = "https://paste-production.up.railway.app/wasmcraft-bundle"
local PICATLIB_URL = "https://paste-production.up.railway.app/wc-picat.lua"

local PROGRAM = [[
import planner.
import util.
main =>
  Origin = {0,0}, Goals = [{4,4},{4,0}], Walls = [{2,1},{2,2},{2,3}],
  best_plan({Origin,Goals,Walls}, Plan),
  printf("BOUNDS 4 4\n"), printf("START %w %w\n", Origin[1], Origin[2]),
  foreach({Gx,Gy} in Goals) printf("GOAL %w %w\n", Gx, Gy) end,
  foreach({Wx,Wy} in Walls) printf("WALL %w %w\n", Wx, Wy) end,
  printf("PATH %w %w\n", Origin[1], Origin[2]),
  walk(Origin, Plan).
final({_Pos,Goals,_}) => Goals = [].
action(From,To,Action,Cost) ?=>
  From = {{Fx,Fy},Goals,Walls}, member({Dx,Dy},[{-1,0},{1,0},{0,-1},{0,1}]),
  Tx=Fx+Dx, Ty=Fy+Dy, member(Tx,0..4), member(Ty,0..4), not member({Tx,Ty},Walls),
  To = {{Tx,Ty},Goals,Walls}, Action={move,{Tx,Ty}}, Cost=1.
action(From,To,Action,Cost) ?=>
  From = {Pos,Goals,Walls}, member(Pos,Goals),
  To = {Pos,delete(Goals,Pos),Walls}, Action={mark,Pos}, Cost=1.
walk(_, []) => true.
walk(_P,[{move,{Tx,Ty}}|R]) => printf("PATH %w %w\n", Tx, Ty), walk({Tx,Ty}, R).
walk(P,[{mark,_}|R]) => walk(P, R).
]]

-- ---- bootstrap deps --------------------------------------------------------
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
local args = { ... }
picat.modulePath = args[1] or find({ "disk/picat.wasm", "picat.wasm", "wasm/picat.wasm",
  "/Users/robertwendt/picat-cc/third_party/picat/emu/picat.wasm" }) or "disk/picat.wasm"

-- ---- find the monitor up front, and SAY what we found ----------------------
local mon = (type(peripheral) == "table") and peripheral.find and peripheral.find("monitor")
if mon then
  print("monitor found: drawing there.")
else
  print("NO MONITOR found — make sure the computer is directly touching the monitor")
  print("(or connected by a wired modem). Falling back to the terminal.")
end

-- ---- run + parse -----------------------------------------------------------
print("solving with Picat (compiles once, ~30-60s)...")
local out = picat.run(PROGRAM, { root = "." })

local bounds, start, goals, walls, path = { x = 4, y = 4 }, { x = 0, y = 0 }, {}, {}, {}
local goalset, wallset = {}, {}
for line in out:gmatch("[^\n]+") do
  local k, a, b = line:match("(%u+)%s+(%-?%d+)%s+(%-?%d+)")
  if k == "BOUNDS" then bounds = { x = tonumber(a), y = tonumber(b) }
  elseif k == "START" then start = { x = tonumber(a), y = tonumber(b) }
  elseif k == "GOAL" then goals[#goals + 1] = { x = tonumber(a), y = tonumber(b) }; goalset[a .. "," .. b] = true
  elseif k == "WALL" then walls[#walls + 1] = { x = tonumber(a), y = tonumber(b) }; wallset[a .. "," .. b] = true
  elseif k == "PATH" then path[#path + 1] = { x = tonumber(a), y = tonumber(b) } end
end
local function isgoal(x, y) return goalset[x .. "," .. y] end
local function iswall(x, y) return wallset[x .. "," .. y] end

-- ---- monitor renderer: big centered colored cells filling the screen -------
local function render_monitor()
  local cols = colors or colours
  mon.setTextScale(1)
  local W, H = mon.getSize()
  local gw, gh = bounds.x + 1, bounds.y + 1
  local cw = math.max(1, math.floor(W / gw))
  local ch = math.max(1, math.floor((H - 2) / gh))
  local ox = math.floor((W - cw * gw) / 2)
  local oy = 1
  local function fill(gx, gy, bg, label, fg)
    local sx, sy = ox + gx * cw, oy + (bounds.y - gy) * ch
    mon.setBackgroundColor(bg)
    for r = 0, ch - 1 do mon.setCursorPos(sx + 1, sy + 1 + r); mon.write(string.rep(" ", cw)) end
    if label then
      mon.setTextColor(fg or cols.white)
      mon.setCursorPos(sx + math.floor(cw / 2) + 1, sy + math.floor(ch / 2) + 1)
      mon.write(label)
    end
  end
  mon.setBackgroundColor(cols.black); mon.clear()
  for gy = 0, bounds.y do for gx = 0, bounds.x do
    fill(gx, gy, iswall(gx, gy) and cols.brown or cols.gray)
  end end
  for _, g in ipairs(goals) do fill(g.x, g.y, cols.orange, "G", cols.black) end
  fill(start.x, start.y, cols.lime, "S", cols.black)
  for i = 1, #path do
    local p = path[i]
    if i > 1 then local pv = path[i - 1]; fill(pv.x, pv.y, isgoal(pv.x, pv.y) and cols.red or cols.blue) end
    fill(p.x, p.y, cols.white)
    if sleep then sleep(0.2) end
  end
  local last = path[#path]; fill(last.x, last.y, isgoal(last.x, last.y) and cols.red or cols.blue)
  mon.setBackgroundColor(cols.black); mon.setTextColor(cols.white)
  mon.setCursorPos(1, H); mon.write((#path - 1) .. " moves, " .. #goals .. " goals")
end

local function render_ascii()
  local visited = {}; for _, p in ipairs(path) do visited[p.x .. "," .. p.y] = true end
  print("+" .. string.rep("-", bounds.x + 1) .. "+")
  for y = bounds.y, 0, -1 do
    local row = {}
    for x = 0, bounds.x do
      local c = " "
      if visited[x .. "," .. y] then c = "*" end
      if iswall(x, y) then c = "#" end
      if isgoal(x, y) then c = "G" end
      if x == start.x and y == start.y then c = "O" end
      row[#row + 1] = c
    end
    print("|" .. table.concat(row) .. "|")
  end
  print("+" .. string.rep("-", bounds.x + 1) .. "+")
end

if #path == 0 then print("no plan found / parse error; raw output:\n" .. out); return end
print("solved: " .. (#path - 1) .. " moves around the wall")
if mon then render_monitor() else render_ascii() end
