(* Copyright 2026 the caml-harness authors. Licensed under the Apache License, Version 2.0.
   Re-implements parts of Harness2 (Copyright 2026 Google LLC, Apache-2.0); see NOTICE. *)

(* CPython's random.Random (MT19937 + init_by_array + shuffle), reproduced exactly.

   selection.assign_ids seeds random.Random with a SHA-1-derived integer and shuffles the
   candidate labels. Matching it bit for bit means the OCaml port shows the selector the
   same anonymous IDs as the Python release, so the two pick the same candidate. *)

let n = 624
let m = 397
let mask = 0xFFFFFFFF

type t = { mt : int array; mutable idx : int }

let init_genrand s =
  let mt = Array.make n 0 in
  mt.(0) <- s land mask;
  for i = 1 to n - 1 do
    mt.(i) <- ((1812433253 * (mt.(i - 1) lxor (mt.(i - 1) lsr 30))) + i) land mask
  done;
  mt

let init_by_array key =
  let mt = init_genrand 19650218 in
  let klen = Array.length key in
  let i = ref 1 and j = ref 0 in
  for _ = max n klen downto 1 do
    let prev = mt.(!i - 1) in
    mt.(!i) <- ((mt.(!i) lxor ((prev lxor (prev lsr 30)) * 1664525)) + key.(!j) + !j) land mask;
    incr i;
    incr j;
    if !i >= n then (mt.(0) <- mt.(n - 1); i := 1);
    if !j >= klen then j := 0
  done;
  for _ = n - 1 downto 1 do
    let prev = mt.(!i - 1) in
    mt.(!i) <- ((mt.(!i) lxor ((prev lxor (prev lsr 30)) * 1566083941)) - !i) land mask;
    incr i;
    if !i >= n then (mt.(0) <- mt.(n - 1); i := 1)
  done;
  mt.(0) <- 0x80000000;
  mt

(* random.Random(seed) for a non-negative int seed: the key is its 32-bit words, low first. *)
let of_int seed =
  let rec words s = if s = 0 then [] else (s land mask) :: words (s lsr 32) in
  let key = match words (abs seed) with [] -> [| 0 |] | ws -> Array.of_list ws in
  { mt = init_by_array key; idx = n }

let genrand st =
  if st.idx >= n then begin
    let mt = st.mt in
    let mag y = if y land 1 = 0 then 0 else 0x9908b0df in
    for kk = 0 to n - 1 do
      let y = (mt.(kk) land 0x80000000) lor (mt.((kk + 1) mod n) land 0x7fffffff) in
      mt.(kk) <- mt.((kk + m) mod n) lxor (y lsr 1) lxor mag y
    done;
    st.idx <- 0
  end;
  let y = st.mt.(st.idx) in
  st.idx <- st.idx + 1;
  let y = y lxor (y lsr 11) in
  let y = y lxor ((y lsl 7) land 0x9d2c5680) in
  let y = y lxor ((y lsl 15) land 0xefc60000) in
  (y lxor (y lsr 18)) land mask

let getrandbits st k = if k <= 0 then 0 else genrand st lsr (32 - k)

let bit_length x =
  let rec go x acc = if x = 0 then acc else go (x lsr 1) (acc + 1) in
  go x 0

let randbelow st bound =
  let k = bit_length bound in
  let rec draw () = let r = getrandbits st k in if r >= bound then draw () else r in
  draw ()

let shuffle st (a : 'a array) =
  for i = Array.length a - 1 downto 1 do
    let j = randbelow st (i + 1) in
    let t = a.(i) in
    a.(i) <- a.(j);
    a.(j) <- t
  done
