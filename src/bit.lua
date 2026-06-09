-- Unified 32-bit bitwise ops.
-- On Cobalt the global `bit32` exists (our harness installs Bit32Lib); use it.
-- On lua5.4 there is no bit32, so fall back to a native-operator implementation
-- kept in a SEPARATE file (bit_native.lua) — Cobalt's 5.1 parser would choke on
-- `&`/`|`/`<<`, and it never requires that file.
local b32 = rawget(_G, "bit32")
if b32 then return b32 end
return require("bit_native")
