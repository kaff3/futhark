-- Ascription only needs a subtype.
-- ==
-- input { 2 } output { [0,0] }

module type S = { val f: i32 -> []i32 }

module M: S = {
  let f(x: i32): *[]i32 = replicate (i64.i32 x) 0
}

let main(n: i32): []i32 = M.f n
