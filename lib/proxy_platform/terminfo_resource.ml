type error = [ `Read_failed of string ]

let pp_error ppf (`Read_failed message) = Format.fprintf ppf "read-failed(%s)" message
let default_search_dirs = [ "/etc/terminfo"; "/lib/terminfo"; "/usr/share/terminfo" ]

let candidate_path dir term =
  if String.length term = 0 then None else Some (Filename.concat (Filename.concat dir (String.make 1 term.[0])) term)

let is_regular_file path =
  match Unix.stat path with Unix.{ st_kind = S_REG; _ } -> true | _ -> false | exception Unix.Unix_error _ -> false

let find_in_dirs dirs term =
  List.find_map
    (fun dir -> match candidate_path dir term with Some path when is_regular_file path -> Some path | _ -> None)
    dirs

let locate ~term ~home ~terminfo ~terminfo_dirs =
  let terminfo_dir = match terminfo with Some path -> [ path ] | None -> [] in
  let home_dir = match home with Some home -> [ Filename.concat home ".terminfo" ] | None -> [] in
  find_in_dirs (terminfo_dir @ home_dir @ terminfo_dirs @ default_search_dirs) term

let read path =
  try
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () ->
        let length = in_channel_length channel in
        let buffer = Bytes.create length in
        really_input channel buffer 0 length;
        Ok buffer)
  with
  | Sys_error message -> Error (`Read_failed message)
  | End_of_file -> Error (`Read_failed "truncated read")
