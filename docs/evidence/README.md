# Evidence and validation

Measured evidence must state **branch/commit**, platform, test command, runtime versions and limitations. A CI green check proves only the suites it actually ran.

## On `main`

- [Testing policy and reproduction](../development/testing.md)
- [PostgreSQL P2 backend acceptance](postgres-p2l/README.md) — disposable native correctness runs, distinct from P3/P4 runtime adoption.
- [PostgreSQL P3a Inventory execution](postgres-p3a/README.md) — local worker ownership, backpressure and lifecycle, without a live backend switch.
- [PostgreSQL P3b Inventory recovery](postgres-p3b/README.md) — durable identity, terminal outcomes and discovery after producer-process loss.
- [PostgreSQL P3c Inventory sessions](postgres-p3c/README.md) — delegated grant fencing and recovery barrier on disposable native PostgreSQL.
- [PostgreSQL P3d Inventory runtime](postgres-p3d/README.md) — main-thread recovery, actual World combat cache and stale-delivery fencing.
- [PostgreSQL P3e session bridge](postgres-p3e/README.md) — current Master ticket publication after grant COMMIT, native auth/relogin and normal-role SQLite regression.
- [PostgreSQL P3f Inventory endpoint](postgres-p3f/README.md) — native client processes, stable journal/receipt recovery, private state/public weapon and no SQLite economic fallback.
- [PostgreSQL P3g cache reconciliation](postgres-p3g/README.md) — command freshness ACK, versioned local invalidations, bounded repair and current client/stat projections.
- [PostgreSQL P3h pending recovery](postgres-p3h/README.md) — indexed unresolved-only recovery, data-preserving index migration and retained receipt lookup.
- [PostgreSQL P3i wallet runtime](postgres-p3i/README.md) — RAM batching, stable checkpoint/spend receipts, native client Yang delivery and lifecycle recovery.
- [PostgreSQL P3j NPC runtime](postgres-p3j/README.md) — atomic Shop/Upgrade, captured-income replay safety and actual client journal recovery.
- [CI / platform checks](../development/ci.md)
- [Historical native validation](../history/README.md) (dated results, not current acceptance)
- [Terrain3D adoption and verification](../world/visuals/visual-upgrade-v4-terrain3d.md)

## Auction/Marketplace — on `shop` until PR #1 merges

The `shop` branch contains the Auction D0–D2 reports and evidence under `docs/evidence/`, including the Windows D2 load/recovery measurements. They are deliberately **not copied into `main`** just to make documentation appear current; access them through [PR #1](https://github.com/PatrykCieszynski/Mandate-of-Three/pull/1) or switch to `shop` until merge.

Recorded D2 limitations: Linux runtime not verified, actual native-only SQL timing unavailable from the public addon API, and economy writes still cause measurable simulation tick tails. A benchmark passing on the developer's Windows host is not a production SLA.

This directory retains reproducible raw evidence. The documentation cleanup removes obsolete *plans*, not Auction D2 performance data on `shop`. Large diagnostic P0 data needs separate review after integration.
