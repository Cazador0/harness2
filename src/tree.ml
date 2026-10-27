(* Copyright 2026 the caml-harness authors. Licensed under the Apache License, Version 2.0.
   Re-implements parts of Harness2 (Copyright 2026 Google LLC, Apache-2.0); see NOTICE. *)

(* The editable harness: eight components (c1..c8) as a variant, and a tree of files.

   Python keeps the surface as path regexes and asks `is_allowed(rel)`. Here every path is
   classified into a [component]; a path with no component is off the surface, and every
   `match` over components is checked for exhaustiveness by the compiler. *)

module SMap = Map.Make (String)

type t = string SMap.t (* rel path -> file content *)

type component =
  | System_prompt (* c1 *)
  | Guardrails (* c2 *)
  | Memory (* c3 *)
  | Tool_guidance (* c4 *)
  | Subagent of string (* c5: sub_agents/<name>/AGENT.md *)
  | Skill of string (* c6: skills/<name>/SKILL.md *)
  | Skill_asset of string (* c6: skills/<name>/scripts/<file> *)
  | Script of string (* c7: scripts/<name>.py *)
  | Plugin of string (* c8: plugin/<name>.ts *)

let component_id = function
  | System_prompt -> "c1"
  | Guardrails -> "c2"
  | Memory -> "c3"
  | Tool_guidance -> "c4"
  | Subagent _ -> "c5"
  | Skill _ | Skill_asset _ -> "c6"
  | Script _ -> "c7"
  | Plugin _ -> "c8"

type skill_name_rule = Must_match | May_override

type surface = {
  name : string;
  always_on : (string * component) list;
  always_on_max : int;
  always_on_cap_reason : string;
  skill_dir : string;
  skill_name_rule : skill_name_rule;
  trigger_hint : string; (* "{name}" is replaced *)
  autotrigger_file : string;
  trigger_line : string; (* "{name}" and "{desc}" are replaced *)
  subagent_requires_mode : bool;
  plugin_dir : string option;
  reject_empty_always_on : bool;
  stubs : (string * string) list;
}

let opencode =
  {
    name = "opencode";
    always_on =
      [
        ("systemprompt.md", System_prompt);
        ("guardrails.md", Guardrails);
        ("LongTermMEMORY.md", Memory);
        ("tool_descriptions/tool_guidance.md", Tool_guidance);
      ];
    always_on_max = 24_000;
    always_on_cap_reason = "every token here competes with the agent's own output budget";
    skill_dir = "skills";
    skill_name_rule = Must_match;
    trigger_hint =
      "Fix it by adding a trigger line naming `{name}` to systemprompt.md or guardrails.md, \
       e.g. \"When <the situation this skill handles>, load the `{name}` skill.\"";
    autotrigger_file = "guardrails.md";
    trigger_line = "- When {desc}, load the `{name}` skill.\n";
    subagent_requires_mode = true;
    plugin_dir = Some "plugin";
    reject_empty_always_on = false;
    stubs =
      [
        ( "scripts/README.md",
          "<!-- c7: deterministic helpers, run as `python3 scripts/<name>.py`. Add one by \
           emitting scripts/<name>.py. -->\n" );
        ( "sub_agents/README.md",
          "<!-- c5: delegated subagents, invoked with the `task` tool in their OWN context. \
           Add one as sub_agents/<name>/AGENT.md with frontmatter `mode: subagent` and \
           `description:`. -->\n" );
        ( "plugin/README.md",
          "<!-- c8: OpenCode plugins. Acts INSIDE the tool loop -- the only lever that can \
           enforce something the model cannot skip. Add one as plugin/<name>.ts. -->\n" );
        ( "skills/README.md",
          "<!-- c6: reusable workflows loaded on demand via the `skill` tool. Add one as \
           skills/<name>/SKILL.md with frontmatter `name:` matching the directory and a \
           `description:`. -->\n" );
      ];
  }

let reserved_scripts = [ "read_doc.py"; "pack.py"; "unpack.py" ]
let fill tmpl pairs = List.fold_left (fun s (k, v) -> Fs.replace_all ~sub:("{" ^ k ^ "}") ~by:v s) tmpl pairs

