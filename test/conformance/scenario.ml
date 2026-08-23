(* The reusable adapter-conformance fixture: a scheduler-independent
   vocabulary of host events, plus the named scripted scenarios built from it. A future scheduler
   adapter (Unix, Lwt, Async, JSOO, Melange) is expected to serialise its own host
   events into this same shape and replay these scenarios against its own driver, so its ordering,
   short-write, backpressure, EOF, failure, and resize-coalescing behaviour can be compared against
   the reference driver in reference.ml. Nothing here depends on a scheduler, so this module has no
   adapter-specific dependency to keep it reusable. *)

type host_event =
  | Write of string
      (** One logical write available from the host all at once; a conforming adapter may still choose to deliver it to
          [Session.ingest] in several pieces. *)
  | Short_write of string list
      (** The host write already arrived to the adapter split into several short pieces (e.g. a small read buffer);
          every piece must still be ingested, in order. *)
  | Backpressure_pause
      (** The adapter paused delivering ingress because a downstream consumer applied backpressure. Pure flow control:
          it never becomes ingress and never changes the ordered sequence of ingested bytes/resizes that follow. *)
  | Backpressure_resume  (** Delivery resumes after a preceding [Backpressure_pause]. *)
  | Resize of int * int  (** columns, rows *)
  | Coalesced_resize of (int * int) list
      (** Several host resize notifications arrived before the adapter delivered any of them (e.g. a burst of
          window-resize events). A conforming adapter ingests only the last one: the earlier sizes were never actually
          observable at the host. Must be non-empty. *)
  | Failure of string
      (** A host I/O failure (e.g. a PTY read error). Ingress stops here: no further event in the scenario is delivered,
          and the failure is reported through the adapter's own error channel, never fabricated into a core update or
          diagnostic. *)
  | Eof  (** The host stream ended; the adapter calls [Session.finish] and stops. *)

type scenario = { name : string; columns : int; rows : int; events : host_event list }

let ordered_ingress =
  {
    name = "ordered ingress interleaves writes and resizes in host order";
    columns = 4;
    rows = 2;
    events = [ Write "AB"; Resize (6, 2); Write "CD"; Resize (4, 3); Write "EF"; Eof ];
  }

let short_writes =
  {
    name = "a short-write delivery of one logical write";
    columns = 4;
    rows = 2;
    events = [ Short_write [ "A"; "B"; "C"; "D" ]; Eof ];
  }

let short_writes_reference =
  { short_writes with name = "the same logical write delivered whole"; events = [ Write "ABCD"; Eof ] }

let backpressure =
  {
    name = "backpressure pauses do not affect ingested order or content";
    columns = 4;
    rows = 2;
    events = [ Write "AB"; Backpressure_pause; Backpressure_resume; Write "CD"; Eof ];
  }

let failure_stops_ingress =
  {
    name = "a host failure stops ingress before later events are delivered";
    columns = 4;
    rows = 2;
    events = [ Write "AB"; Failure "read error"; Write "should never be ingested"; Eof ];
  }

let distinct_size_resize =
  { name = "a resize to a distinct size"; columns = 4; rows = 2; events = [ Write "AB"; Resize (6, 3); Eof ] }

let equal_size_resize =
  { name = "a resize to the current size"; columns = 4; rows = 2; events = [ Write "AB"; Resize (4, 2); Eof ] }

let coalesced_resize =
  {
    name = "a burst of host resize notifications coalesces to the last one";
    columns = 4;
    rows = 2;
    events = [ Write "AB"; Coalesced_resize [ (5, 2); (6, 2); (7, 3) ]; Write "CD"; Eof ];
  }

let all =
  [
    ordered_ingress;
    short_writes;
    backpressure;
    failure_stops_ingress;
    distinct_size_resize;
    equal_size_resize;
    coalesced_resize;
  ]
