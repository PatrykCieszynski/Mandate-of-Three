# PostgreSQL P2b — Inventory custody evidence

Windows, PostgreSQL 18.6, Godot 4.7.2 and pinned godot-soci v0.4.2. Fresh owned
SCRAM loopback clusters only; no installed service, runtime stores or player data.

Final `inventory-concurrency` fixture `run-yu59t5p6`: PASS. Independent native
sessions prove cross-alt receipt conflict/reopen, equip/list, move/Storage deposit,
move/Exchange conversion, full-footprint receiving overlap and last-space
Claim/NPC competition. Starter/duplicate pickup and two-account global UID claims
retain one receiving item/marker. Complete item/custody/full-footprint checks pass.

Same-fixture A/B with only the original P2a Inventory file (`run-ruomcwtx`) fails
at `receipt_collision`: the losing alt did not return `command_conflict` after
passing receipt discovery. Restoring account-first admission passes. The runner
rejects script assertions even if a later PASS marker prints. Raw diagnostics stay
ignored under `.godot/verification/postgres-readiness/`; owned clusters stopped.

Native regressions PASS: Inventory `run-z71s_wq4`, Storage `run-t72yvl7u`, Shop seller
`run-gli24q49`, account Claims `run-4zlgtvba`, Exchange ledger `run-l099fnpv`.
Default smoke passes. PostgreSQL remains opt-in, with no default CI dependency.

No P2 throughput/soak, Linux, PostgreSQL World/CEF or cutover claim. Unique-conflict
ground pickup may report storage until original UID retry discovers claimed; no
automatic retry or new ground receipt protocol is introduced.
