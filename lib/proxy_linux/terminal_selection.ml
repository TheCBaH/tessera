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

(* ncurses' $TERMINFO_DIRS search semantics: each colon-separated element is a directory to search, in order, except
   an *empty* element, which stands for the compiled-in system terminfo directory at exactly that position in the
   order -- not "skip it". [/etc/terminfo] is that directory (the head of {!Tessera_proxy_platform.Terminfo_resource
   .default_search_dirs}, which {!Tessera_proxy_platform.Terminfo_resource.locate} already appends unconditionally
   after every caller-supplied directory). Dropping empty elements instead, as a naive [String.split_on_char]/filter
   would, silently reorders the search: [/custom::/other] must search [/custom], then [/etc/terminfo], then [/other]
   -- filtering searches [/custom], [/other], and only reaches [/etc/terminfo] afterwards via the unconditional
   defaults, which can select a different (wrong) terminal description. *)
let terminfo_dirs_of_env = function
  | None -> []
  | Some value -> String.split_on_char ':' value |> List.map (function "" -> "/etc/terminfo" | dir -> dir)

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