(* ---- classification ---------------------------------------------------------------- *)

let name_rx = "\\([a-z0-9][-a-z0-9_]*\\)"
let quote = Str.quote

let rx_skill s = Str.regexp (quote s.skill_dir ^ "/" ^ name_rx ^ "/SKILL\\.md")
let rx_skill_asset s = Str.regexp (quote s.skill_dir ^ "/" ^ name_rx ^ "/scripts/[-A-Za-z0-9_.]+")
let rx_subagent = Str.regexp ("sub_agents/" ^ name_rx ^ "/AGENT\\.md")
let rx_script = Str.regexp "scripts/\\([a-z0-9_][a-z0-9_]*\\)\\.py"
let rx_plugin dir = Str.regexp (quote dir ^ "/" ^ name_rx ^ "\\.ts")

let normalize_rel rel =
  let r = String.map (fun c -> if c = '\\' then '/' else c) (Fs.trim rel) in
  if Fs.starts_with ~prefix:"/" r || List.mem ".." (String.split_on_char '/' r) then
    Error (Printf.sprintf "path escapes the harness: %S" rel)
  else begin
    let r = ref r in
    while Fs.starts_with ~prefix:"./" !r do r := String.sub !r 2 (String.length !r - 2) done;
    let s = !r in
    let a = ref 0 and b = ref (String.length s) in
    while !a < !b && s.[!a] = '/' do incr a done;
    while !b > !a && s.[!b - 1] = '/' do decr b done;
    Ok (String.sub s !a (!b - !a))
  end

let classify s rel =
  match normalize_rel rel with
  | Error _ -> None
  | Ok rel -> (
      match List.assoc_opt rel s.always_on with
      | Some c -> Some c
      | None -> (
          let one re = Option.map (fun g -> List.nth g 1) (Rx.full_match re ~groups:1 rel) in
          match one (rx_skill s) with
          | Some n -> Some (Skill n)
          | None -> (
              match one (rx_skill_asset s) with
              | Some n -> Some (Skill_asset n)
              | None -> (
                  match one rx_subagent with
                  | Some n -> Some (Subagent n)
                  | None -> (
                      match one rx_script with
                      | Some n -> Some (Script n)
                      | None -> (
                          match s.plugin_dir with
                          | Some d -> Option.map (fun n -> Plugin n) (one (rx_plugin d))
                          | None -> None))))))

let is_allowed s rel = classify s rel <> None
let is_stub s rel = List.mem_assoc rel s.stubs

let names_of s tree pick =
  SMap.fold (fun rel _ acc -> match classify s rel with Some c -> (match pick c with Some n -> n :: acc | None -> acc) | None -> acc) tree []
  |> List.sort_uniq compare

let skill_names s tree = names_of s tree (function Skill n -> Some n | _ -> None)
let subagent_names s tree = names_of s tree (function Subagent n -> Some n | _ -> None)

(* ---- tree IO --------------------------------------------------------------------------- *)

let read_tree ?rejected s dir =
  List.fold_left
    (fun acc rel ->
      if Fs.has_part "__pycache__" rel || is_stub s rel then acc
      else if not (is_allowed s rel) then begin
        Option.iter (fun r -> r := rel :: !r) rejected;
        acc
      end
      else SMap.add rel (Fs.read (Fs.( / ) dir rel)) acc)
    SMap.empty (Fs.walk dir)

let is_tree s dir = Fs.is_dir dir && List.exists (fun (a, _) -> Fs.is_file (Fs.( / ) dir a)) s.always_on

(* Materialise an exact editable tree. Files outside the surface are preserved. *)
let write_tree ?(stubs = true) s tree dest =
  let open Fs in
  mkdir_p dest;
  List.iter (fun rel -> if is_allowed s rel || is_stub s rel then Sys.remove (dest / rel)) (walk dest);
  List.iter (fun (a, _) -> if not (SMap.mem a tree) && not (Sys.file_exists (dest / a)) then write (dest / a) "") s.always_on;
  SMap.iter
    (fun rel content -> match normalize_rel rel with Ok r -> write (dest / r) content | Error e -> invalid_arg e)
    tree;
  if stubs then List.iter (fun (rel, body) -> if not (Sys.file_exists (dest / rel)) then write (dest / rel) body) s.stubs;
  dest

