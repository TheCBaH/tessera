# Proxy contract regression workflow

`contract_test.ml` has a deterministic generated state machine in addition to
its hand-written expect scenarios.  A property failure reports both its seed
and a greedy-minimized `minimized=[...]` event sequence.

To promote that failure deliberately:

1. Copy the reported minimized sequence into a named expect test in
   `contract_test.ml` (use the existing `drive` helper).
2. Add the expected canonical projection and observer log using
   `dune promote`.
3. Run `dune runtest test/proxy_linux --force`, then commit the new curated
   case in the same change that fixes or accepts the behavior.

Generated scenarios never rewrite goldens.  `make precommit` rejects any
uncommitted promotion, so CI continues to treat a golden change as an explicit
reviewed behavior change.
