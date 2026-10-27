(* Harness fingerprints (Python: core/runmark.py), SHA-1 over sorted relative paths and bytes. *)

let mark = ".adapt_complete"

let fingerprint dir =
  if not (Fs.is_dir dir) then "absent"
  else begin
    let b = Buffer.create 4096 in
    List.iter
      (fun rel ->
        let base = Filename.basename rel in
        let ignored = base = mark || base = ".DS_Store" || Fs.has_part "__pycache__" rel || Filename.check_suffix rel ".pyc" in
        if not ignored then begin
          Buffer.add_string b rel;
          Buffer.add_char b '\000';
          Buffer.add_string b (Fs.read (Fs.( / ) dir rel));
          Buffer.add_char b '\000'
        end)
      (Fs.walk dir);
    String.sub (Sha1.hex (Buffer.contents b)) 0 16
  end
