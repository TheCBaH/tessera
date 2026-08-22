type error = [ `Compiled_format of string | `Description of Description.error | `Source_syntax of string ]
type resource = Compiled of bytes | Source of string

let pp_error ppf = function
  | `Compiled_format message -> Format.fprintf ppf "compiled format: %s" message
  | `Description error -> Description.pp_error ppf error
  | `Source_syntax message -> Format.fprintf ppf "source syntax: %s" message

module Error = struct
  type nonrec error = error

  let pp_error = pp_error
end

module E = Err.Make (Error)

let pp_resource ppf = function
  | Compiled bytes -> Format.fprintf ppf "compiled(%d bytes)" (Bytes.length bytes)
  | Source source -> Format.fprintf ppf "source(%d bytes)" (String.length source)

let trim = String.trim
let string_of_reverse_characters characters = String.of_seq (List.to_seq (List.rev characters))
let ( let* ) = Result.bind

let ( and* ) left right =
  let* left = left in
  let* right = right in
  Ok (left, right)

type located_field = { column : int; line : int; text : string }

let source_error { column; line; _ } message =
  E.fail ~pos:__POS__ (`Source_syntax (Format.asprintf "line %d, column %d: %s" line column message))

let advance line column = function '\n' -> (line + 1, 1) | _ -> (line, column + 1)

let scan_fields source =
  let emit fields ~column ~line characters =
    let text = string_of_reverse_characters characters in
    if trim text = "" then fields else { column; line; text } :: fields
  in
  let length = String.length source in
  let rec loop index line column field_line field_column only_space in_comment characters fields =
    if index = length then
      if in_comment then List.rev fields else List.rev (emit fields ~column:field_column ~line:field_line characters)
    else
      let character = source.[index] in
      if in_comment then
        let line, column = advance line column character in
        if character = '\n' then loop (index + 1) line column line column true false [] fields
        else loop (index + 1) line column field_line field_column only_space true characters fields
      else if character = '#' && only_space then
        let line, column = advance line column character in
        loop (index + 1) line column field_line field_column only_space true characters fields
      else if character = ',' then
        let fields = emit fields ~column:field_column ~line:field_line characters in
        let line, column = advance line column character in
        loop (index + 1) line column line column true false [] fields
      else if character = '\\' && index + 1 < length then
        let escaped = source.[index + 1] in
        let line, column = advance line column character in
        let line, column = advance line column escaped in
        loop (index + 2) line column field_line field_column false false (escaped :: '\\' :: characters) fields
      else
        let starts_field =
          only_space && not (character = ' ' || character = '\t' || character = '\r' || character = '\n')
        in
        let field_line, field_column = if starts_field then (line, column) else (field_line, field_column) in
        let line, column = advance line column character in
        let only_space = only_space && (character = ' ' || character = '\t' || character = '\r' || character = '\n') in
        loop (index + 1) line column field_line field_column only_space false (character :: characters) fields
  in
  loop 0 1 1 1 1 true false [] []

let first_unescaped value separator =
  let rec loop index =
    if index = String.length value then None
    else if value.[index] = '\\' then loop (index + 2)
    else if value.[index] = separator then Some index
    else loop (index + 1)
  in
  loop 0

let valid_name name =
  name <> ""
  && String.for_all (function ' ' | '\t' | '\r' | '\n' | ',' | '=' | '#' | '@' | '|' -> false | _ -> true) name

let decode_string value =
  let length = String.length value in
  let digit value = value >= '0' && value <= '7' in
  let rec loop index characters =
    if index = length then Ok (string_of_reverse_characters characters)
    else
      match value.[index] with
      | '^' when index + 1 < length -> loop (index + 2) (Char.chr (Char.code value.[index + 1] land 0x1f) :: characters)
      | '\\' when index + 1 < length -> (
          match value.[index + 1] with
          | 'E' | 'e' -> loop (index + 2) ('\027' :: characters)
          | 'n' -> loop (index + 2) ('\n' :: characters)
          | 'r' -> loop (index + 2) ('\r' :: characters)
          | 't' -> loop (index + 2) ('\t' :: characters)
          | 'b' -> loop (index + 2) ('\b' :: characters)
          | ('\\' | ',' | '^') as character -> loop (index + 2) (character :: characters)
          | first when digit first && index + 3 < length && digit value.[index + 2] && digit value.[index + 3] ->
              let character =
                ((Char.code first - 48) * 64)
                + ((Char.code value.[index + 2] - 48) * 8)
                + Char.code value.[index + 3]
                - 48
              in
              if character > 255 then Error "invalid octal escape"
              else loop (index + 4) (Char.chr character :: characters)
          | _ -> Error "invalid escape")
      | '^' | '\\' -> Error "truncated escape"
      | character -> loop (index + 1) (character :: characters)
  in
  loop 0 []

let extension name value extensions =
  let rec replace = function
    | [] -> [ (name, value) ]
    | (current, _) :: rest when current = name -> (name, value) :: rest
    | current :: rest -> current :: replace rest
  in
  replace extensions

let parse_source policy source =
  let maximum =
    Tessera_foundation.UInt.to_int
      (Tessera_foundation.Limits.max_control_bytes (Tessera_foundation.Policy.limits policy))
  in
  let decode field value =
    match decode_string value with
    | Error message -> source_error field message
    | Ok program when String.length program > maximum -> source_error field "source string exceeds policy"
    | Ok program -> Ok program
  in
  let parse_field field =
    let text = trim field.text in
    match first_unescaped text '=' with
    | Some index ->
        let name = trim (String.sub text 0 index) in
        let value = String.sub text (index + 1) (String.length text - index - 1) in
        if name = "use" then Ok (`Use (trim value)) else Ok (`String (name, value))
    | None -> (
        match first_unescaped text '#' with
        | Some index -> (
            let name = trim (String.sub text 0 index) in
            let value = String.sub text (index + 1) (String.length text - index - 1) |> trim in
            try Ok (`Number (name, int_of_string value)) with Failure _ -> source_error field "invalid number")
        | None ->
            if String.length text > 0 && text.[String.length text - 1] = '@' then
              Ok (`Cancelled (trim (String.sub text 0 (String.length text - 1))))
            else Ok (`Boolean text))
  in
  match scan_fields source with
  | [] -> E.fail ~pos:__POS__ (`Source_syntax "missing terminal names")
  | names_field :: fields ->
      let names =
        List.filter (fun name -> name <> "") (List.map trim (String.split_on_char '|' (trim names_field.text)))
      in
      if names = [] || List.exists (fun name -> not (valid_name name)) names then
        source_error names_field "invalid terminal name"
      else
        let rec loop capabilities extensions uses = function
          | [] -> Ok (Description.make_with_source ~capabilities ~extensions ~names ~uses:(List.rev uses))
          | field :: rest -> (
              if String.length field.text > maximum then source_error field "source field exceeds policy"
              else
                let* value = parse_field field in
                let name =
                  match value with
                  | `Boolean name | `Cancelled name | `Number (name, _) | `String (name, _) -> name
                  | `Use _ -> "use"
                in
                if not (valid_name name) then source_error field "invalid capability name"
                else
                  match value with
                  | `Use value ->
                      if value = "" then source_error field "empty use dependency"
                      else loop capabilities extensions (value :: uses) rest
                  | `Boolean name -> loop capabilities (extension name Description.Boolean extensions) uses rest
                  | `Number (name, value) ->
                      loop capabilities (extension name (Description.Number value) extensions) uses rest
                  | `Cancelled name ->
                      let capabilities =
                        match Description.capability_of_name name with
                        | None -> capabilities
                        | Some capability -> Description.Capability_map.remove capabilities capability
                      in
                      loop capabilities (extension name Description.Cancelled extensions) uses rest
                  | `String (name, value) -> (
                      let* program = decode field value in
                      match Description.capability_of_name name with
                      | None -> loop capabilities (extension name (Description.String program) extensions) uses rest
                      | Some capability ->
                          let* value =
                            E.map_error ~pos:__POS__
                              (fun error -> `Description error)
                              (Description.Capability_map.of_list [ (capability, program) ])
                          in
                          let* capabilities =
                            E.map_error ~pos:__POS__
                              (fun error -> `Description error)
                              (Description.Capability_map.merge ~earlier:capabilities ~later:value)
                          in
                          loop capabilities extensions uses rest))
        in
        loop Description.Capability_map.empty [] [] fields

let read_uint16 bytes offset =
  if offset < 0 || offset + 1 >= Bytes.length bytes then
    E.fail ~pos:__POS__ (`Compiled_format "truncated compiled entry")
  else Ok (Char.code (Bytes.get bytes offset) lor (Char.code (Bytes.get bytes (offset + 1)) lsl 8))

