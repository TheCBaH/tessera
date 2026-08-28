module Foundation = Tessera_foundation

let name = "xterm-256color"

let source =
  "xterm-256color,clear=\\E[H\\E[2J,cup=\\E[%i%p1%d;%p2%dH,cud1=\\n,cub1=^H,cuf1=\\E[C,cuu1=\\E[A,ech=\\E[%p1%dX,el=\\E[K,"

let must_uint n = match Foundation.UInt.of_int n with Ok value -> value | Error _ -> assert false

let policy =
  let limits =
    match
      Foundation.Limits.make ~max_columns:(must_uint 1000) ~max_control_bytes:(must_uint 65536)
        ~max_csi_params:(must_uint 64) ~max_diagnostics:(must_uint 256) ~max_rows:(must_uint 1000)
        ~max_slice_bytes:(must_uint 65536) ~max_snapshot_cells:(must_uint 1_000_000)
    with
    | Ok limits -> limits
    | Error _ -> assert false
  in
  Foundation.Policy.make ~limits ~profile:Foundation.Policy.Xterm_256color_core

let description =
  match Terminfo.parse policy (Terminfo.Source source) with Ok value -> value | Error _ -> assert false

let capability_domain =
  [
    Description.Clear_screen;
    Description.Cursor_address;
    Description.Cursor_down;
    Description.Cursor_left;
    Description.Cursor_right;
    Description.Cursor_up;
    Description.Erase_char;
    Description.Erase_line;
    Description.Set_title;
  ]

let is_compatible candidate =
  let canonical = Description.capabilities description in
  let given = Description.capabilities candidate in
  List.for_all
    (fun capability ->
      match Description.Capability_map.find given capability with
      | None -> true
      | Some value -> (
          match Description.Capability_map.find canonical capability with
          | None -> true
          | Some canonical_value -> String.equal value canonical_value))
    capability_domain
