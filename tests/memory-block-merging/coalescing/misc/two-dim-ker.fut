-- Test2 Memory-Block Merging
--
-- For the CPU pipeline there is no coalescing to do in this program.  The
-- compiler makes sure there is only a single alloc before we even get to memory
-- block merging.
--
-- The GPU pipeline on the other hand does have one copy, and can be reduced
-- from 4 allocations to 3 allocations with a coalescing.
-- ==
-- input { [ [ [0i64, 1i64], [2i64, 3i64] ], [ [4i64, 5i64], [6i64, 7i64] ] ]  }
-- output { [[[0i64, 9i64], [0i64, 13i64]]]}
-- structure cpu { Alloc 1 }
-- structure gpu { Alloc 3 }

let main [n] (xsss: [n][n][n]i64): [][n][n]i64 =
  let (_,asss) = split (1) xsss
  in  map (\ass ->
                map (\as ->
                        let r = loop r = 0 for i < n do
                            let r = r + as[i]
                            in  r
                        in
                        loop bs = iota n for j < n do
                            let bs[j] = bs[j]*r
                            in bs
                    )
                    ass
          ) asss
