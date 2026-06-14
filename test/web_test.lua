-- End-to-end test of the Stage 1 web engine (csrc/web/web.c -> wasm/web.wasm):
-- run it through the wasm interpreter over the committed fixture web/site/
-- index.html and assert the draw protocol it emits — proving HTML parsing, the
-- CSS cascade (tag/.class/#id + inline style), inline-run colours, text
-- wrapping, and block layout all the way to the host. Runs on lua5.4 + Cobalt.
package.path = "src/?.lua;test/?.lua;" .. package.path
local T = require("harness")
local wasm = require("wasm")
local wasi = require("wasi")
T.start("web")

local f = assert(io.open("wasm/web.wasm", "rb"), "wasm/web.wasm missing (run tools/build-fixtures)")
local bytes = f:read("*a"); f:close()

-- capture the engine's stdout (the draw protocol). web.wasm is a reactor:
-- _initialize, then web_init(page, width) renders the first frame.
local out = {}
local host = wasi.make({
  write = function(s) out[#out + 1] = s end,
  args = { "web.wasm" },
  root = "web/site",
})
local inst = wasm.instantiate(wasm.load(bytes), { wasi_snapshot_preview1 = host }, { mode = "interp" })
inst:call("_initialize")
local function wstr(s) local p = inst:call("web_malloc", #s + 1); inst.memory:storestr(p, s); inst.memory:set8(p + #s, 0); return p end
local pp = wstr("index.html"); inst:call("web_init", pp, 51); inst:call("web_free", pp)
local proto = table.concat(out)

-- a small helper: is `needle` present as a whole protocol line?
local lines = {}
for ln in (proto .. "\n"):gmatch("([^\n]*)\n") do lines[ln] = true end
local function has(line, msg) T.ok(lines[line] == true, (msg or line) .. "  [missing: " .. line .. "]") end

T.ok(proto:match("^SIZE 51 %d+\n") ~= nil, "frame opens with SIZE 51 x")
T.ok(lines["CLEAR 0"], "page clears to white")
T.ok(lines["FRAME END"], "frame is committed")

-- h1 { color: blue; text-align: center } -> blue (11), centered on 51 cols
has("T 17 1 11 0 wasmcraft", "h1 centered + blue")
has("T 27 1 11 0 browser", "h1 second word")

-- inline <span style="color:red"> keeps its colour through wrapping (14 = red)
has("T 1 5 14 0 C", "inline red span word 1")
has("T 3 5 14 0 program", "inline red span word 2")

-- .note { background-color: yellow } -> a yellow (4) RECT behind the line
has("RECT 1 8 50 1 4", "note paragraph background fill")
has("T 1 8 15 4 Backgrounds,", "note text on yellow bg")

-- <ul><li> bullets
has("T 1 12 15 0 -", "list bullet")
has("T 3 12 15 0 parses", "list item text")

-- #foot { color: lightgray; text-align: right } -> grey (8), right-aligned
has("T 44 17 8 0 stage", "footer right-aligned + lightgray")

T.done()
