type t = { description_identity : string option; child_term : string; fallback : bool }

let fallback_result () =
  {
    description_identity = Tessera.Description.identity Tessera.Bundled.description;
    child_term = Tessera.Bundled.name;
    fallback = true;
  }

let select ~policy ~term ~locate ~read =
  match term with
  | None -> fallback_result ()
  | Some term -> (
      match locate ~term with
      | None -> fallback_result ()
      | Some path -> (
          match read path with
          | Error _ -> fallback_result ()
          | Ok bytes -> (
              match Tessera.Terminfo.parse policy (Tessera.Terminfo.Compiled bytes) with
              | Error _ -> fallback_result ()
              | Ok description ->
                  if Tessera.Bundled.is_compatible description then
                    {
                      description_identity = Tessera.Description.identity description;
                      child_term = term;
                      fallback = false;
                    }
                  else fallback_result ())))

let env_with_term base ~child_term =
  let entry = "TERM=" ^ child_term in
  let replaced = ref false in
  let updated =
    Array.map
      (fun line ->
        if String.length line >= 5 && String.sub line 0 5 = "TERM=" then (
          replaced := true;
          entry)
        else line)
      base
  in
  if !replaced then updated else Array.append updated [| entry |]
