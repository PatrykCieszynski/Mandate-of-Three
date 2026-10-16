# Marketplace implementation sequence v1.1

Accepted 2026-10-13 from the supplied product PDF and implementation brief.
`shop` is the integration branch; each package uses a separate `codex/e0a-*`,
`codex/e0b-*`, etc. feature branch based on that integration branch. Keep packages
separate and merge with no-ff after appropriate checks. Publication and merging
to main remain explicit user actions.

One SQLite database per logical World; start with Seasonal. One wallet and one
durable Player Shop per account in that World. Offline/global-within-World market;
instances and future channels do not partition ownership. No generic ORM,
event bus, PostgreSQL, channels, reputation, favorite sellers or commission now.

| Package | Scope / exit contract |
| --- | --- |
| E0a | Verified Master account ID handoff, one-to-one World mapping, spoof rejection; [identity implementation](marketplace-e0a-identity.md). |
| E0b | Account Yang: explicitly map every legacy account, sum character wallets once with overflow/rollback checks, migrate pending/dirty cache and all economy consumers; no extra Yang for alts. |
| E1a | SQL-enforced exclusive item custody across bag/equipment/Storage/shop/claim; transactional receipts, revisions, retry and fault injection. |
| E1b | Durable My Shop, name/status/grid/prices and Inventory D&D using existing Core UI. Cancel returns to account claims, not a possibly full alt bag. |
| E2 | Atomic purchase and offline seller settlement; one buyer wins, no charge on full bag, same command retry returns the same receipt. |
| E3a | Server catalog/search: one base definition, independent +0..+9 inclusive bounds, rolled-affix AND filters, indexed queries, bounded cursor/limit, 10k-offer measurements. |
| E3b | Compact marketplace-search CEF table with multi-bonus AND filters; tooltip reuse; selecting a result opens the whole shop and highlights the offer. |
| E4 | Whitelisted fungible asset ledger, deposit/withdraw, free/reserved and conservation, sharing the same Yang authority. |
| E5 | Exact integer-ratio, price-time orderbook: maker price, partial fill/cancel races, offline fills, receipts and Exchange UI. |
| E6 optional | Rotating physical stalls reference existing shop IDs; no separate market. |
| S future | Offline resumable Seasonal-to-Classic transfer with manifests, ID mapping, receipts and conservation. |

Dependency chain: E0a -> E0b -> E1a -> E1b -> E2. E3a/E3b and E4/E5 follow E2;
avoid simultaneous changes to shared transactions/currency APIs. The user authorized sequential progression through E0-E5 on 2026-10-13.
Integrate locally into shop; merging to main and publication remain explicit.

Keep ItemInstance changes immediate and atomic. Grind Yang uses account RAM plus
pending delta/checkpoints; critical spend/sale incorporates pending in the same
transaction and refreshes RAM only after commit. Progression retains its own
dirty checkpoints. Market mutations use command IDs/receipts and expected revisions.
Before public trading, measure SQLite NORMAL versus FULL durability, exercise
WAL backup/restore, and test crashes/retries and two-client races. Native CEF
verification begins when real market UI is introduced, not for E0a identity work.

Implemented and integrated locally on shop: E0a, E0b, E1a, E1b, E2, E3a, E3b, E4,
E5. Native CEF market/Exchange milestone passed; human input/IME/gameplay feel is
still a separate review. See [E5 verification and limits](marketplace-e5-exchange.md).
No E6 stalls or Seasonal transfer implementation. Main/publication remain explicit.
