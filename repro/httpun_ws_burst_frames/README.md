# `httpun-ws` burst-frames read-starvation probe

Run this from the repository root:

```sh
PATH=/opt/opam/4.14.3/bin:$PATH timeout 8s dune exec --root repro/httpun_ws_burst_frames ./repro.exe 30
```

It uses real loopback sockets, with no tessera code involved. The server
acks every frame it dispatches; the client fires the given count (default
30) of small text frames back-to-back with no yield in between, then waits
up to 5s for that many acks.

On unpatched `httpun-ws` 0.2.0 this reliably prints `RESULT: FAIL (only
3/30 acks seen before timeout)` -- frames past the first couple are parsed
and queued but never dispatched, because `Websocket_connection.
_next_read_operation`'s `` `Read `` branch advances its internal frame
queue by exactly one frame and returns, instead of recursing to drain every
already-ready frame the way its structurally identical `` `Close `` branch
already does. Fixed by pinning a one-line patched fork (see
`.devcontainer/devcontainer.json`'s `pin-packages`) pending an upstream release.
