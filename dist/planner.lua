-- planner — run a Picat planner (grid pathfinding, after Hillel Wayne's
-- "Planner programming blows my mind") through the pure-Lua wasm interpreter,
-- and visualize the solved path on a CC:Tweaked monitor (or the terminal).
--
--   Usage: planner [picat.wasm path]      (default: disk/picat.wasm — a floppy)
--
-- Picat is given a start, a list of goals, and one-step move actions; its
-- planner finds the shortest path that visits every goal (order-free). We parse
-- its output and animate the marker tracing that path.

-- ---- the Picat program (its planner does the actual search) ----------------
local PROGRAM = [[
import planner.
import util.

main =>
  Origin = {0,0},
  Goals  = [{4,4},{4,0},{0,3}],
  MaxX = 4, MaxY = 4,
  best_plan({Origin, Goals}, Plan),
  printf("BOUNDS %w %w\n", MaxX, MaxY),
  printf("START %w %w\n", Origin[1], Origin[2]),
  foreach({Gx,Gy} in Goals) printf("GOAL %w %w\n", Gx, Gy) end,
  printf("PATH %w %w\n", Origin[1], Origin[2]),
  walk(Origin, Plan).

final({_Pos, Goals}) => Goals = [].

action(From, To, Action, Cost) ?=>
  From = {{Fx,Fy}, Goals},
  member({Dx,Dy}, [{-1,0},{1,0},{0,-1},{0,1}]),
  Tx = Fx+Dx, Ty = Fy+Dy,
  member(Tx, 0..4), member(Ty, 0..4),
  To = {{Tx,Ty}, Goals},
  Action = {move,{Tx,Ty}}, Cost = 1.

action(From, To, Action, Cost) ?=>
  From = {Pos, Goals},
  member(Pos, Goals),
  To = {Pos, delete(Goals, Pos)},
  Action = {mark, Pos}, Cost = 1.

walk(_, []) => true.
walk(_Pos, [{move,{Tx,Ty}}|R]) => printf("PATH %w %w\n", Tx, Ty), walk({Tx,Ty}, R).
walk(Pos, [{mark,_}|R]) => walk(Pos, R).
]]

-- ---- load the picat library (and the interpreter it sits on) ---------------
local function load_picat()
  for _, p in ipairs({ "picat.lua", "dist/picat.lua", "picat" }) do
    local fn = loadfile(p)
    if fn then return fn() end
  end
  local ok, mod = pcall(require, "picat")
  if ok then return mod end
  error("picat.lua not found — wget it first")
end

local picat = load_picat()
local args = { ... }
picat.modulePath = args[1] or "disk/picat.wasm"

-- ---- run + parse -----------------------------------------------------------
io.write("solving plan with Picat (engine boot ~1 min on a computer)...\n")
local out = picat.run(PROGRAM, { root = (args[2] or ".") })

local bounds, start, goals, path = { x = 4, y = 4 }, { x = 0, y = 0 }, {}, {}
local goalset = {}
for line in out:gmatch("[^\n]+") do
  local k, a, b = line:match("(%u+)%s+(%-?%d+)%s+(%-?%d+)")
  if k == "BOUNDS" then bounds = { x = tonumber(a), y = tonumber(b) }
  elseif k == "START" then start = { x = tonumber(a), y = tonumber(b) }
  elseif k == "GOAL" then goals[#goals + 1] = { x = tonumber(a), y = tonumber(b) }; goalset[a .. "," .. b] = true
  elseif k == "PATH" then path[#path + 1] = { x = tonumber(a), y = tonumber(b) } end
end
local function isgoal(x, y) return goalset[x .. "," .. y] == true end

-- ---- renderers -------------------------------------------------------------
-- ASCII (terminal / standalone): blog-style box, origin bottom-left.
local function render_ascii(visited)
  local W = bounds.x + 1
  local top = "+" .. string.rep("-", W) .. "+"
  print(top)
  for y = bounds.y, 0, -1 do
    local row = {}
    for x = 0, bounds.x do
      local c = " "
      if visited[x .. "," .. y] then c = "*" end
      if isgoal(x, y) then c = "G" end
      if x == start.x and y == start.y then c = "O" end
      row[#row + 1] = c
    end
    print("|" .. table.concat(row) .. "|")
  end
  print(top)
end

-- CC monitor: animated colored trace. Origin bottom-left.
local function render_monitor(mon)
  local cols = colors or colours
  mon.setTextScale(0.5)
  mon.setBackgroundColor(cols.black); mon.clear()
  local ox, oy = 2, 2 -- top-left of the grid inside the monitor
  local function cell(x, y, bg, ch, fg)
    mon.setCursorPos(ox + x, oy + (bounds.y - y))
    mon.setBackgroundColor(bg); mon.setTextColor(fg or cols.white)
    mon.write(ch or " ")
  end
  -- empty grid + goals + start
  for y = 0, bounds.y do for x = 0, bounds.x do cell(x, y, cols.gray, " ") end end
  for _, g in ipairs(goals) do cell(g.x, g.y, cols.orange, "G", cols.black) end
  cell(start.x, start.y, cols.lime, "O", cols.black)
  -- animate the marker
  for i = 1, #path do
    local p = path[i]
    if i > 1 then
      local prev = path[i - 1]
      local bg = isgoal(prev.x, prev.y) and cols.red or cols.blue
      cell(prev.x, prev.y, bg, isgoal(prev.x, prev.y) and "G" or " ", cols.white)
    end
    cell(p.x, p.y, cols.white, "@", cols.black)
    if sleep then sleep(0.12) end
  end
  -- finalize last cell
  local last = path[#path]
  cell(last.x, last.y, isgoal(last.x, last.y) and cols.red or cols.blue, " ")
  mon.setBackgroundColor(cols.black); mon.setTextColor(cols.white)
  mon.setCursorPos(1, oy + bounds.y + 2)
  mon.write(#path - 1 .. " steps, " .. #goals .. " goals")
end

-- ---- drive -----------------------------------------------------------------
local visited = {}
for _, p in ipairs(path) do visited[p.x .. "," .. p.y] = true end

local mon = (type(peripheral) == "table") and peripheral.find and peripheral.find("monitor")
if mon then
  render_monitor(mon)
  print("path drawn on the monitor (" .. (#path - 1) .. " steps).")
else
  print("Goals: " .. #goals .. "   Path length: " .. (#path - 1) .. " steps")
  render_ascii(visited)
end
