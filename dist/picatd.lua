-- picatd — a resident Picat daemon. Boots Picat ONCE, then serves run/query/
-- reset requests over rednet, so any computer on the network can use it without
-- paying the ~30s boot each time.
--   Usage: picatd [name]     (name defaults to the computer label, else "picat")
-- Talk to it with the `pic` client, or any rednet message on protocol "wcpicat":
--   { action="run",   program="main => ..." }  -> { ok=bool, output=str }
--   { action="query", goal="X=2+3, println(X)." }
--   { action="reset" }                          -> fresh engine (clears state)
--   { action="ping" }                           -> { ok=true, output=name }
local BUNDLE_URL   = "https://paste-production.up.railway.app/wasmcraft-bundle"
local PICATLIB_URL = "https://paste-production.up.railway.app/wc-picat.lua"
local PROTO = "wcpicat"

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
picat.modulePath = find({ "disk/picat.wasm", "picat.wasm", "wasm/picat.wasm",
  "/Users/robertwendt/picat-cc/third_party/picat/emu/picat.wasm" }) or "disk/picat.wasm"

local name = ({ ... })[1]
if not name and os and os.getComputerLabel then name = os.getComputerLabel() end
name = name or "picat"

-- open every modem so rednet can host/serve
local served = false
if type(peripheral) == "table" and peripheral.find then
  peripheral.find("modem", function(n) rednet.open(n); served = true end)
end

print("picatd: booting Picat (~30-60s)...")
local s = picat.session({ root = "." })
print("picatd: ready.")

if served then
  rednet.host(PROTO, name)
  print("picatd: serving as '" .. name .. "' on protocol '" .. PROTO .. "'.")
else
  print("picatd: no modem attached — attach one and restart to serve over rednet.")
  return
end

local function handle(msg)
  if type(msg) ~= "table" then return { ok = false, output = "bad request" } end
  if msg.action == "ping" then return { ok = true, output = name }
  elseif msg.action == "reset" then s:reset(); return { ok = true, output = "reset" }
  elseif msg.action == "run" then
    local ok, out = pcall(function() return s:run(msg.program or "") end)
    return { ok = ok, output = ok and out or tostring(out) }
  elseif msg.action == "query" then
    local ok, out = pcall(function() return s:query(msg.goal or "") end)
    return { ok = ok, output = ok and out or tostring(out) }
  end
  return { ok = false, output = "unknown action: " .. tostring(msg.action) }
end

while true do
  local sender, msg = rednet.receive(PROTO)
  local reply = handle(msg)
  rednet.send(sender, reply, PROTO)
  print(("%s from %s -> %s"):format(type(msg) == "table" and tostring(msg.action) or "?",
    tostring(sender), reply.ok and "ok" or "err"))
end
