# PostgreSQL P2a — shared wallet concurrency evidence

Windows, PostgreSQL 18.6, Godot 4.7.2, pinned godot-soci v0.4.2. Every run uses a
fresh owned SCRAM loopback cluster; no installed PostgreSQL service or player data.

`wallet-concurrency` final run `run-t0dx3son`: PASS. Native lock-wait barriers
exercise shared-account NPC/Exchange and Upgrade/NPC competing spends, near-cap
revenue collection/spend, cross-alt/cross-kind receipt collisions, reverse wallet
matching/checkpoint, opposite input-order checkpoints and explicit lock-timeout
recovery. Snapshots include wallets, revenue, assets/orders/fills, items/custody,
item revisions and durable receipts. Original-ID retry/reopen retains the outcome.

A/B regression: the same fixture using only the original P1l wallet file failed in
`run-uihdmb4b` at `checkpoint_matching`: checkpoint and reverse-wallet matching
could not both complete. The runner rejected the script assertion despite the
later marker; all owned clusters stopped. Restoring the fix makes the test pass.
Raw diagnostics remain ignored under `.godot/verification/postgres-readiness/`.

Native regressions PASS: wallet `run-ebkfuicy`, NPC purchase `run-2djwqng6`, Upgrade
`run-ez04xt0q`, Shop settlement `run-zudx_3ov`, Exchange orders `run-apylrhgf`.
Default smoke also passes. No PostgreSQL dependency was added to default CI.

No throughput, Linux, PostgreSQL network/CEF or P3 runtime-fencing claim. P2's
broader custody/conflict and retry gates remain open. No automatic retry policy
is inferred from the native driver's unstructured failure text.
