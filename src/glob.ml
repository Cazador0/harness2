(* Copyright 2026 the caml-harness authors. Licensed under the Apache License, Version 2.0.
   Re-implements parts of Harness2 (Copyright 2026 Google LLC, Apache-2.0); see NOTICE. *)

(* fnmatch.fnmatch as used by the leak guards: '*' and '?' match any character, '/' included. *)

let fnmatch ~pattern s =
  let pl = String.length pattern and sl = String.length s in
  let memo = Hashtbl.create 64 in
  let rec go i j =
    match Hashtbl.find_opt memo (i, j) with
    | Some v -> v
    | None ->
        let v =
          if i = pl then j = sl
          else
            match pattern.[i] with
            | '*' -> go (i + 1) j || (j < sl && go i (j + 1))
            | '?' -> j < sl && go (i + 1) (j + 1)
            | c -> j < sl && s.[j] = c && go (i + 1) (j + 1)
        in
        Hashtbl.add memo (i, j) v;
        v
  in
  go 0 0

let strip_dot_slash p =
  let p = String.map (fun c -> if c = '\\' then '/' else c) p in
  let n = String.length p in
  let i = ref 0 in
  while !i < n && (p.[!i] = '.' || p.[!i] = '/') do incr i done;
  String.sub p !i (n - !i)

(* The guard's rule: the pattern matches the path or any path suffix after a '/'. *)
let leak_match ~pattern rel =
  let pat = strip_dot_slash pattern in
  fnmatch ~pattern:pat rel || fnmatch ~pattern:("*/" ^ pat) rel
