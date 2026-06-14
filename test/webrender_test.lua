-- Drive the browser's pure renderer (dist/webrender.lua) with exactly the draw
-- protocol csrc/web/mvp.c emits, and assert the resulting frame — fills, text
-- placement, the palette->blit-hex mapping, and chunked line buffering. This is
-- the Stage 0 golden: it pins the wasm<->host contract without needing the
-- (zig-built) web.wasm present.
package.path = "dist/?.lua;test/?.lua;" .. package.path
local T = require("harness")
local WR = require("webrender")
T.start("webrender")

-- the byte-for-byte stdout of csrc/web/mvp.c
local PROTO =
  "SIZE 30 9\n" ..
  "CLEAR 0\n" ..
  "RECT 0 0 30 1 11\n" ..
  "T 1 0 0 11 wasmcraft web - stage 0\n" ..
  "T 1 2 15 0 Hello from wasm!\n" ..
  "T 1 3 7 0 Rendered on a CC monitor\n" ..
  "T 1 4 7 0 via the draw protocol.\n" ..
  "RECT 1 6 4 2 14\n" ..
  "RECT 6 6 4 2 5\n" ..
  "RECT 11 6 4 2 4\n" ..
  "RECT 16 6 4 2 9\n" ..
  "FRAME END\n"

-- feed the stream in awkward chunks (split mid-line) to exercise line_sink
local captured
local sink = WR.line_sink(WR.make_parser(function(fr) captured = fr end))
local i = 1
while i <= #PROTO do
  sink(PROTO:sub(i, i + 6))   -- 7-byte chunks straddle newlines
  i = i + 7
end

T.ok(captured ~= nil, "a frame was committed on FRAME END")
T.eq(captured.cols, 30, "frame width")
T.eq(captured.rows, 9, "frame height")

-- text placement: runs start at x=1 (a leading blank from the x=0 cell)
T.eq(captured:textrow(0):gsub("%s+$", ""), " wasmcraft web - stage 0", "title text row")
T.eq(captured:textrow(2):gsub("%s+$", ""), " Hello from wasm!", "body row 2")
T.eq(captured:textrow(3):gsub("%s+$", ""), " Rendered on a CC monitor", "body row 3")
T.eq(captured:textrow(8):gsub("%s+$", ""), "", "empty trailing row")

-- palette mapping: index n -> blit hex. The title bar fills row 0 with blue (b).
local _, fg0, bg0 = captured:blitrow(0)
T.eq(bg0, string.rep("b", 30), "row 0 background all blue (RECT then text share bg)")
T.eq(fg0:sub(2, 2), "0", "title text fg is white (0)")

-- the swatch row: white(0) gaps between red(e)/lime(5)/yellow(4)/cyan(9) blocks
local _, _, bg6 = captured:blitrow(6)
T.eq(bg6, "0eeee0555504444099990000000000", "swatch row background")

-- ---- monitor path: paint to a mock device and check the blit calls ----------
-- A 40x12 "monitor" comfortably fits the 30x9 frame, so fit_scale should pick a
-- large text scale and paint_blit should issue one blit per row.
local mon = { scale = nil, rows = {} }
function mon.setTextScale(s) mon.scale = s end
function mon.getSize() return 40, 12 end
function mon.setCursorPos(_, y) mon._y = y end
function mon.blit(t, f, b) mon.rows[mon._y] = { t = t, f = f, b = b } end

local s = WR.fit_scale(mon, captured)
T.ok(s == 5, "fit_scale picks the largest scale that fits 30x9 in 40x12")
WR.paint_blit(mon, captured)
T.eq(#mon.rows, 9, "paint_blit issues one blit per frame row")
T.eq(mon.rows[1].b, string.rep("b", 30), "monitor row 1 background matches frame (blue title bar)")
T.eq(mon.rows[7].b, "0eeee0555504444099990000000000", "monitor swatch row background matches frame")
T.eq(mon.rows[3].t:gsub("%s+$", ""), " Hello from wasm!", "monitor row 3 text matches frame")

-- a tiny monitor (10x4) can't fit the frame: fit_scale falls back to 0.5
local tiny = {}
function tiny.setTextScale() end
function tiny.getSize() return 10, 4 end
T.eq(WR.fit_scale(tiny, captured), 0.5, "fit_scale falls back to smallest scale when nothing fits")

T.done()
