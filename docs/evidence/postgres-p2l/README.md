# PostgreSQL P2l — backend concurrency acceptance evidence

Verified 2026-10-18 on Windows, Godot 4.7.2, PostgreSQL 18.6 and official pinned
SOCI v0.4.3. Branch `codex/postgres-concurrency-acceptance`, based on `main`
`cb28409d`. The changed wallet fixture's SHA-256 is
`9a4cef68019bdd338e8c93f6151a674b7bdc5d1434ac572ce80907fd26c342ae`.
Other native domain sources match that baseline. No runtime/store/schema change.

## Final native matrix

Every row passed the existing runner's exit-code, domain-marker and script-error
checks. Every invocation initialized its own fresh loopback SCRAM cluster and
confirmed shutdown afterward; no installed service or player data was used.

| Suite | Successful run |
| --- | --- |
| readiness | `run-nzwok1rt` |
| commit-failure | `run-loeksq1c` |
| wallet | `run-dqbx73td` |
| npc-shop | `run-iyy1r6j3` |
| inventory | `run-2df47zl0` |
| storage | `run-4fvyzqln` |
| upgrade | `run-ckq_nhpc` |
| shop-seller | `run-i172o9qq` |
| shop-settlement | `run-ddq2m86q` |
| account-claims | `run-m8rt7tjv` |
| auction-search | `run-fltg8qvy` |
| exchange-ledger | `run-_thhf4nb` |
| exchange-orders | `run-gt1ka90y` |
| wallet-concurrency | `run-l8io91kq` |
| inventory-concurrency | `run-7q8l3xnw` |

The expanded existing wallet fixture observes overlapping native transactions:

- Player Shop purchase competes with another alt's Exchange reservation or
  immediate maker settlement. Exactly one commits with insufficient shared
  funds. Wallet/reserved balances, offline proceeds, material total, fill count
  and unique item custody remain consistent.
- Simultaneous sale and partial collection preserve newly credited offline
  proceeds and wallet headroom, regardless of admission order.
- One purchase remains blocked at account admission while another Shop purchase
  and an independent Exchange match both commit. This is a correctness/progress
  barrier, not a throughput or latency measurement. Only those diagnostic
  worker sessions extend their own lock/statement timeout budgets.

Default smoke also passed: 14 Godot checks, 85 Web contracts and architecture
guards, using Node 24.19.0. Pinned SOCI is verified by every native runner;
`git diff --check` passed.
No additional default-CI suite, game window, pixel or combat-balance test added.

An earlier matrix attempt `run-8ulzcviq` was correctly rejected: a new diagnostic
query used nonexistent `maker_order_id` instead of schema field `maker_id`.
Its interrupted cleanup also affected the following diagnostic scenario. The
fixture query was corrected; the final wallet/Inventory runs above passed on
fresh clusters. No production transaction fix was necessary. Failed-run logs
remain distinct from acceptance results under ignored `.godot/verification`.

## Decision and boundary

The [P2 matrix](../../development/postgres-concurrency-acceptance.md) is verified
for the current opt-in backend operations. This is the reviewable backend
correctness gate, not permission to switch production from SQLite.

P3 nonblocking transaction ownership/admission, in-flight discovery, session and
handoff fencing, runtime pending-income ownership and committed-state publication
remain unimplemented. P4 still needs PostgreSQL-backed World/network load, soak,
failure/recovery and migration/cutover proof. Native fault fixtures do not decide
whether an arbitrary lost COMMIT reply committed. Linux, PostgreSQL-backed CEF,
physical input and multi-World behavior are **NOT VERIFIED** by this gate.