let read_int16 bytes offset =
  let* value = read_uint16 bytes offset in
  Ok (if value land 0x8000 = 0 then value else value - 0x10000)

let read_int32 bytes offset =
  let* first = read_uint16 bytes offset and* second = read_uint16 bytes (offset + 2) in
  let value = Int64.logor (Int64.of_int first) (Int64.shift_left (Int64.of_int second) 16) in
  Ok (if Int64.logand value 0x8000_0000L = 0L then value else Int64.sub value 0x1_0000_0000L)

let checked_add ~context left right =
  if left < 0 || right < 0 || left > max_int - right then
    E.fail ~pos:__POS__ (`Compiled_format (context ^ " overflows"))
  else Ok (left + right)

let checked_mul ~context left right =
  if left < 0 || right < 0 || (left <> 0 && right > max_int / left) then
    E.fail ~pos:__POS__ (`Compiled_format (context ^ " overflows"))
  else Ok (left * right)

let checked_end ~context bytes start length =
  let* stop = checked_add ~context start length in
  if stop > Bytes.length bytes then E.fail ~pos:__POS__ (`Compiled_format ("truncated " ^ context)) else Ok stop

let has_nul bytes ~start ~stop =
  let rec loop position = position < stop && (Bytes.get bytes position = '\000' || loop (position + 1)) in
  loop start

let align_even ~context bytes offset =
  if offset land 1 = 0 then Ok offset
  else
    let* next = checked_end ~context bytes offset 1 in
    if Bytes.get bytes offset <> '\000' then E.fail ~pos:__POS__ (`Compiled_format ("invalid " ^ context)) else Ok next

