(* A minimal JSON emitter (the summaries and selection records only need writing). *)

type t =
  | Null
  | Bool of bool
  | Int of int
  | Float of float
  | String of string
  | List of t list
  | Assoc of (string * t) list

let escape s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (function
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\r' -> Buffer.add_string b "\\r"
      | '\t' -> Buffer.add_string b "\\t"
      | c when Char.code c < 0x20 -> Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

let rec pp ind v =
  let pad n = String.make (2 * n) ' ' in
  match v with
  | Null -> "null"
  | Bool b -> string_of_bool b
  | Int i -> string_of_int i
  | Float f -> if Float.is_integer f then Printf.sprintf "%.1f" f else Printf.sprintf "%.17g" f
  | String s -> escape s
  | List [] -> "[]"
  | Assoc [] -> "{}"
  | List xs ->
      "[\n"
      ^ String.concat ",\n" (List.map (fun x -> pad (ind + 1) ^ pp (ind + 1) x) xs)
      ^ "\n" ^ pad ind ^ "]"
  | Assoc kv ->
      "{\n"
      ^ String.concat ",\n"
          (List.map (fun (k, x) -> pad (ind + 1) ^ escape k ^ ": " ^ pp (ind + 1) x) kv)
      ^ "\n" ^ pad ind ^ "}"

let to_string v = pp 0 v ^ "\n"
let strings xs = List (List.map (fun s -> String s) xs)

(* A small parser, enough for CLI JSON replies (claude -p --output-format json). *)
exception Parse_error of string

let parse (s : string) : t =
  let n = String.length s in
  let pos = ref 0 in
  let peek () = if !pos < n then s.[!pos] else '\000' in
  let rec ws () = if !pos < n && (match s.[!pos] with ' ' | '\t' | '\n' | '\r' -> true | _ -> false) then (incr pos; ws ()) in
  let expect c = ws (); if peek () <> c then raise (Parse_error (Printf.sprintf "expected %c at %d" c !pos)); incr pos in
  let lit w v = if !pos + String.length w <= n && String.sub s !pos (String.length w) = w then (pos := !pos + String.length w; v) else raise (Parse_error "bad literal") in
  let str () =
    expect '"';
    let b = Buffer.create 16 in
    let rec go () =
      if !pos >= n then raise (Parse_error "unterminated string");
      let c = s.[!pos] in
      incr pos;
      match c with
      | '"' -> ()
      | '\\' ->
          let e = s.[!pos] in
          incr pos;
          (match e with
           | 'n' -> Buffer.add_char b '\n' | 't' -> Buffer.add_char b '\t' | 'r' -> Buffer.add_char b '\r'
           | 'b' -> Buffer.add_char b '\b' | 'f' -> Buffer.add_char b '\012'
           | 'u' ->
               let code = int_of_string ("0x" ^ String.sub s !pos 4) in
               pos := !pos + 4;
               let u = if Uchar.is_valid code then Uchar.of_int code else Uchar.rep in
               Buffer.add_utf_8_uchar b u
           | c -> Buffer.add_char b c);
          go ()
      | c -> Buffer.add_char b c; go ()
    in
    go ();
    Buffer.contents b
  in
  let rec value () =
    ws ();
    match peek () with
    | '{' ->
        incr pos; ws ();
        if peek () = '}' then (incr pos; Assoc [])
        else
          let rec fields acc =
            let k = str () in
            expect ':';
            let v = value () in
            ws ();
            match peek () with
            | ',' -> incr pos; ws (); fields ((k, v) :: acc)
            | '}' -> incr pos; Assoc (List.rev ((k, v) :: acc))
            | _ -> raise (Parse_error "bad object")
          in
          fields []
    | '[' ->
        incr pos; ws ();
        if peek () = ']' then (incr pos; List [])
        else
          let rec items acc =
            let v = value () in
            ws ();
            match peek () with
            | ',' -> incr pos; items (v :: acc)
            | ']' -> incr pos; List (List.rev (v :: acc))
            | _ -> raise (Parse_error "bad array")
          in
          items []
    | '"' -> String (str ())
    | 't' -> lit "true" (Bool true)
    | 'f' -> lit "false" (Bool false)
    | 'n' -> lit "null" Null
    | _ ->
        let start = !pos in
        while !pos < n && (match s.[!pos] with '0' .. '9' | '-' | '+' | '.' | 'e' | 'E' -> true | _ -> false) do incr pos done;
        let t = String.sub s start (!pos - start) in
        if t = "" then raise (Parse_error (Printf.sprintf "unexpected %C at %d" (peek ()) start));
        (match int_of_string_opt t with Some i -> Int i | None -> Float (float_of_string t))
  in
  value ()

let member k = function Assoc kv -> List.assoc_opt k kv | _ -> None
let to_string_opt = function Some (String s) -> Some s | _ -> None
let to_float = function Some (Float f) -> f | Some (Int i) -> float i | _ -> 0.
