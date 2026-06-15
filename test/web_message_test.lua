-- Test the host->JS data channel: render a plain-JS page, call web_message with
-- JSON, and assert the page read globalThis.__hostmsg and re-rendered. Exercises
-- the web_message export + __wasmcraft_message hook + re-layout. The page's
-- inline script sets a JS-driven "ready" sentinel on load; a non-WEB_JS engine
-- never runs it (the DOM keeps its static "nojs" text), so the test skips.
package.path = "src/?.lua;test/?.lua;" .. package.path
local T = require("harness")
local wasm = require("wasm")
local wasi = require("wasi")
T.start("web_message")

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

local pp = wstr("hostmsg.html"); inst:call("web_init", pp, 51); inst:call("web_free", pp)
local f0 = frame()

-- skip on a non-WEB_JS engine: the inline script never runs, so the JS-driven
-- "ready" sentinel is absent (the DOM keeps its static "nojs" text).
if f0:find("ready", 1, true) == nil then
  print("web_message: engine has no JS (non-WEB_JS build) — skipping"); T.done(); return
end
T.ok(f0:find("ready", 1, true) ~= nil, "initial state rendered (ready)")

local function message(json)
  local p = wstr(json); inst:call("web_message", p); inst:call("web_free", p)
  return frame()
end

local f1 = message('{"text":"hello"}')
T.ok(f1:find("msg:hello", 1, true) ~= nil, "web_message delivers JSON -> msg:hello")
local f2 = message('{"text":"again"}')
T.ok(f2:find("msg:again", 1, true) ~= nil, "second web_message updates without remount -> msg:again")

T.done()