let always_on_text s tree =
  String.concat "\n\n" (List.map (fun (a, _) -> Option.value (SMap.find_opt a tree) ~default:"") s.always_on)

let head600 s = if String.length s > 600 then String.sub s 0 600 else s

(* Give every skill a trigger line in always-on text; return the names repaired. *)
let autotrigger s tree =
  let tree = ref tree and fixed = ref [] in
  List.iter
    (fun name ->
      if not (Fs.contains ~sub:name (always_on_text s !tree)) then begin
        let fm = head600 (Option.value (SMap.find_opt (s.skill_dir ^ "/" ^ name ^ "/SKILL.md") !tree) ~default:"") in
        let desc =
          match Rx.line_value ~key:"description" fm with
          | Some d when d <> "" ->
              let d = Fs.trim d in
              if Fs.ends_with ~suffix:"." d then String.sub d 0 (String.length d - 1) else d
          | _ -> Printf.sprintf "the %s workflow applies" name
        in
        let line = fill s.trigger_line [ ("name", name); ("desc", desc) ] in
        let cur = Option.value (SMap.find_opt s.autotrigger_file !tree) ~default:"" in
        if String.length (always_on_text s !tree) + String.length line + 2 <= s.always_on_max then begin
          let body = if Fs.trim cur <> "" then Fs.trim_right cur ^ "\n" ^ line else line in
          tree := SMap.add s.autotrigger_file body !tree;
          fixed := name :: !fixed
        end
      end)
    (skill_names s !tree);
  (!tree, List.rev !fixed)

(* ---- validation ------------------------------------------------------------------------ *)

type census = { always_on_chars : int; n_files : int; skills : int; sub_agents : int; scripts : int; plugins : int }

let py_compiles rel src =
  let code, _, err =
    Fs.run ~stdin_text:src
      [ "python3"; "-I"; "-c"; "import sys\ncompile(sys.stdin.read(), sys.argv[1], 'exec')"; rel ]
  in
  if code = 0 then None
  else
    let last = match List.rev (Fs.lines err) with l :: _ -> l | [] -> "SyntaxError" in
    Some (Printf.sprintf "%s does not compile: %s" rel (if String.length last > 160 then String.sub last 0 160 else last))

let script_ref_rx s =
  Str.regexp ("python3?[ \t\n]+\\(\\(" ^ quote s.skill_dir ^ "/[-A-Za-z0-9_]+/\\)?scripts/[-A-Za-z0-9_.]+\\.py\\)")

