(* A real, but still headless, terminal compatibility layer. tmux is the
   independent terminal emulator; all cases use an empty config and a private
   server socket, so neither the developer's tmux state nor a controlling
   terminal participates in their outcome. *)

let failf format = Printf.ksprintf failwith format

let getenv name =
  match Sys.getenv_opt name with Some value -> value | None -> failf "required test environment %s is absent" name

let shell_quote = Filename.quote

let run ?(capture = false) program arguments =
  let command = String.concat " " (List.map shell_quote (program :: arguments)) in
  let argv = Array.of_list (program :: arguments) in
  if capture then (
    let read_end, write_end = Unix.pipe () in
    let child = Unix.create_process program argv Unix.stdin write_end Unix.stderr in
    Unix.close write_end;
    let buffer = Buffer.create 256 in
    let chunk = Bytes.create 4096 in
    let rec read () =
      match Unix.read read_end chunk 0 (Bytes.length chunk) with
      | 0 -> ()
      | count ->
          Buffer.add_subbytes buffer chunk 0 count;
          read ()
    in
    read ();
    Unix.close read_end;
    match Unix.waitpid [] child with
    | _, Unix.WEXITED 0 -> Buffer.contents buffer
    | _, Unix.WEXITED status -> failf "%s exited %d" command status
    | _, Unix.WSIGNALED signal -> failf "%s was killed by signal %d" command signal
    | _, Unix.WSTOPPED signal -> failf "%s stopped by signal %d" command signal)
  else
    match Unix.create_process program argv Unix.stdin Unix.stdout Unix.stderr |> Unix.waitpid [] with
    | _, Unix.WEXITED 0 -> ""
    | _, Unix.WEXITED status -> failf "%s exited %d" command status
    | _, Unix.WSIGNALED signal -> failf "%s was killed by signal %d" command signal
    | _, Unix.WSTOPPED signal -> failf "%s stopped by signal %d" command signal

let tmux socket arguments = run "tmux" ([ "-S"; socket; "-f"; "/dev/null" ] @ arguments)
let tmux_capture socket arguments = run ~capture:true "tmux" ([ "-S"; socket; "-f"; "/dev/null" ] @ arguments)

let read_file path =
  let input = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr input) (fun () -> really_input_string input (in_channel_length input))

let write_file path contents =
  let output = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr output) (fun () -> output_string output contents)

let regenerate_goldens = Sys.getenv_opt "TESSERA_PROXY_TMUX_WRITE_GOLDENS" = Some "1"

(* GitHub-hosted runners can take longer than a local machine to schedule the
   proxy and its PTY.  This remains a bounded wait while leaving enough room
   for an otherwise healthy interaction to complete. *)
let tmux_wait_timeout_seconds = "30"
let tmux_wait_timeout = 30.

type input = Keys of string list | Literal of string

type case = {
  name : string;
  input : input;
  resize : (int * int) option;
  ready_text : string;
  expected_result : string;
  golden : string;
}

let cases =
  [
    {
      name = "dialog-menu-submit";
      input = Keys [ "Down"; "Enter" ];
      resize = None;
      ready_text = "Dialog menu";
      expected_result = "second";
      golden = "dialog-menu-submit.pane";
    };
    {
      name = "whiptail-menu-cancel";
      input = Keys [ "Escape" ];
      resize = None;
      ready_text = "Whiptail menu";
      expected_result = "cancel\n";
      golden = "whiptail-menu-cancel.pane";
    };
    {
      name = "vt-form-edit";
      input = Literal "proxy value";
      resize = None;
      ready_text = "FORM: enter value>";
      expected_result = "proxy value\n";
      golden = "vt-form-edit.pane";
    };
    {
      name = "vt-scroll-redraw";
      input = Keys [ "Enter" ];
      resize = None;
      ready_text = "SCROLL START";
      expected_result = "redrawn\n";
      golden = "vt-scroll-redraw.pane";
    };
    {
      name = "vt-resize-redraw";
      input = Keys [ "Enter" ];
      resize = Some (60, 16);
      ready_text = "RESIZE WAITING";
      expected_result = "16 60\n";
      golden = "vt-resize-redraw.pane";
    };
    {
      name = "vt-shell-session";
      input =
        Literal
          "echo shell-command-ran > \"$TESSERA_RESULT_PATH\"; tmux wait-for -S \"$TESSERA_TEST_DONE\"; tmux wait-for \
           \"$TESSERA_TEST_CAPTURED\"";
      resize = None;
      ready_text = "TESSERA$";
      expected_result = "shell-command-ran\n";
      golden = "vt-shell-session.pane";
    };
  ]

let fresh_server () =
  let directory = Filename.temp_file "tessera-proxy-tmux-test" "" in
  Sys.remove directory;
  Unix.mkdir directory 0o700;
  (directory, Filename.concat directory "tmux.sock")

let remove_if_present path = try Sys.remove path with Sys_error _ -> ()

let cleanup_server ~directory ~socket ~result =
  ignore (try tmux socket [ "kill-server" ] with Failure _ -> "");
  remove_if_present result;
  remove_if_present socket;
  try Unix.rmdir directory with Unix.Unix_error _ -> ()

let contains ~needle haystack =
  let needle_length = String.length needle in
  let rec loop offset =
    offset + needle_length <= String.length haystack
    && (String.sub haystack offset needle_length = needle || loop (offset + 1))
  in
  needle = "" || loop 0