type string_range = { length : int; start : int }
type compiled_string = Absent | Cancelled | Present of string_range
type compiled_number = Absent_number | Cancelled_number | Number of int

let string_range ~kind bytes ~offsets_start ~table_start ~table_stop index =
  let* offset = read_int16 bytes (offsets_start + (index * 2)) in
  if offset = -1 then Ok Absent
  else if offset = -2 then Ok Cancelled
  else if offset < 0 || offset >= table_stop - table_start then
    E.fail ~pos:__POS__ (`Compiled_format ("invalid " ^ kind ^ " offset"))
  else
    let start = table_start + offset in
    let rec terminator position =
      if position = table_stop then None
      else if Bytes.get bytes position = '\000' then Some position
      else terminator (position + 1)
    in
    let* stop =
      E.map_none ~pos:__POS__ ~error:(fun () -> `Compiled_format ("unterminated " ^ kind)) (terminator start)
    in
    Ok (Present { length = stop - start; start })

let string_of_range bytes = function
  | Absent | Cancelled -> None
  | Present { length; start } -> Some (Bytes.sub_string bytes start length)

let valid_name_range bytes ({ length; start } : string_range) =
  length > 0
  &&
  let stop = start + length in
  let rec loop index =
    index = stop
    ||
    match Bytes.get bytes index with
    | ' ' | '\t' | '\r' | '\n' | ',' | '=' | '#' | '@' | '|' -> false
    | _ -> loop (index + 1)
  in
  loop start

