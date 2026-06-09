(module
 (func $sq (param i32)(result i32) (i32.mul (local.get 0)(local.get 0)))
 (func (export "sumsq")(param i32 i32)(result i32)
   (i32.add (call $sq (local.get 0))(call $sq (local.get 1)))))
