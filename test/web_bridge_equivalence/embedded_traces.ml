(* Generated once from the committed test/node_pty/traces/*.json fixtures (see
   test/web_rendering_trace_fixture/trace_fixture.ml and test/README.md's "Canonical
   real-terminal traces" section) and committed as plain OCaml source, matching
   lib/terminfo/bundled.ml's existing checked-in-data precedent. Embedding the raw JSON text as
   string literals -- rather than reading the files at run time -- keeps corpus.ml free of any
   file I/O, which Melange has no Stdlib support for at all (unlike native and js_of_ocaml, which
   could read files under Node): the exact same corpus.ml source must compile and run identically
   under all three targets for the equivalence check to mean anything.

   To regenerate after a trace fixture changes, re-run the generator described in this file's
   commit message, or reproduce it: for each test/node_pty/traces/<name>.json, emit
   [let <name> = {|<raw file contents>|}]. None of the fixture JSON text can itself contain the
   `|}` delimiter (it holds only JSON syntax and base64), so the raw string quoting below is
   always unambiguous. *)

let dialog_menu_submit =
  {|{
  "columns": 40,
  "rows": 10,
  "events": [
    {
      "kind": "data",
      "bytes_base64": "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"
    }
  ]
}
|}

let whiptail_menu_cancel =
  {|{
  "columns": 40,
  "rows": 10,
  "events": [
    {
      "kind": "data",
      "bytes_base64": "G1s/MTA0OWgbWzIyOzA7MHQbWzE7MTByG1s0bBtbPzI1bBsoQhtbbRtbMzdtG1s0MG0bWzE7MTByG1tIG1syShtbMTsxSBtbOTdtG1s0NG0bW0sKG1tLChtbSwobW0sKG1tLChtbSwobW0sKG1tLChtbSwobW0sbWzE7MUgbWzMwbRtbNDdt4pSM4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSQG1syOzFI4pSCIFdoaXB0YWlsIG1lbnUgICAgICAgICAgICAgICAgICAgICAgICDilIIbWzM7MUjilIIgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIOKUghtbNDsxSOKUgiAgICAgICAgICAgIBtbMzdtG1s0MW1maXJzdCAgRmlyc3QgG1szMG0bWzQ3bSAgICAgICAgICAgICDilIIbWzU7MUjilIIgICAgICAgICAgICBzZWNvbmQgU2Vjb25kICAgICAgICAgICAgIOKUghtbNjsxSOKUgiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg4pSCG1s3OzFI4pSCICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICDilIIbWzg7MUjilIIgICAgICAgPE9rPiAgICAgICAgICAgPENhbmNlbD4gICAgICAgIOKUghtbOTsxSOKUgiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg4pSCG1sxMDsxSOKUlOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUmBtbMTA7MzlI4pSYCBtbNGjilIAbWzRsG1s0OzE0SBtbPzEybBtbPzI1aBtbMTA7MUgbWzM3bRtbNDBtGyhCG1ttG1szOTs0OW0NG1tLDRtbPzEwNDlsG1syMzswOzB0G1syShtbSFdISVBUQUlMIENBTkNFTExFRA0KG10wO3Rlc3NlcmEtbm9kZS1wdHktZG9uZQc="
    }
  ]
}
|}

let vt_form_edit =
  {|{
  "columns": 40,
  "rows": 10,
  "events": [
    {
      "kind": "data",
      "bytes_base64": "G1syShtbSEZPUk06IGVudGVyIHZhbHVlPiBwcm94eSB2YWx1ZQ0KG1syShtbSEZPUk0gU0FWRUQ6IHByb3h5IHZhbHVlDQobXTA7dGVzc2VyYS1ub2RlLXB0eS1kb25lBw=="
    }
  ]
}
|}

let vt_scroll_redraw =
  {|{
  "columns": 40,
  "rows": 10,
  "events": [
    {
      "kind": "data",
      "bytes_base64": "G1syShtbSFNDUk9MTCBTVEFSVA0Kb25lDQp0d28NCnRocmVlDQobWzJBG1syS3JlZHJhd24gdHdvDQoNChtdMDt0ZXNzZXJhLW5vZGUtcHR5LWRvbmUH"
    }
  ]
}
|}

let vt_resize_redraw =
  {|{
  "columns": 40,
  "rows": 10,
  "events": [
    {
      "kind": "data",
      "bytes_base64": "G1syShtbSFJFU0laRSBXQUlUSU5HDQo="
    },
    {
      "kind": "resize",
      "columns": 60,
      "rows": 16
    },
    {
      "kind": "data",
      "bytes_base64": "DQobWzJKG1tIUkVTSVpFIEFQUExJRUQ6IDE2IDYwDQobXTA7dGVzc2VyYS1ub2RlLXB0eS1kb25lBw=="
    }
  ]
}
|}

let vt_shell_session =
  {|{
  "columns": 40,
  "rows": 10,
  "events": [
    {
      "kind": "data",
      "bytes_base64": "VEVTU0VSQSQgZWNobyBzaGVsbC1jb21tYW5kLXJhbiA+ICIkVEVTU0VSQV9SRVNVTFRfUEFUSCI7IHByaW50ZiAnXDAzM10wOyVzXDAwNycgIiRURVNTRVJBX1RFU1RfRE9ORV9USVRMRSI7IDogPiAiJFRFU1NFUkFfVEVTVF9ET05FX0ZJTEUiOyB3aGlsZSBbICEgLWYgIiRURVNTRVJBX1RFU1RfQ0FQVFVSRURfRklMRSIgXTsgZG8gc2xlZXAgMC4wNTsgZG9uZQ0KG10wO3Rlc3NlcmEtbm9kZS1wdHktZG9uZQc="
    }
  ]
}
|}

let cases =
  [
    ("dialog-menu-submit", dialog_menu_submit);
    ("whiptail-menu-cancel", whiptail_menu_cancel);
    ("vt-form-edit", vt_form_edit);
    ("vt-scroll-redraw", vt_scroll_redraw);
    ("vt-resize-redraw", vt_resize_redraw);
    ("vt-shell-session", vt_shell_session);
  ]
