# PostgreSQL P2i — Shared Storage retry evidence

Windows, Godot 4.7.2, PostgreSQL 18.6 and official pinned SOCI v0.4.3. Fresh owned
SCRAM loopback clusters and disposable SQLite only; owned clusters stopped after
verification. No dependency pin, schema, protocol or runtime backend change.

- Pre-change Storage baseline `run-5ia67fwn`: PASS. Expanded Storage
  `run-eszajmjo`: PASS, retaining SQLite parity, existing two-session custody/
  capacity/receipt conflicts, provenance, full destinations and COMMIT containment.
- Server-injected `40001`/`40P01` statement faults at custody deletion, provenance/
  revision update, destination insertion and receipt persistence succeed on the
  second whole attempt for deposit, internal move and alt withdrawal. One UID has
  one custody, one revision increment and preserved amount/upgrade/rolls/sockets.
  Stored provenance remains original; withdrawal changes it to the receiving alt.
- Original issuer replays the exact result without mutation; a different alt
  using that command ID conflicts and cannot discover the other's receipt.
  Retrying a no-op receipt write preserves item state and mutation/replay flags.
- Persistent retryable failures stop after three total attempts. Constraint,
  lock-timeout and cancellation codes run once, preserving item/custody/account
  revisions and receipts. Deferred COMMIT errors with the same retryable codes
  run once, close and return `outcome_unknown`; reopen/discovery confirms the
  fixture's aborted state, not an inference about arbitrary lost COMMIT replies.
- Real independently queued alts withdraw a source (owner rejection), move it
  (stale revision), or occupy a nonstarting destination footprint cell (occupied).
  Retry rejects without partial transfer or retargeting the receiving character.
  Only these barrier diagnostics extend their own session-local timeouts.
- Inventory concurrency `run-3ma5b4zl` and Exchange ledger `run-khmfn6_x`: PASS,
  including Storage consumption/transfer boundaries and cross-alt receiving.
- Default smoke: 14 Godot checks and 85 Web contracts PASS. Existing Storage
  recovery network: server and two headless clients PASS on production SQLite.

No PostgreSQL World/CEF integration, physical-input, throughput/soak, Linux or P3
execution/fencing claim. In-transaction Storage helpers retain their caller's
transaction; seller/claim commands, starter/pickup and unreceipted checkpoints
are not newly opted in. Raw diagnostics remain ignored under `.godot/verification`.
