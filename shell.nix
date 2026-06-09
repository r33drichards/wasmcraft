# Dev environment for wasmcraft: a WASM 3.0 interpreter in Lua, verified on Cobalt.
# Usage:  nix-shell --run "tools/cobalt test/probe_cobalt.lua"
#   lua          -> Lua 5.4, fast local dev (semantics kept to the 5.1 subset Cobalt supports)
#   java/javac   -> JDK 21, to build & run the Cobalt VM harness
#   wat2wasm     -> assemble .wat test fixtures into .wasm
#   wasmtime     -> reference oracle for differential testing
{ pkgs ? import <nixpkgs> { } }:
pkgs.mkShell {
  packages = [
    pkgs.lua5_4
    pkgs.temurin-bin-21
    pkgs.wabt
    pkgs.wasmtime
  ];
}
