# PostgreSQL P2j — Player Shop seller retry evidence

Verified on 2026-10-18: Windows, Godot 4.7.2, PostgreSQL 18.6 and official pinned
SOCI v0.4.3. Native tests use fresh owned SCRAM loopback clusters; regression
network tests use disposable SQLite. Owned clusters stop after verification.
No dependency pin, schema, protocol or production backend change.

- Expanded seller suite `run-6v4k3hhz`: PASS, retaining SQLite parity and existing
  independent-session listing, withdrawal, footprint and receipt conflicts.
- Server-injected statement `40001`/`40P01` faults exercise complete
  list/configure/edit/price-only/withdraw cycles. Faults after partial Shop cell
  writes, during custody/configuration changes and at receipt persistence roll
  back before a second whole attempt. One offer/footprint, UID, ownership,
  revisions and original affixes/sockets survive. Offer Only remains supported;
  price-only edits leave item revisions and account item watermark unchanged.
- Original account-scoped command results replay through another alt without a
  new commit or retargeting the original receiving character. Discovery retains
  its existing account scope.
- Persistent retryable statement failures stop after three total attempts for
  all four command kinds. Constraint, lock-timeout and cancellation codes run
  once. Economic state and durable receipts remain unchanged after rejection.
- Deferred COMMIT `40001`/`40P01` runs once, closes and returns `outcome_unknown`.
  Reopen/discovery verifies the fixture's aborted state; this is not an inference
  about arbitrary lost COMMIT responses and does not authorize automatic retry.
- Independently queued editors change source custody, offer revision, Shop
  configuration or a nonstarting Shop/Inventory footprint cell. Retry rejects
  current owner/stale/occupied conflicts or reselects automatic Inventory
  capacity. An older configuration cannot overwrite the editor's name/status.
  Only these barrier diagnostics extend their own session-local timeouts.
- Shop settlement `run-qibwe0bd` and Inventory concurrency `run-zzmwb_bd`: PASS.
- Default smoke: 14 Godot checks and 85 Web contracts PASS. Existing Player Shop
  network test: server and two headless clients PASS on production SQLite.

No PostgreSQL World/CEF integration, physical-input, throughput/soak, Linux or P3
execution/fencing claim. Claims, starter/pickup and unreceipted checkpoints retain
their existing policies. Production remains SQLite. Raw diagnostics stay ignored
under `.godot/verification`.
