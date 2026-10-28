(* Str keeps match state in globals, so every match-and-extract runs under one lock; the
   recursion runs stages on threads. *)

let lock = Mutex.create ()

let locked f =
  Mutex.lock lock;
  match f () with
  | v -> Mutex.unlock lock; v
  | exception e -> Mutex.unlock lock; raise e

(* Python re.fullmatch: Some groups (index 0 = whole match) or None. *)
let full_match re ~groups s =
  locked (fun () ->
      if Str.string_match re s 0 && Str.match_end () = String.length s then
        Some (List.init (groups + 1) (fun i -> try Str.matched_group i s with Not_found -> ""))
      else None)

let matches re s = full_match re ~groups:0 s <> None

(* Python re.search with one capture group, over the whole string. *)
let search_group re s =
  locked (fun () ->
      match Str.search_forward re s 0 with
      | _ -> Some (Str.matched_group 1 s)
      | exception Not_found -> None)

(* Python re.findall with one capture group. *)
let find_all_group re s =
  locked (fun () ->
      let rec go pos acc =
        match Str.search_forward re s pos with
        | exception Not_found -> List.rev acc
        | _ ->
            let g = Str.matched_group 1 s in
            let next = max (Str.match_end ()) (pos + 1) in
            if next > String.length s then List.rev (g :: acc) else go next (g :: acc)
      in
      go 0 [])

(* Text between an opening and closing tag, like the selector's <why>(.*?)</why>. *)
let between ~open_ ~close s =
  match Fs.index_of ~sub:open_ s with
  | None -> None
  | Some i -> (
      let start = i + String.length open_ in
      let rest = String.sub s start (String.length s - start) in
      match Fs.index_of ~sub:close rest with
      | None -> None
      | Some j -> Some (String.sub rest 0 j))

(* Lines matching "^key:\s*value" in a frontmatter-like header. *)
let line_value ~key s =
  List.find_map
    (fun l ->
      let p = key ^ ":" in
      if Fs.starts_with ~prefix:p l then
        let v = Fs.trim (String.sub l (String.length p) (String.length l - String.length p)) in
        Some v
      else None)
    (Fs.lines s)
