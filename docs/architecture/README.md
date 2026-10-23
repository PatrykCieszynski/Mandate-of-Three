# Architecture — ownership and constraints

## Accepted target contracts

- [Economy V2 — contracts C1–C5](economy/README.md): account Yang, ItemInstance custody, idempotent transactions, snapshots, session fencing and CH handoff.
- [World instance topology and dynamic channels](world-instance-architecture.md): MapInstance lifecycle, pooling, public/party dungeons, visible channels and optional overflow layers.

Some local transaction/session/instance guarantees are implemented; distributed Economy and cross-host World placement remain future work. These documents intentionally distinguish **one logical authority** from **one physical process**. In the near term we can enforce good internal module boundaries inside the current World without introducing a distributed Economy process or splitting processes.

## Running prototype contracts

- [Persistence and crash window](persistence-policy.md): PostgreSQL writer, wallet pending deltas, dirty XP checkpoints and immediate critical Item/Yang COMMIT.
- [Server/client/Web UI boundary](../ui/web-ui.md): authoritative gameplay, explicit CEF commands, snapshots.
- [Items and identity](item-instances.md) and [Yang wallet](yang-wallet.md).
- [Current test contracts](../development/testing.md).

## Audits and proposals — not accepted contracts

- [Gameplay modularization audit V1](gameplay-modularization-audit.md): current
  ownership/couplings, proposed Shared Core / Classic / Mandate boundaries and
  a staged Vendor Recipes extraction. No gameplay or schema change is implied.

**Authority rule:** where target contracts differ from the running prototype, the current persistence policy describes reality; accepted Economy/World ADRs describe future desired behavior. Historical implementation plans are retained in Git history; current code and accepted contracts determine behavior.