let validate ?(allow_subagents = true) ?(reserved = reserved_scripts) s tree : (census, string list) result =
  let errs = ref [] in
  let err e = errs := e :: !errs in
  let body = always_on_text s tree in
  if String.length body > s.always_on_max then
    err (Printf.sprintf "always-on content is %d chars, over the %d cap; %s" (String.length body) s.always_on_max s.always_on_cap_reason);
  if s.reject_empty_always_on && Fs.trim body = "" then
    err (Printf.sprintf "%s is empty -- an empty one is a harness that does not exist" (fst (List.hd s.always_on)));
  let skills = skill_names s tree in
  List.iter
    (fun name ->
      let path = s.skill_dir ^ "/" ^ name ^ "/SKILL.md" in
      let fm = head600 (SMap.find path tree) in
      (match Rx.line_value ~key:"description" fm with
       | Some d when d <> "" -> ()
       | _ -> err (path ^ " needs a `description:` in its frontmatter, or the skill is dropped SILENTLY at load"));
      let declared = Rx.line_value ~key:"name" fm in
      (match (s.skill_name_rule, declared) with
       | Must_match, Some n when n = name -> ()
       | Must_match, _ ->
           err (Printf.sprintf "%s needs frontmatter `name: %s` matching its directory (a mismatch is dropped SILENTLY at load)" path name)
       | May_override, Some n when n <> name ->
           err (Printf.sprintf "%s frontmatter `name: %s` OVERRIDES the directory name at load; drop the `name:` line or make it `name: %s`" path n name)
       | May_override, _ -> ());
      if not (Fs.contains ~sub:name body) then
        err
          (Printf.sprintf "skill '%s' is never named in the always-on text, so the agent will not know to invoke it -- an untriggered skill is dead weight. %s" name
             (fill s.trigger_hint [ ("name", name) ])))
    skills;
  let subs = subagent_names s tree in
  if subs <> [] && not allow_subagents then
    err ("sub_agents are not available on this deployment: " ^ String.concat ", " subs);
  List.iter
    (fun name ->
      let path = "sub_agents/" ^ name ^ "/AGENT.md" in
      let fm = head600 (SMap.find path tree) in
      if s.subagent_requires_mode && Rx.line_value ~key:"mode" fm <> Some "subagent" then
        err (path ^ " needs frontmatter `mode: subagent`");
      match Rx.line_value ~key:"description" fm with
      | Some d when d <> "" -> ()
      | _ -> err (path ^ " needs a `description:`"))
    subs;
  SMap.iter
    (fun rel src -> match classify s rel with Some (Script _) -> Option.iter err (py_compiles rel src) | _ -> ())
    tree;
  let shipped = SMap.filter (fun rel _ -> match classify s rel with Some (Script _ | Skill_asset _) -> true | _ -> false) tree in
  let rx = script_ref_rx s in
  SMap.iter
    (fun rel src ->
      let invokes = match classify s rel with Some (Skill _ | System_prompt | Guardrails | Memory | Tool_guidance) -> true | _ -> false in
      if invokes then
        List.iter
          (fun r ->
            if not (List.mem (Filename.basename r) reserved) && not (SMap.mem r shipped) then
              err (Printf.sprintf "%s invokes `%s` but that file is not in the harness" rel r))
          (Rx.find_all_group rx src))
    tree;
  match List.rev !errs with
  | [] ->
      let count p = SMap.fold (fun rel _ n -> match classify s rel with Some c when p c -> n + 1 | _ -> n) tree 0 in
      Ok
        {
          always_on_chars = String.length body;
          n_files = SMap.cardinal tree;
          skills = List.length skills;
          sub_agents = List.length subs;
          scripts = count (function Script _ -> true | _ -> false);
          plugins = count (function Plugin _ -> true | _ -> false);
        }
  | es -> Error es

(* ---- comparison ------------------------------------------------------------------------ *)

type diff = { added : string list; removed : string list; modified : string list; always_on_char_delta : int }

let diff_summary s before after =
  let keys m = List.map fst (SMap.bindings m) in
  {
    added = List.filter (fun k -> not (SMap.mem k before)) (keys after);
    removed = List.filter (fun k -> not (SMap.mem k after)) (keys before);
    modified = List.filter (fun k -> match SMap.find_opt k after with Some v -> v <> SMap.find k before | None -> false) (keys before);
    always_on_char_delta = String.length (always_on_text s after) - String.length (always_on_text s before);
  }

let unchanged s before after =
  let d = diff_summary s before after in
  d.added = [] && d.removed = [] && d.modified = []

(* Pairwise line-Jaccard over candidate trees, so collapse to one body is visible. *)
let diversity (trees : (string * t) list) =
  let module SS = Set.Make (String) in
  let names = List.sort compare (List.map fst trees) in
  let n = List.length names in
  if n < 2 then (n, n, 1.0)
  else begin
    let lines t = SMap.fold (fun rel c acc -> List.fold_left (fun acc l -> if Fs.trim l = "" then acc else SS.add (rel ^ ":" ^ l) acc) acc (Fs.lines c)) t SS.empty in
    let sets = List.map (fun nm -> (nm, lines (List.assoc nm trees))) names in
    let sims = ref [] in
    List.iteri
      (fun i (_, a) ->
        List.iteri
          (fun j (_, b) ->
            if j > i then
              let u = SS.cardinal (SS.union a b) in
              sims := (if u = 0 then 1.0 else float (SS.cardinal (SS.inter a b)) /. float u) :: !sims)
          sets)
      sets;
    let distinct = List.length (List.sort_uniq compare (List.map (fun (_, t) -> SMap.bindings t) trees)) in
    let mean = List.fold_left ( +. ) 0. !sims /. float (List.length !sims) in
    (n, distinct, Float.round (mean *. 10000.) /. 10000.)
  end
