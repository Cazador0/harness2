(* Copyright 2026 the caml-harness authors. Licensed under the Apache License, Version 2.0.
   Re-implements parts of Harness2 (Copyright 2026 Google LLC, Apache-2.0); see NOTICE. *)

(* The per-domain experience library (Python: core/library.py).

     <root>/<mode>/<domain>/INDEX.md
     <root>/<mode>/<domain>/harnesses/<task>/harness/<rel>   the full adopted tree
     <root>/<mode>/<domain>/harnesses/<task>/EXPERIENCE.md   why picked + lesson *)

open Fs

type t = { root : string; domain : string; surface : Tree.surface }

let slug task_id = replace_all ~sub:"/" ~by:"__" task_id

(* One directory name for a domain: separators and the whitespace around them become "__". *)
let sep_rx = Str.regexp "[ \t\n]*[/\\][ \t\n]*"
let domain_dir domain = match trim (Rx.locked (fun () -> Str.global_replace sep_rx "__" domain)) with "" -> "unknown" | s -> s

let dir t = t.root / domain_dir t.domain
let index t = dir t / "INDEX.md"
let entry_dir t task_id = dir t / "harnesses" / slug task_id
(* The directory handed to an improver session, or None while the domain has no entry. *)
let context_dir t =
  if is_file (index t) && List.exists (fun rel -> Filename.basename rel = "EXPERIENCE.md") (walk (dir t)) then Some (dir t) else None

let entries t =
  let h = dir t / "harnesses" in
  if is_dir h then List.sort compare (List.filter (fun n -> is_dir (h / n)) (Array.to_list (Sys.readdir h))) else []

let commas n =
  let s = string_of_int n in
  let len = String.length s in
  String.concat "" (List.init len (fun i -> (if i > 0 && (len - i) mod 3 = 0 then "," else "") ^ String.make 1 s.[i]))

(* A one-line census of the components actually in this harness. *)
let inventory (surface : Tree.surface) tree =
  let skills = ref 0 and subs = ref 0 and scripts = ref 0 and plugins = ref 0 in
  Tree.SMap.iter
    (fun rel _ ->
      if starts_with ~prefix:(surface.skill_dir ^ "/") rel && ends_with ~suffix:"SKILL.md" rel then incr skills
      else if starts_with ~prefix:"sub_agents/" rel then incr subs
      else if starts_with ~prefix:"scripts/" rel then incr scripts
      else match surface.plugin_dir with Some d when starts_with ~prefix:(d ^ "/") rel -> incr plugins | _ -> ())
    tree;
  let bits =
    List.filter_map (fun (n, k) -> if n > 0 then Some (Printf.sprintf "%d %s" n k) else None)
      [ (!skills, "skills"); (!subs, "sub_agents"); (!scripts, "scripts"); (!plugins, "plugins") ]
  in
  let bits = if bits = [] then [ "always-on edits only" ] else bits in
  Printf.sprintf "%s; %s always-on chars" (String.concat ", " bits) (commas (String.length (Tree.always_on_text surface tree)))

let field path name =
  if not (is_file path) then ""
  else
    let p = "- **" ^ name ^ "**:" in
    match List.find_opt (starts_with ~prefix:p) (lines (read path)) with
    | Some l -> trim (String.sub l (String.length p) (String.length l - String.length p))
    | None -> ""

let rebuild_index t =
  let rows =
    [ "# Library — " ^ t.domain; "";
      "Each entry is an earlier task in THIS domain whose harness was chosen, stored with its FULL component tree and why it was picked. Browse this index, then open the entries that look relevant to the matter in front of you.";
      "" ]
  in
  let body =
    match entries t with
    | [] -> [ "_(empty — this is the first task in this domain)_" ]
    | names ->
        List.concat_map
          (fun name ->
            let ed = dir t / "harnesses" / name in
            let cue = field (ed / "EXPERIENCE.md") "cue" in
            let tree = Tree.read_tree t.surface (ed / "harness") in
            [ Printf.sprintf "## `harnesses/%s/`" name;
              Printf.sprintf "- harness: `harnesses/%s/harness/` — %s" name (inventory t.surface tree);
              Printf.sprintf "- why:     `harnesses/%s/EXPERIENCE.md`" name ]
            @ (if cue <> "" then [ "- cue:     " ^ cue ] else [])
            @ [ "" ])
          names
  in
  write (index t) (String.concat "\n" (rows @ body))

let has_experience exp = List.for_all (fun k -> match List.assoc_opt k exp with Some v -> v <> "" | None -> false) [ "cue"; "lesson"; "evidence" ]

let forget t task_ids =
  let removed = List.filter (fun id -> is_dir (entry_dir t id)) task_ids in
  List.iter (fun id -> rm_rf (entry_dir t id)) removed;
  if removed <> [] then rebuild_index t

(* Keep only the entries preceding the current task in this stream. *)
let retain t task_ids =
  let keep = List.map slug task_ids in
  forget t (List.filter (fun e -> not (List.mem e keep)) (entries t))

let add t task_id tree ~why ~label ~run_id ~experience =
  if not (has_experience experience) then Ok None
  else
    match Context.tree_grader_verdict tree with
    | Some e -> Error e
    | None ->
        let d = entry_dir t task_id in
        rm_rf (d / "harness");
        mkdir_p (d / "harness");
        ignore (Tree.write_tree ~stubs:false t.surface tree (d / "harness"));
        let get k = Option.value (List.assoc_opt k experience) ~default:"" in
        let ls =
          [ "# " ^ task_id; ""; Printf.sprintf "- adopted: `%s`" label ^ (if run_id <> "" then Printf.sprintf "  (run `%s`)" run_id else "");
            "- components: " ^ inventory t.surface tree; "" ]
          @ (if trim why <> "" then [ "## Why this was chosen"; trim why; "" ] else [])
          @ (if get "edits" <> "" then [ "## What each edit did"; trim (get "edits"); "" ] else [])
          @
          if get "lesson" <> "" then
            [ "## Transferable lesson" ]
            @ List.filter_map (fun f -> if get f <> "" then Some (Printf.sprintf "- **%s**: %s" f (trim (get f))) else None) [ "cue"; "lesson"; "evidence"; "confidence" ]
            @ [ "" ]
          else []
        in
        write (d / "EXPERIENCE.md") (String.concat "\n" ls);
        rebuild_index t;
        Ok (Some d)
