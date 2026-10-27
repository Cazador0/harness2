(* Jev channel: the seam where Jev would plug into the improver/selector/reflector role.

   STATUS: NOT WIRED TO JEV. typesafe.ai could not be reached from the session that wrote
   this prototype, so nothing here assumes Jev's API, CLI or model names. What exists is the
   integration point and the contract Jev must meet:

     input   the mission text on stdin, run with its working directory set to a scratch
             copy of the sealed context (context/...)
     output  the reply text on stdout (the same tags the other channels return: <notes>,
             ```choice, <why>, <edits>, <experience>)
     effect  any harness edits made in place under context/harness/, harvested afterwards

   Configure the command with HARNESS2_JEV_CMD, e.g. HARNESS2_JEV_CMD="jev run --model X".
   The words are split on spaces; the mission arrives on stdin. Until that is set, every
   call fails with Proposer_error, which the recursion handles as it would any channel
   failure (retry once, then keep the current harness). *)

let env_cmd = "HARNESS2_JEV_CMD"

let session () : Proposer.session =
 fun ~cwd ~mission ->
  match Sys.getenv_opt env_cmd with
  | None | Some "" ->
      ("", 0., env_cmd ^ " is not set; the Jev channel has no command to run (see experiment/src/jev.ml)")
  | Some cmd ->
      let words = List.filter (( <> ) "") (String.split_on_char ' ' cmd) in
      let code, out, err = Fs.run ~stdin_text:mission ([ "sh"; "-c"; "cd \"$0\" && shift && exec \"$@\""; cwd; "_" ] @ words) in
      if Fs.trim out = "" then ("", 0., Printf.sprintf "rc=%d: %s" code (Fs.trim err)) else (out, 0., "")

let proposer ?(model = "jev/unspecified") () =
  Proposer.of_session { Spec.kind = Spec.Jev; model; effort = "high"; steps = 120; timeout = 3600 } (session ())
