(module
  (func (export "bench") (param $n i32) (result i32)
    (local $i i32) (local $acc i32)
    (block $done (loop $loop
      (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
      (local.set $acc (i32.add (local.get $acc) (local.get $i)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $loop)))
    (local.get $acc)))
