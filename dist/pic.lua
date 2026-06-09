-- pic — client for a picatd daemon. Sends a Picat program/query to a named
-- daemon over rednet and prints the result. No boot cost: the daemon stays warm.
--   pic <name> <file.pi>     run a program file on the daemon
--   pic <name> -e "Goal."    run a raw Picat goal/query
--   pic <name> -i            interactive shell (a remote Picat> prompt)
--   pic <name> --reset       reset the daemon to a fresh engine
--   pic <name>               read a program from the terminal (end with a "." line)
local PROTO = "wcpicat"

local a = { ... }
local name = a[1]
if not name then print("usage: pic <name> [file.pi | -e \"goal.\" | -i | --reset]"); return end

-- open every modem
local opened = false
if type(peripheral) == "table" and peripheral.find then
  peripheral.find("modem", function(n) rednet.open(n); opened = true end)
end
if not opened then print("pic: no modem attached."); return end

local id = rednet.lookup(PROTO, name)
if not id then print("pic: no picatd named '" .. name .. "' found on the network."); return end

local reqn = 0
local function ask(m, timeout)
  reqn = reqn + 1
  m.id = tostring(os.getComputerID and os.getComputerID() or 0) .. ":" .. reqn .. ":" ..
    tostring(os.epoch and os.epoch("utc") or os.clock())
  rednet.send(id, m, PROTO)
  local deadline = os.clock() + (timeout or 300)
  while os.clock() < deadline do
    local _, r = rednet.receive(PROTO, deadline - os.clock())
    if type(r) == "table" and (r.id == m.id or r.id == nil) then
      if r.status == "queued" then
        print("(daemon busy — queued at position " .. tostring(r.position) .. ")")
      else
        return r
      end
    end
  end
end

-- interactive shell: a remote Picat> prompt served by the warm daemon
if a[2] == "-i" then
  print("pic: shell on '" .. name .. "' — 'reset.' resets, 'exit' quits.")
  while true do
    write("Picat> ")
    local line = read()
    if line == "exit" or line == "quit" or line == "halt." then break end
    if line == "reset." or line == "reset" then
      local r = ask({ action = "reset" })
      print(r and r.output or "(timeout)")
    elseif line ~= "" then
      local r = ask({ action = "query", goal = line })
      if not r then print("(timeout — daemon busy or gone)")
      else
        -- strip the REPL's echo of our own line and the trailing prompt
        local out = (r.output or "")
        out = out:gsub("^[^\n]*\n", "", 1)
        out = out:gsub("%s*Picat>%s*$", "")
        if out ~= "" then print(out) end
        if not r.ok then print("(daemon reported an error)") end
      end
    end
  end
  return
end

local msg
if a[2] == "--reset" then
  msg = { action = "reset" }
elseif a[2] == "-e" then
  msg = { action = "query", goal = a[3] or "true." }
elseif a[2] then
  local h = assert(fs and fs.open(a[2], "r") or io.open(a[2], "r"), "cannot open " .. a[2])
  local prog = h.readAll and h.readAll() or h:read("*a"); h.close()
  msg = { action = "run", program = prog }
else
  print("enter a Picat program; finish with a line containing only '.'")
  local lines = {}
  while true do local l = read(); if l == "." then break end lines[#lines + 1] = l end
  msg = { action = "run", program = table.concat(lines, "\n") }
end

local reply = ask(msg)
if not reply then print("pic: timeout waiting for daemon.")
elseif type(reply) == "table" then
  io.write(reply.output or "")
  if reply.output and reply.output:sub(-1) ~= "\n" then io.write("\n") end
  if not reply.ok then print("(daemon reported an error)") end
end
