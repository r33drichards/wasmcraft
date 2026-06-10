-- bctest — does this computer's Lua load 5.1 bytecode? CC:Tweaked >= 1.109.0
-- refuses binary chunks, which disables wasmcraft's jit (compiled) mode — the
-- engine then falls back to the interpreter automatically. This prints which
-- world you're in. The probe chunk is a minimal valid 5.1 proto: "return 42".
local bc = "\27\76\117\97\81\0\1\4\4\4\8\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\2\2\2\0\0\0\1\0\0\0\30\0\0\1\1\0\0\0\3\0\0\0\0\0\0\69\64\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0"
local okload, f = pcall(loadstring or load, bc)
if okload and type(f) == "function" then
  local okrun, v = pcall(f)
  if okrun and v == 42 then
    print("bytecode loading WORKS (got " .. tostring(v) .. ") - jit mode available")
    return
  end
  print("chunk loaded but ran wrong: " .. tostring(v))
else
  print("bytecode loading BLOCKED: " .. tostring(f))
  print("(CC:T >= 1.109 behavior - wasmcraft will use the interpreter instead)")
end
