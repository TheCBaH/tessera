type instruction = Decimal | Increment_first_two | Literal of string | Parameter of int
type t = instruction list

let compile source =
  let flush literals instructions =
    match literals with
    | [] -> instructions
    | _ -> Literal (String.of_seq (List.to_seq (List.rev literals))) :: instructions
  in
  let length = String.length source in
  let rec loop index literals instructions =
    if index = length then Some (List.rev (flush literals instructions))
    else if source.[index] <> '%' then loop (index + 1) (source.[index] :: literals) instructions
    else if index + 1 = length then None
    else
      let instructions = flush literals instructions in
      match source.[index + 1] with
      | '%' -> loop (index + 2) [ '%' ] instructions
      | 'd' -> loop (index + 2) [] (Decimal :: instructions)
      | 'i' -> loop (index + 2) [] (Increment_first_two :: instructions)
      | 'p' when index + 2 < length -> (
          match source.[index + 2] with
          | '1' -> loop (index + 3) [] (Parameter 0 :: instructions)
          | '2' -> loop (index + 3) [] (Parameter 1 :: instructions)
          | _ -> None)
      | _ -> None
  in
  loop 0 [] []

let execute program parameters =
  let buffer = Buffer.create 32 in
  let rec increment index = function
    | [] -> []
    | value :: rest -> (if index < 2 then value + 1 else value) :: increment (index + 1) rest
  in
  let rec loop current parameters = function
    | [] -> Some (Buffer.contents buffer)
    | Literal value :: rest ->
        Buffer.add_string buffer value;
        loop current parameters rest
    | Increment_first_two :: rest -> loop current (increment 0 parameters) rest
    | Parameter index :: rest -> loop (List.nth_opt parameters index) parameters rest
    | Decimal :: rest -> (
        match current with
        | None -> None
        | Some value ->
            Buffer.add_string buffer (string_of_int value);
            loop current parameters rest)
  in
  loop None parameters program
