(* Copyright 2026 the caml-harness authors. Licensed under the Apache License, Version 2.0.
   Re-implements parts of Harness2 (Copyright 2026 Google LLC, Apache-2.0); see NOTICE. *)

(* SHA-1, so anonymous candidate IDs and harness fingerprints match the Python release
   byte for byte (Python uses hashlib.sha1 for both). *)

let mask = 0xFFFFFFFF
let rotl x n = ((x lsl n) lor (x lsr (32 - n))) land mask

let hex (s : string) : string =
  let ml = String.length s in
  let pad = let r = (ml + 9) mod 64 in if r = 0 then 0 else 64 - r in
  let total = ml + 9 + pad in
  let b = Bytes.make total '\000' in
  Bytes.blit_string s 0 b 0 ml;
  Bytes.set b ml '\x80';
  let bits = ml * 8 in
  for i = 0 to 7 do
    Bytes.set b (total - 1 - i) (Char.chr ((bits lsr (8 * i)) land 0xff))
  done;
  let h = [| 0x67452301; 0xEFCDAB89; 0x98BADCFE; 0x10325476; 0xC3D2E1F0 |] in
  let w = Array.make 80 0 in
  let byte o = Char.code (Bytes.get b o) in
  for chunk = 0 to (total / 64) - 1 do
    for i = 0 to 15 do
      let o = (chunk * 64) + (i * 4) in
      w.(i) <- (byte o lsl 24) lor (byte (o + 1) lsl 16) lor (byte (o + 2) lsl 8) lor byte (o + 3)
    done;
    for i = 16 to 79 do
      w.(i) <- rotl (w.(i - 3) lxor w.(i - 8) lxor w.(i - 14) lxor w.(i - 16)) 1
    done;
    let a = ref h.(0) and bb = ref h.(1) and c = ref h.(2) and d = ref h.(3) and e = ref h.(4) in
    for i = 0 to 79 do
      let f, k =
        if i < 20 then ((!bb land !c) lor (lnot !bb land mask land !d), 0x5A827999)
        else if i < 40 then (!bb lxor !c lxor !d, 0x6ED9EBA1)
        else if i < 60 then ((!bb land !c) lor (!bb land !d) lor (!c land !d), 0x8F1BBCDC)
        else (!bb lxor !c lxor !d, 0xCA62C1D6)
      in
      let temp = (rotl !a 5 + f + !e + k + w.(i)) land mask in
      e := !d;
      d := !c;
      c := rotl !bb 30;
      bb := !a;
      a := temp
    done;
    h.(0) <- (h.(0) + !a) land mask;
    h.(1) <- (h.(1) + !bb) land mask;
    h.(2) <- (h.(2) + !c) land mask;
    h.(3) <- (h.(3) + !d) land mask;
    h.(4) <- (h.(4) + !e) land mask
  done;
  String.concat "" (Array.to_list (Array.map (Printf.sprintf "%08x") h))
