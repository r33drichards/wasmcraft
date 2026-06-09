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
local function load_lib()
  return assert(loadfile(find({ "picat.lua", "dist/picat.lua" }) or error("picat.lua missing")))()
end
local picat = load_lib()
-- self-heal: ensure() keeps pre-existing files, so an old picat.lua/wasmcraft
-- (without session support) may have been loaded. Refresh both and reload.
if not picat.session and type(fs) == "table" then
  print("picatd: picat.lua/wasmcraft out of date - refreshing...")
  for f, u in pairs({ ["picat.lua"] = PICATLIB_URL, ["wasmcraft"] = BUNDLE_URL }) do
    if fs.exists(f) then fs.delete(f) end
    ensure(f, u)
  end
  picat = load_lib()
end
assert(picat.session, "picat.lua still lacks session() after refresh")
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
-- warm-up: the first cl/main touches engine paths that compile lazily on first
-- call; pay that cost here so the first real command is fast.
print("picatd: warming up...")
pcall(function() s:run('main => println(warm).') end)
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

local function respond(sender, reply, id)
  reply.id = id
  rednet.send(sender, reply, PROTO)
end

-- Concurrent clients: a receiver coroutine accepts requests while a worker runs
-- the (single) Picat engine. The compiled engine yields to the event loop at
-- loop back-edges, so the receiver stays responsive during long runs: pings are
-- answered instantly and queued jobs get an immediate ACK with their position.
-- Requests carry an id; replies echo it so clients match them up.
local queue, busy = {}, false

local function receiver()
  while true do
    local sender, msg = rednet.receive(PROTO)
    if type(msg) == "table" and msg.action == "ping" then
      respond(sender, { ok = true, output = name }, msg.id)
    elseif type(msg) == "table" then
      queue[#queue + 1] = { sender = sender, msg = msg }
      if busy or #queue > 1 then
        respond(sender, { ok = true, status = "queued", position = #queue }, msg.id)
      end
      os.queueEvent("wcpicat_work")
    else
      respond(sender, { ok = false, output = "bad request" }, nil)
    end
  end
end

local function worker()
  while true do
    if #queue == 0 then
      os.pullEvent("wcpicat_work")
    else
      local job = table.remove(queue, 1)
      busy = true
      local reply = handle(job.msg)
      busy = false
      respond(job.sender, reply, job.msg.id)
      print(("%s from %s -> %s%s"):format(tostring(job.msg.action), tostring(job.sender),
        reply.ok and "ok" or "err", #queue > 0 and (" (" .. #queue .. " queued)") or ""))
    end
  end
end

if parallel then
  parallel.waitForAll(receiver, worker)
else -- non-CC fallback: serial serve loop
  while true do
    local sender, msg = rednet.receive(PROTO)
    local reply = handle(msg)
    respond(sender, reply, type(msg) == "table" and msg.id or nil)
  end
end
