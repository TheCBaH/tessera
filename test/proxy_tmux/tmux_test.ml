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

let tmux socket arguments = run "tmux" ([ "-L"; socket; "-f"; "/dev/null" ] @ arguments)
let tmux_capture socket arguments = run ~capture:true "tmux" ([ "-L"; socket; "-f"; "/dev/null" ] @ arguments)

let read_file path =
  let input = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr input) (fun () -> really_input_string input (in_channel_length input))

let contains ~needle haystack =
  let needle_length = String.length needle in
  let rec loop offset =
    offset + needle_length <= String.length haystack
    && (String.sub haystack offset needle_length = needle || loop (offset + 1))
  in
  needle = "" || loop 0

type input = Keys of string list | Literal of string

type case = {
  name : string;
  input : input;
  resize : (int * int) option;
  expected_result : string;
  expected_pane : string;
}

let cases =
  [
    {
      name = "dialog-menu-submit";
      input = Keys [ "Down"; "Enter" ];
      resize = None;
      expected_result = "second";
      expected_pane = "Dialog menu";
    };
    {
      name = "whiptail-menu-cancel";
      input = Keys [ "Escape" ];
      resize = None;
      expected_result = "cancel\n";
      expected_pane = "WHIPTAIL CANCELLED";
    };
    {
      name = "vt-form-edit";
      input = Literal "proxy value";
      resize = None;
      expected_result = "proxy value\n";
      expected_pane = "FORM SAVED: proxy value";
    };
    {
      name = "vt-scroll-redraw";
      input = Keys [ "Enter" ];
      resize = None;
      expected_result = "redrawn\n";
      expected_pane = "redrawn two";
    };
    {
      name = "vt-resize-redraw";
      input = Keys [ "Enter" ];
      resize = Some (60, 16);
      expected_result = "16 60\n";
      expected_pane = "RESIZE APPLIED: 16 60";
    };
  ]

let test_case ~proxy ~fixture case =
  let socket = Printf.sprintf "tessera-test-%d-%s" (Unix.getpid ()) case.name in
  let session = "case" in
  let directory = Filename.get_temp_dir_name () in
  let result = Filename.concat directory (Printf.sprintf "tessera-%d-%s.result" (Unix.getpid ()) case.name) in
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
  let cleanup () = ignore (try tmux socket [ "kill-server" ] with Failure _ -> "") in
  Fun.protect ~finally:cleanup (fun () ->
      ignore (tmux socket [ "new-session"; "-d"; "-s"; session; "-x"; "40"; "-y"; "10"; "sleep 60" ]);
      ignore (tmux socket [ "set-option"; "-g"; "status"; "off" ]);
      ignore (tmux socket [ "set-window-option"; "-t"; session ^ ":0"; "remain-on-exit"; "on" ]);
      ignore (tmux socket [ "respawn-pane"; "-k"; "-t"; session ^ ":0.0"; command ]);
      ignore (run "timeout" [ "10"; "tmux"; "-L"; socket; "-f"; "/dev/null"; "wait-for"; ready_token ]);
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
      ignore (run "timeout" [ "10"; "tmux"; "-L"; socket; "-f"; "/dev/null"; "wait-for"; token ]);
      let pane = tmux_capture socket [ "capture-pane"; "-p"; "-t"; session ^ ":0.0" ] in
      ignore (tmux socket [ "wait-for"; "-S"; captured_token ]);
      let result_contents = read_file result in
      if not (String.equal result_contents case.expected_result) then
        failf "%s result mismatch: expected %S, got %S" case.name case.expected_result result_contents;
      if not (contains ~needle:case.expected_pane pane) then
        failf "%s pane capture is missing %S:\n%s" case.name case.expected_pane pane;
      Printf.printf "%s: result and pane golden matched\n%!" case.name)

let version program arguments = String.trim (run ~capture:true program arguments)

let () =
  let proxy = getenv "TESSERA_PROXY" in
  let fixture = getenv "TESSERA_PROXY_TMUX_FIXTURE" in
  Printf.printf "tmux=%s\ndialog=%s\nwhiptail=%s\n%!" (version "tmux" [ "-V" ]) (version "dialog" [ "--version" ])
    (version "whiptail" [ "--version" ]);
  List.iter (test_case ~proxy ~fixture) cases