let wait_for_pane ~socket ~needle =
  let deadline = Unix.gettimeofday () +. tmux_wait_timeout in
  let rec loop () =
    let pane = tmux_capture socket [ "capture-pane"; "-p"; "-t"; "case:0.0" ] in
    if contains ~needle pane then ()
    else if Unix.gettimeofday () >= deadline then failf "pane never became ready with %S:\n%s" needle pane
    else (
      ignore (Unix.select [] [] [] 0.05);
      loop ())
  in
  loop ()

let test_case ~proxy ~fixture case =
  let directory, socket = fresh_server () in
  let session = "case" in
  let result = Filename.concat directory "result" in
  let ready_token = Printf.sprintf "ready-%d-%s" (Unix.getpid ()) case.name in
  let token = Printf.sprintf "done-%d-%s" (Unix.getpid ()) case.name in
  let captured_token = Printf.sprintf "captured-%d-%s" (Unix.getpid ()) case.name in
  let command =
    String.concat " "
      [
        "env";
        "TERM=xterm-256color";
        "LC_ALL=C.UTF-8";
        "TESSERA_TEST_READY=" ^ shell_quote ready_token;
        "TESSERA_TEST_DONE=" ^ shell_quote token;
        "TESSERA_TEST_CAPTURED=" ^ shell_quote captured_token;
        shell_quote proxy;
        "/bin/sh";
        shell_quote fixture;
        shell_quote case.name;
        shell_quote result;
      ]
  in
  let cleanup () = cleanup_server ~directory ~socket ~result in
  Fun.protect ~finally:cleanup (fun () ->
      ignore (tmux socket [ "new-session"; "-d"; "-s"; session; "-x"; "40"; "-y"; "10"; "sleep 60" ]);
      ignore (tmux socket [ "set-option"; "-g"; "status"; "off" ]);
      ignore (tmux socket [ "set-window-option"; "-t"; session ^ ":0"; "remain-on-exit"; "on" ]);
      ignore (tmux socket [ "respawn-pane"; "-k"; "-t"; session ^ ":0.0"; command ]);
      ignore
        (run "timeout" [ tmux_wait_timeout_seconds; "tmux"; "-S"; socket; "-f"; "/dev/null"; "wait-for"; ready_token ]);
      wait_for_pane ~socket ~needle:case.ready_text;
      (match case.resize with
      | None -> ()
      | Some (columns, rows) ->
          ignore
            (tmux socket
               [ "resize-window"; "-t"; session ^ ":0"; "-x"; string_of_int columns; "-y"; string_of_int rows ]));
      (match case.input with
      | Keys keys -> ignore (tmux socket ([ "send-keys"; "-t"; session ^ ":0.0" ] @ keys))
      | Literal text ->
          ignore (tmux socket [ "send-keys"; "-t"; session ^ ":0.0"; "-l"; text ]);
          ignore (tmux socket [ "send-keys"; "-t"; session ^ ":0.0"; "Enter" ]));
      ignore (run "timeout" [ tmux_wait_timeout_seconds; "tmux"; "-S"; socket; "-f"; "/dev/null"; "wait-for"; token ]);
      let pane = tmux_capture socket [ "capture-pane"; "-p"; "-t"; session ^ ":0.0" ] in
      ignore (tmux socket [ "wait-for"; "-S"; captured_token ]);
      let result_contents = read_file result in
      let golden_path = Filename.concat (Filename.concat (Filename.dirname fixture) "goldens") case.golden in
      if not (String.equal result_contents case.expected_result) then
        failf "%s result mismatch: expected %S, got %S" case.name case.expected_result result_contents;
      (if regenerate_goldens then write_file golden_path pane
       else
         let golden = read_file golden_path in
         if not (String.equal pane golden) then
           failf "%s pane golden mismatch:\nexpected %S\ngot %S" case.name golden pane);
      Printf.printf "%s: result and full-pane golden %s\n%!" case.name
        (if regenerate_goldens then "regenerated" else "matched"))

let version program arguments = String.trim (run ~capture:true program arguments)

let () =
  (* This suite's whole point is byte-exact fidelity of the *relayed terminal content* tmux's pane
     capture sees -- and unlike a piped-subprocess test, a real tmux pane merges the child's stdout and
     stderr onto the same terminal. tessera-proxy's own startup diagnostics (the web endpoint's
     "tessera-proxy: web: http://..." banner) are deliberately printed to
     stderr precisely because that is *not* the relayed stream in the piped/subprocess sense this
     comment in proxy.ml documents -- but tmux still shows it in-pane, which would corrupt every golden
     here. Disabling the web endpoint for this suite is the correct fix, not silencing or reordering the
     banner: this suite tests the terminal relay, not the web endpoint. *)
  Unix.putenv "TESSERA_PROXY_WEB" "0";
  let proxy = getenv "TESSERA_PROXY" in
  let fixture = getenv "TESSERA_PROXY_TMUX_FIXTURE" in
  Printf.printf "tmux=%s\ndialog=%s\nwhiptail=%s\n%!" (version "tmux" [ "-V" ]) (version "dialog" [ "--version" ])
    (version "whiptail" [ "--version" ]);
  List.iter (test_case ~proxy ~fixture) cases
