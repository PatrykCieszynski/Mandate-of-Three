# PostgreSQL P3a — Inventory executor evidence

Verified 2026-10-18 on Windows, Godot 4.7.2, PostgreSQL 18.6 and pinned official
SOCI v0.4.3. Branch `codex/postgres-inventory-executor`, based on integrated
`main` `1fa49e98`. Native suites use fresh owned SCRAM loopback clusters; shutdown
is verified by the runner. No installed service or player data is used.

- Final executor suite `run-b6g07g8f`: PASS. Two worker-owned native sessions run
  whole Inventory transactions; an account lock blocks one command while another
  commits. The fixture's SceneTree physics counter advances while SQL is blocked.
- A committed receipt is visible in PostgreSQL before the main thread polls the
  result; that unconsumed ticket still occupies capacity. Overflow is not buffered
  and creates no receipt. Invalid actions and pre-ready/draining submissions are
  rejected before execution.
- Replay and read-only discovery retain the exact original result across fresh
  worker sessions. One UID/revision survives. No-op/replay flags remain distinct;
  modifying a consumer result does not change another completion or the receipt.
- Real deferred COMMIT `40001` publishes unknown once; a nontransactional sequence
  observes one attempt. The worker reconnects for discovery and executes an
  explicit same-ID retry only after the fixture verifies its known aborted state.
  This does not infer the outcome of an arbitrary lost COMMIT reply.
- A real account lock timeout returns a cleaned storage failure while physics
  continues; the original ID subsequently succeeds without poisoning the worker.
- Drain finishes running and buffered dependent commands, denies new work, joins
  finished workers and leaves zero executor sessions. Failed database startup
  drains/reaps and permits a subsequent successful start/stop.
- Existing full Inventory parity/retry suite `run-fn1z6st0`: PASS. Default smoke:
  14 Godot checks, 85 Web contracts and architecture guards PASS. Diff checks PASS.

The first fixture attempt was rejected for a helper named `seed` colliding with
Godot's global function; it was renamed before native verification. Intermediate
and final logs remain separate under ignored `.godot/verification`.

This verifies the local executor, not C2 durable admission, C5 fencing, real World
simulation responsiveness or active CEF input. No PostgreSQL production switch,
session/handoff policy, pending-Yang ownership, other-domain routing, Linux,
throughput/soak or native-driver cancellation claim. Unexpected GDScript worker
termination is guarded conservatively but not fault-injected. P3/P4 remain open.
