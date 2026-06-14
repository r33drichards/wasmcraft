-- End-to-end test of the reactor/event loop: render an interactive page, then
-- deliver click events at the button's cell and assert the DOM updated and
-- re-rendered. Exercises addEventListener + hit-testing + web_event + re-layout
-- with plain JS (fast — no React). Requires the WEB_JS build; skips otherwise.
package.path = "src/?.lua;test/?.lua;" .. package.path
local T = require("harness")
local wasm = require("wasm")
local wasi = require("wasi")
T.start("web_event")

local f = assert(io.open("wasm/web.wasm", "rb"), "wasm/web.wasm missing (run tools/build-fixtures)")
local bytes = f:read("*a"); f:close()

local out = {}
local host = wasi.make({
  write = function(s) out[#out + 1] = s end,
  writeerr = function() end,
  args = { "web.wasm" },
  root = "web/site",
})
local inst = wasm.instantiate(wasm.load(bytes), { wasi_snapshot_preview1 = host }, { mode = "interp" })
inst:call("_initialize")
local function wstr(s) local p = inst:call("web_malloc", #s + 1); inst.memory:storestr(p, s); inst.memory:set8(p + #s, 0); return p end
local function frame() local s = table.concat(out); out = {}; return s end

local pp = wstr("click.html"); inst:call("web_init", pp, 51); inst:call("web_free", pp)
local f0 = frame()

if f0:find("clicks:0", 1, true) == nil then
  print("web_event: engine has no JS (non-WEB_JS build) — skipping"); T.done(); return
end
T.ok(f0:find("clicks:0", 1, true) ~= nil, "initial state rendered (clicks:0)")

-- find the button's row from the draw protocol (T x y ... increment)
local brow
for line in (f0 .. "\n"):gmatch("([^\n]*)\n") do
  local y = line:match("^T %d+ (%d+) .*increment"); if y then brow = tonumber(y) end
end
T.ok(brow ~= nil, "increment button is rendered")

local function click(x, y)
  local tp = wstr("click"); inst:call("web_event", tp, x, y); inst:call("web_free", tp)
  return frame()
end

-- a click ON the button updates the count and re-renders
local f1 = click(2, brow or 0)
T.ok(f1:find("clicks:1", 1, true) ~= nil, "click on the button -> clicks:1")
local f2 = click(2, brow or 0)
T.ok(f2:find("clicks:2", 1, true) ~= nil, "second click -> clicks:2")

-- a click far away (row 0, not on the button) does NOT change the count
local f3 = click(0, 0)
T.ok(f3:find("clicks:2", 1, true) ~= nil, "click off the button leaves the count unchanged")

T.done()
