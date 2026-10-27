(* Copyright 2026 the caml-harness authors. Licensed under the Apache License, Version 2.0.
   Re-implements parts of Harness2 (Copyright 2026 Google LLC, Apache-2.0); see NOTICE. *)

(** Evidence trees handed to the improver, selector and reflector (Python: core/context.py).

    In Python the leak guards ([assert_no_leak_paths], [assert_no_grader_verdicts]) are
    tripwires that each call site must remember to run. Here a model can only be given a
    {!t}, {!t} is abstract, and the only ways to make one ({!build} and {!seal}) run both
    scans over the finished directory first. Skipping the guard is a type error.

    Limit (same as Python): a sealed directory could still be modified on disk afterwards;
    the proposer reads it immediately, and nothing in this code writes to it after sealing. *)

type t

val root : t -> string
val layout : t -> string

type pool_entry = { label : string; harness_dir : string; rollout : Spec.run_view option }

val build :
  string ->
  Spec.adapter ->
  string ->
  Spec.run_view list ->
  ?harness_dir:string ->
  ?library_dir:string ->
  ?pool:pool_entry list ->
  ?decisions:(string * string) list ->
  unit ->
  (t, string) result
(** Write the evidence tree at the given directory (replacing it), then scan and seal it. *)

val seal : string -> leak_globs:string list -> (t, string) result
(** Scan a directory assembled by hand (selection and reflection) and seal it. *)

val mission : t -> job:string -> string

val copy_source : Spec.adapter -> string -> string -> int
(** Copy task sources under [<root>/source], skipping answer-key paths. *)

val leak_paths : string -> string list -> string list
val grader_verdict : string -> string option
val tree_grader_verdict : Tree.t -> string option
val grader_verdict_markers : string list
