(module
 (func (export "f") (param i32 i32)(result i32)
   (i32.add
     (i32.sub
       (i32.mul (local.get 0)(i32.const 3))
       (i32.and (local.get 1)(i32.const 0xFF)))
     (i32.shl
       (i32.xor (i32.or (local.get 0)(local.get 1))(i32.const 1))
       (i32.const 2))))
 (func (export "divrem")(param i32 i32)(result i32)
   (i32.add (i32.div_s (local.get 0)(local.get 1))(i32.rem_s (local.get 0)(local.get 1))))
 (func (export "cmp")(param i32 i32)(result i32)
   (i32.add (i32.add
     (i32.mul (i32.lt_s (local.get 0)(local.get 1))(i32.const 1))
     (i32.mul (i32.gt_u (local.get 0)(local.get 1))(i32.const 10)))
     (i32.mul (i32.eqz (local.get 0))(i32.const 100))))
 (func (export "bits")(param i32)(result i32)
   (i32.add (i32.add (i32.clz (local.get 0))(i32.ctz (local.get 0)))(i32.popcnt (local.get 0)))))
