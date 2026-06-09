(module
 (memory 1)
 (func (export "shrs")(param i32 i32)(result i32)(i32.shr_s (local.get 0)(local.get 1)))
 (func (export "shru")(param i32 i32)(result i32)(i32.shr_u (local.get 0)(local.get 1)))
 (func (export "divs")(param i32 i32)(result i32)(i32.div_s (local.get 0)(local.get 1)))
 (func (export "remu")(param i32 i32)(result i32)(i32.rem_u (local.get 0)(local.get 1)))
 (func (export "truncs")(param f64)(result i32)(i32.trunc_f64_s (local.get 0)))
 (func (export "l8u")(param i32)(result i32)(i32.store8 (i32.const 0)(local.get 0))(i32.load8_u (i32.const 0)))
 (func (export "l16u")(param i32)(result i32)(i32.store16 (i32.const 0)(local.get 0))(i32.load16_u (i32.const 0)))
 (func (export "i64rt")(param i32)(result i32)  ;; i64 store/load roundtrip, return low32
   (i64.store (i32.const 8)(i64.extend_i32_s (local.get 0)))
   (i32.wrap_i64 (i64.load (i32.const 8))))
 (func (export "sel")(param i32 i32 i32)(result i32)(select (local.get 0)(local.get 1)(local.get 2)))
 (func (export "addr")(param i32)(result i32)  ;; pointer arith: store at base-12 then load
   (i32.store (i32.sub (local.get 0)(i32.const 12))(i32.const 99))
   (i32.load (i32.sub (local.get 0)(i32.const 12)))))
