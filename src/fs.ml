(* Copyright 2026 the caml-harness authors. Licensed under the Apache License, Version 2.0.
   Re-implements parts of Harness2 (Copyright 2026 Google LLC, Apache-2.0); see NOTICE. *)

(* Filesystem helpers shared by every module; the Python code uses pathlib + shutil. *)

let ( / ) = Filename.concat

let is_dir p = Sys.file_exists p && Sys.is_directory p
let is_file p = Sys.file_exists p && not (Sys.is_directory p)

let rec mkdir_p d =
  if d <> "" && d <> "/" && d <> "." && not (Sys.file_exists d) then begin
    mkdir_p (Filename.dirname d);
    try Unix.mkdir d 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let read p = In_channel.with_open_bin p In_channel.input_all

let write p s =
  mkdir_p (Filename.dirname p);
  Out_channel.with_open_bin p (fun oc -> output_string oc s)

let rec rm_rf p =
  match Unix.lstat p with
  | exception Unix.Unix_error _ -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun n -> rm_rf (p / n)) (Sys.readdir p);
      Unix.rmdir p
  | _ -> Sys.remove p

(* Every file under [root], as sorted "a/b/c" relative paths. *)
let walk root =
  let acc = ref [] in
  let rec go rel =
    let abs = if rel = "" then root else root / rel in
    Array.iter
      (fun n ->
        let r = if rel = "" then n else rel ^ "/" ^ n in
        if is_dir (root / r) then go r else acc := r :: !acc)
      (Sys.readdir abs)
  in
  if is_dir root then go "";
  (* pathlib orders paths component by component, not as flat strings *)
  let parts = String.split_on_char '/' in
  List.sort (fun a b -> compare (parts a) (parts b)) !acc

let has_part part rel = List.mem part (String.split_on_char '/' rel)

(* Copy a component tree, dropping byte-compiled files; return the file count. *)
let copy_tree src dst =
  List.fold_left
    (fun n rel ->
      if has_part "__pycache__" rel || Filename.check_suffix rel ".pyc" then n
      else begin
        write (dst / rel) (read (src / rel));
        n + 1
      end)
    0 (walk src)

let suffix rel =
  let base = Filename.basename rel in
  match String.rindex_opt base '.' with
  | Some 0 | None -> ""
  | Some i -> String.lowercase_ascii (String.sub base i (String.length base - i))

let contains ~sub s =
  let n = String.length sub and m = String.length s in
  let rec go i = i + n <= m && (String.sub s i n = sub || go (i + 1)) in
  n = 0 || go 0

let index_of ~sub s =
  let n = String.length sub and m = String.length s in
  let rec go i = if i + n > m then None else if String.sub s i n = sub then Some i else go (i + 1) in
  go 0

let starts_with ~prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

let ends_with ~suffix s =
  let n = String.length suffix and m = String.length s in
  m >= n && String.sub s (m - n) n = suffix

let replace_all ~sub ~by s =
  let n = String.length sub in
  if n = 0 then s
  else begin
    let b = Buffer.create (String.length s) in
    let rec go i =
      if i > String.length s - n then Buffer.add_string b (String.sub s i (String.length s - i))
      else if String.sub s i n = sub then (Buffer.add_string b by; go (i + n))
      else (Buffer.add_char b s.[i]; go (i + 1))
    in
    go 0;
    Buffer.contents b
  end

let trim = String.trim

(* Python str.splitlines() for \n and \r\n text. *)
let lines s =
  let parts = String.split_on_char '\n' s in
  let parts = List.map (fun l -> if ends_with ~suffix:"\r" l then String.sub l 0 (String.length l - 1) else l) parts in
  match List.rev parts with "" :: rest -> List.rev rest | _ -> parts

(* Run a command, returning (exit code, stdout, stderr). *)
let run ?stdin_text argv =
  let out_f = Filename.temp_file "h2ml" ".out" and err_f = Filename.temp_file "h2ml" ".err" in
  let in_f = Filename.temp_file "h2ml" ".in" in
  write in_f (Option.value stdin_text ~default:"");
  let cmd =
    String.concat " " (List.map Filename.quote argv)
    ^ " < " ^ Filename.quote in_f ^ " > " ^ Filename.quote out_f ^ " 2> " ^ Filename.quote err_f
  in
  let code = Sys.command cmd in
  let o = read out_f and e = read err_f in
  List.iter Sys.remove [ out_f; err_f; in_f ];
  (code, o, e)

let trim_right s =
  let n = ref (String.length s) in
  while !n > 0 && (match s.[!n - 1] with ' ' | '\t' | '\n' | '\r' -> true | _ -> false) do decr n done;
  String.sub s 0 !n

(* A worker pool of [width] threads over [xs], results in input order; the first exception
   raised by [f] is re-raised once every worker has stopped. *)
let parallel_map ~width f xs =
  let arr = Array.of_list xs in
  let n = Array.length arr in
  let res = Array.make n None in
  let next = ref 0 and m = Mutex.create () in
  let rec worker () =
    Mutex.lock m;
    let i = !next in
    incr next;
    Mutex.unlock m;
    if i < n then begin
      res.(i) <- Some (try Ok (f arr.(i)) with e -> Error e);
      worker ()
    end
  in
  let ts = List.init (max 1 (min width n)) (fun _ -> Thread.create worker ()) in
  List.iter Thread.join ts;
  Array.to_list (Array.map (function Some (Ok v) -> v | Some (Error e) -> raise e | None -> assert false) res)