let number ~size bytes offset =
  let* value =
    match size with
    | 2 -> Result.map Int64.of_int (read_int16 bytes offset)
    | 4 -> read_int32 bytes offset
    | _ -> E.fail ~pos:__POS__ (`Compiled_format "unsupported compiled number size")
  in
  if value = -1L then Ok Absent_number
  else if value = -2L then Ok Cancelled_number
  else if value < 0L then E.fail ~pos:__POS__ (`Compiled_format "invalid compiled numeric capability")
  else if value > Int64.of_int max_int then
    E.fail ~pos:__POS__ (`Compiled_format "compiled number exceeds portable int")
  else Ok (Number (Int64.to_int value))

let parse_compiled policy bytes =
  let* magic = read_uint16 bytes 0
  and* names_size = read_uint16 bytes 2
  and* boolean_count = read_uint16 bytes 4
  and* number_count = read_uint16 bytes 6
  and* string_count = read_uint16 bytes 8
  and* string_table_size = read_uint16 bytes 10 in
  if magic <> 0x11a && magic <> 0x21e then E.fail ~pos:__POS__ (`Compiled_format "unsupported compiled entry magic")
  else
    let number_size = if magic = 0x21e then 4 else 2 in
    let* names_start = checked_end ~context:"compiled header" bytes 0 12 in
    let* names_end = checked_end ~context:"compiled names" bytes names_start names_size in
    if names_size = 0 || not (has_nul bytes ~start:names_start ~stop:names_end) then
      E.fail ~pos:__POS__ (`Compiled_format "unterminated compiled names")
    else
      let* boolean_end = checked_end ~context:"compiled booleans" bytes names_end boolean_count in
      let* number_start =
        if boolean_end land 1 = 0 then Ok boolean_end
        else checked_end ~context:"compiled number alignment" bytes boolean_end 1
      in
      let* number_bytes = checked_mul ~context:"compiled number table" number_count number_size in
      let* string_offsets_start = checked_end ~context:"compiled numbers" bytes number_start number_bytes in
      let* string_offset_bytes = checked_mul ~context:"compiled string offset table" string_count 2 in
      let* string_table_start =
        checked_end ~context:"compiled string offsets" bytes string_offsets_start string_offset_bytes
      in
      let* string_table_end = checked_end ~context:"compiled string table" bytes string_table_start string_table_size in
      let maximum =
        Tessera_foundation.UInt.to_int
          (Tessera_foundation.Limits.max_control_bytes (Tessera_foundation.Policy.limits policy))
      in
      let validate count f =
        let rec loop index =
          if index = count then Ok () else match f index with Ok () -> loop (index + 1) | Error _ as error -> error
        in
        loop 0
      in
      let validate_boolean ~context ~start count =
        validate count (fun index ->
            match Char.code (Bytes.get bytes (start + index)) with
            | 0 | 1 | 254 -> Ok ()
            | _ -> E.fail ~pos:__POS__ (`Compiled_format ("invalid " ^ context ^ " boolean")))
      in
      let validate_numbers ~start count =
        validate count (fun index ->
            Result.map (fun _ -> ()) (number ~size:number_size bytes (start + (index * number_size))))
      in
      let legacy_string index =
        string_range ~kind:"compiled string" bytes ~offsets_start:string_offsets_start ~table_start:string_table_start
          ~table_stop:string_table_end index
      in
      let validate_strings count string =
        validate count (fun index ->
            let* value = string index in
            match value with
            | Present { length; _ } when length > maximum ->
                E.fail ~pos:__POS__ (`Compiled_format "compiled string exceeds policy")
            | Absent | Cancelled | Present _ -> Ok ())
      in
      let* () = validate_boolean ~context:"compiled" ~start:names_end boolean_count in
      let* () = validate_numbers ~start:number_start number_count in
      let* () = validate_strings string_count legacy_string in
      let known =
        [
          (Description.Clear_screen, 5);
          (Description.Cursor_address, 10);
          (Description.Cursor_down, 11);
          (Description.Cursor_left, 14);
          (Description.Cursor_right, 17);
          (Description.Cursor_up, 19);
          (Description.Erase_char, 37);
          (Description.Erase_line, 6);
        ]
      in
      let rec capabilities result = function
        | [] ->
            E.map_error ~pos:__POS__
              (fun error -> `Description error)
              (Description.Capability_map.of_list (List.rev result))
        | (capability, index) :: rest ->
            let* value = legacy_string index in
            let result =
              match string_of_range bytes value with None -> result | Some program -> (capability, program) :: result
            in
            capabilities result rest
      in
      let* capabilities = capabilities [] known in
      let description extensions =
        let names =
          match Bytes.index_opt (Bytes.sub bytes names_start names_size) '\000' with
          | None -> []
          | Some terminator ->
              Bytes.sub_string bytes names_start terminator
              |> String.split_on_char '|'
              |> List.filter (fun name -> name <> "")
        in
        Description.make_with_source ~capabilities ~extensions ~names ~uses:[]
      in
      if string_table_end = Bytes.length bytes then Ok (description [])
      else
        let* extended_start = align_even ~context:"compiled extended alignment" bytes string_table_end in
        let* extended_boolean_count = read_int16 bytes extended_start
        and* extended_number_count = read_int16 bytes (extended_start + 2)
        and* extended_string_count = read_int16 bytes (extended_start + 4)
        and* extended_item_count = read_int16 bytes (extended_start + 6)
        and* extended_table_size = read_int16 bytes (extended_start + 8) in
        if
          extended_boolean_count < 0 || extended_number_count < 0 || extended_string_count < 0
          || extended_item_count < 0 || extended_table_size < 0
        then E.fail ~pos:__POS__ (`Compiled_format "negative extended table count")
        else
          let* extended_header_end = checked_end ~context:"compiled extended header" bytes extended_start 10 in
          let* extended_name_count =
            checked_add ~context:"compiled extended capability count" extended_boolean_count extended_number_count
          in
          let* extended_name_count =
            checked_add ~context:"compiled extended capability count" extended_name_count extended_string_count
          in
          let* expected_item_count =
            checked_add ~context:"compiled extended offset count" extended_string_count extended_name_count
          in
          if extended_item_count <> expected_item_count then
            E.fail ~pos:__POS__ (`Compiled_format "invalid extended string item count")
          else
            let* extended_boolean_end =
              checked_end ~context:"compiled extended booleans" bytes extended_header_end extended_boolean_count
            in
            let* extended_number_start =
              align_even ~context:"compiled extended number alignment" bytes extended_boolean_end
            in
            let* extended_number_bytes =
              checked_mul ~context:"compiled extended number table" extended_number_count number_size
            in
            let* extended_offsets_start =
              checked_end ~context:"compiled extended numbers" bytes extended_number_start extended_number_bytes
            in
            let* extended_offset_bytes = checked_mul ~context:"compiled extended offset table" extended_item_count 2 in
            let* extended_table_start =
              checked_end ~context:"compiled extended offsets" bytes extended_offsets_start extended_offset_bytes
            in
            let* extended_table_end =
              checked_end ~context:"compiled extended string table" bytes extended_table_start extended_table_size
            in
            if extended_table_end <> Bytes.length bytes then
              E.fail ~pos:__POS__ (`Compiled_format "trailing compiled data")
            else
              let extended_string index =
                string_range ~kind:"extended string" bytes ~offsets_start:extended_offsets_start
                  ~table_start:extended_table_start ~table_stop:extended_table_end index
              in
              let extended_name index =
                string_range ~kind:"extended capability name" bytes ~offsets_start:extended_offsets_start
                  ~table_start:extended_table_start ~table_stop:extended_table_end (extended_string_count + index)
              in
              let* () = validate_boolean ~context:"extended" ~start:extended_header_end extended_boolean_count in
              let* () = validate_numbers ~start:extended_number_start extended_number_count in
              let* () = validate_strings extended_string_count extended_string in
              let* () =
                validate extended_name_count (fun index ->
                    let* value = extended_name index in
                    match value with
                    | Absent | Cancelled -> E.fail ~pos:__POS__ (`Compiled_format "missing extended capability name")
                    | Present range when not (valid_name_range bytes range) ->
                        E.fail ~pos:__POS__ (`Compiled_format "invalid extended capability name")
                    | Present _ -> Ok ())
              in
              let rec collect_extensions index acc =
                if index = extended_name_count then Ok (description (List.rev acc))
                else
                  let* name = extended_name index in
                  match string_of_range bytes name with
                  | None -> E.fail ~pos:__POS__ (`Compiled_format "missing extended capability name")
                  | Some name -> (
                      let* value =
                        if index < extended_boolean_count then
                          match Char.code (Bytes.get bytes (extended_header_end + index)) with
                          | 0 -> Ok None
                          | 1 -> Ok (Some Description.Boolean)
                          | 254 -> Ok (Some Description.Cancelled)
                          | _ -> E.fail ~pos:__POS__ (`Compiled_format "invalid extended boolean")
                        else if index < extended_boolean_count + extended_number_count then
                          let number_index = index - extended_boolean_count in
                          Result.map
                            (function
                              | Absent_number -> None
                              | Cancelled_number -> Some Description.Cancelled
                              | Number value -> Some (Description.Number value))
                            (number ~size:number_size bytes (extended_number_start + (number_index * number_size)))
                        else
                          let string_index = index - extended_boolean_count - extended_number_count in
                          Result.map
                            (function
                              | Absent -> None
                              | Cancelled -> Some Description.Cancelled
                              | Present { length; start } ->
                                  Some (Description.String (Bytes.sub_string bytes start length)))
                            (extended_string string_index)
                      in
                      match value with
                      | None -> collect_extensions (index + 1) acc
                      | Some value -> collect_extensions (index + 1) ((name, value) :: acc))
              in
              collect_extensions 0 []

let parse policy = function
  | Compiled bytes -> parse_compiled policy bytes
  | Source source -> parse_source policy source

let resolve_use description ~lookup =
  let override_extensions ~base ~overrides =
    List.fold_left (fun base (name, value) -> extension name value base) base overrides
  in
  let rec resolve seen description =
    let rec inherited capabilities extensions = function
      | [] -> Ok (capabilities, extensions)
      | name :: rest ->
          if List.mem name seen then E.fail ~pos:__POS__ (`Source_syntax (Format.asprintf "cyclic use=%S" name))
          else
            let* parent =
              E.map_none ~pos:__POS__
                ~error:(fun () -> `Source_syntax (Format.asprintf "unknown use=%S" name))
                (lookup name)
            in
            let* parent = resolve (name :: seen) parent in
            inherited
              (Description.Capability_map.override ~base:capabilities ~overrides:(Description.capabilities parent))
              (override_extensions ~base:extensions ~overrides:(Description.extensions parent))
              rest
    in
    let* capabilities, extensions = inherited Description.Capability_map.empty [] (Description.uses description) in
    Ok
      (Description.make_with_source
         ~capabilities:
           (Description.Capability_map.override ~base:capabilities ~overrides:(Description.capabilities description))
         ~extensions:(override_extensions ~base:extensions ~overrides:(Description.extensions description))
         ~names:(Description.names description) ~uses:[])
  in
  resolve [] description
