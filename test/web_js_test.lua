-- End-to-end test of Stage 2: the web engine runs <script> through QuickJS
-- (compiled into wasm/web.wasm) against a DOM bound to the parsed document, so
-- JavaScript can read/mutate the page before layout. Renders web/site/js.html
-- and asserts the JS-driven result. Requires the WEB_JS build of web.wasm
-- (tools/build-fixtures); skips cleanly if this engine has no JS.
package.path = "src/?.lua;test/?.lua;" .. package.path
local T = require("harness")
local wasm = require("wasm")
local wasi = require("wasi")
T.start("web_js")

local f = assert(io.open("wasm/web.wasm", "rb"), "wasm/web.wasm missing (run tools/build-fixtures)")
local bytes = f:read("*a"); f:close()

-- the JS demo lives at web/site/js.html; mount its dir, render that page via the
-- reactor interface (_initialize + web_init).
local out, err = {}, {}
local host = wasi.make({
  write = function(s) out[#out + 1] = s end,
  writeerr = function(s) err[#err + 1] = s end,
  args = { "web.wasm" },
  root = "web/site",
})
local inst = wasm.instantiate(wasm.load(bytes), { wasi_snapshot_preview1 = host }, { mode = "interp" })
inst:call("_initialize")
local function wstr(s) local p = inst:call("web_malloc", #s + 1); inst.memory:storestr(p, s); inst.memory:set8(p + #s, 0); return p end
local pp = wstr("js.html"); inst:call("web_init", pp, 51); inst:call("web_free", pp)
local proto = table.concat(out)
local console = table.concat(err)

-- detect a no-JS engine: the script never ran, so #app keeps its placeholder
if proto:find("loading...", 1, true) then
  print("web_js: engine has no JS (non-WEB_JS build) — skipping")
  T.done(); return
end

local lines = {}
for ln in (proto .. "\n"):gmatch("([^\n]*)\n") do lines[ln] = true end
local function has(line, msg) T.ok(lines[line] == true, (msg or line) .. "  [missing: " .. line .. "]") end

-- textContent set by JS, including a value computed in JS ([1,2,3].map(x=>x*x))
-- and style.color = 'lime' (palette 5)
has("T 1 3 5 0 Hello", "getElementById().textContent set by JS, lime")
has("T 24 3 5 0 1,", "JS-computed array value rendered")
has("T 30 3 5 0 9", "JS-computed array value (9 = 3*3)")

-- a node created by document.createElement + appendChild, styled cyan (9) and
-- right-aligned via setAttribute('style', ...)
has("T 36 5 9 0 createElement", "createElement node present + cyan")
has("T 39 6 9 0 appendChild.", "appended node wraps + right-aligned")

-- console.log went to stderr, not into the draw protocol
T.ok(console:find("script ran", 1, true) ~= nil, "console.log captured on stderr")
T.ok(proto:find("script ran", 1, true) == nil, "console.log did NOT leak into the draw protocol")

T.done()
