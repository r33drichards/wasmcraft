(module
 (type $bin (func (param i32 i32)(result i32)))
 (func $add (type $bin)(i32.add (local.get 0)(local.get 1)))
 (func $sub (type $bin)(i32.sub (local.get 0)(local.get 1)))
 (table 2 funcref)
 (elem (i32.const 0) $add $sub)
 (func (export "op")(param i32 i32 i32)(result i32)
   (call_indirect (type $bin) (local.get 1)(local.get 2)(local.get 0))))
