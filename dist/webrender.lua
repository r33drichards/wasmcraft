-- webrender — the pure (device-independent) half of the browser renderer:
-- parse the wasmcraft "web" draw protocol (see csrc/web/draw.h) into a frame
-- buffer of {ch, fg, bg} cells, with no ComputerCraft dependencies. browser.lua
-- wraps this with monitor/terminal painting; tests drive it directly and assert
-- the ASCII form as golden output. Runs identically on Cobalt (Lua 5.1) and lua5.4.
local M = {}

local HEX = "0123456789abcdef"   -- palette index 0..15 -> blit hex digit
local function hexd(i)
  i = tonumber(i) or 0
  if i < 0 or i > 15 then i = 0 end
  return HEX:sub(i + 1, i + 1)
end
M.hexd = hexd

-- ---- frame buffer -----------------------------------------------------------
local Frame = {}
Frame.__index = Frame
M.Frame = Frame

function Frame.new(cols, rows)
  if cols < 1 then cols = 1 end
  if rows < 1 then rows = 1 end
  local g = setmetatable({ cols = cols, rows = rows, cell = {} }, Frame)
  for y = 0, rows - 1 do
    local row = {}
    for x = 0, cols - 1 do row[x] = { " ", 15, 0 } end  -- black on white
    g.cell[y] = row
  end
  return g
end
function Frame:set(x, y, ch, fg, bg)
  local row = self.cell[y]; if not row then return end
  local c = row[x]; if not c then return end
  c[1], c[2], c[3] = ch, fg, bg
end
function Frame:fill(x, y, w, h, bg)
  for yy = y, y + h - 1 do for xx = x, x + w - 1 do
    local row = self.cell[yy]; local c = row and row[xx]
    if c then c[1], c[3] = " ", bg end
  end end
end
-- a row as three parallel strings, ready for blit(text, fgHex, bgHex)
function Frame:blitrow(y)
  local row = self.cell[y]
  local t, f, b = {}, {}, {}
  for x = 0, self.cols - 1 do
    local c = row[x]
    t[x + 1] = c[1]; f[x + 1] = hexd(c[2]); b[x + 1] = hexd(c[3])
  end
  return table.concat(t), table.concat(f), table.concat(b)
end
-- the visible characters of a row (no colour) — golden/ASCII form
function Frame:textrow(y)
  local row, out = self.cell[y], {}
  for x = 0, self.cols - 1 do out[x + 1] = row[x][1] end
  return table.concat(out)
end

-- ---- draw-protocol parser ---------------------------------------------------
-- Feed it whole lines; it calls on_frame(frame) when a frame is committed.
function M.make_parser(on_frame)
  local fr
  return function(line)
    line = line:gsub("[\r\n]+$", "")
    if line == "" then return end
    local cmd, rest = line:match("^(%S+)%s*(.*)$")
    if cmd == "SIZE" then
      local c, r = rest:match("^(%d+)%s+(%d+)")
      if c then fr = Frame.new(tonumber(c), tonumber(r)) end
    elseif cmd == "CLEAR" and fr then
      fr:fill(0, 0, fr.cols, fr.rows, tonumber(rest) or 0)
    elseif cmd == "RECT" and fr then
      local x, y, w, h, bg = rest:match("^(%-?%d+)%s+(%-?%d+)%s+(%d+)%s+(%d+)%s+(%d+)")
      if x then fr:fill(tonumber(x), tonumber(y), tonumber(w), tonumber(h), tonumber(bg)) end
    elseif cmd == "T" and fr then
      local x, y, fg, bg, text = rest:match("^(%-?%d+)%s+(%-?%d+)%s+(%d+)%s+(%d+)%s+(.*)$")
      if x then
        x, y, fg, bg = tonumber(x), tonumber(y), tonumber(fg), tonumber(bg)
        for i = 1, #text do fr:set(x + i - 1, y, text:sub(i, i), fg, bg) end
      end
    elseif cmd == "FRAME" and rest == "END" and fr then
      on_frame(fr); fr = nil
    end
  end
end

-- A line-buffering sink: the engine's stdout callback gets arbitrary chunks, so
-- accumulate and dispatch only on complete newline-terminated lines.
function M.line_sink(onLine)
  local buf = ""
  return function(s)
    buf = buf .. s
    while true do
      local nl = buf:find("\n", 1, true)
      if not nl then break end
      onLine(buf:sub(1, nl)); buf = buf:sub(nl + 1)
    end
  end
end

-- Render a frame as plain ASCII (off-CC fallback / golden output). `write`
-- defaults to io.write; pass your own to capture.
function M.paint_ascii(fr, write)
  write = write or io.write
  for y = 0, fr.rows - 1 do write(fr:textrow(y), "\n") end
end

-- Paint a frame to any device exposing CC's term/monitor blit surface
-- (setCursorPos + blit). Used for both real monitors and the CC terminal.
-- `maxrows` (optional) clips tall pages to the device height.
function M.paint_blit(dev, fr, maxrows)
  local last = fr.rows - 1
  if maxrows and maxrows - 1 < last then last = maxrows - 1 end
  for y = 0, last do
    dev.setCursorPos(1, y + 1)
    dev.blit(fr:blitrow(y))
  end
end

-- Choose the largest CC text scale (0.5..5) at which the whole frame still fits
-- the monitor; if nothing fits, use the smallest text and let the edges clip.
function M.fit_scale(mon, fr)
  for _, s in ipairs({ 5, 4, 3, 2.5, 2, 1.5, 1, 0.5 }) do
    mon.setTextScale(s)
    local W, H = mon.getSize()
    if W >= fr.cols and H >= fr.rows then return s end
  end
  mon.setTextScale(0.5)
  return 0.5
end

return M
