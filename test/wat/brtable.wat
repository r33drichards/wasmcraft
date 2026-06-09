(module
 (func (export "sw")(param i32)(result i32)
   (block $d (block $c (block $b (block $a
     (br_table $a $b $c $d (local.get 0)))
     (return (i32.const 10)))
     (return (i32.const 20)))
     (return (i32.const 30)))
   (i32.const 99)))
