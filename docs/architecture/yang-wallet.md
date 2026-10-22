# Account Yang and ground currency

Normal development uses PostgreSQL. A wallet belongs to an account within the
realm, shared by its characters; it is not a separate balance per character.
The current single-World PostgreSQL Wallet runtime owns loaded account state,
pending income and dirty/checkpoint work. SQLite wallet tests are reference
fixtures, not the normal server path.

## Grinding income

GroundCurrency is a transient World entity: local identity, amount, loot rights,
position and expiry. Pickup/autopickup validates life, distance, line of sight,
rights and expiry, updates the authoritative wallet and removes the stack once.
It creates no ItemInstance, permanent UID or database row per small Yang drop.
Inventory capacity does not block wallet pickup. There is no pet dependency.

Eligible income increases runtime balance and pending delta immediately. About
every 30 seconds, checkpoints apply captured deltas in PostgreSQL. A confirmed
commit consumes only its captured pending prefix; rollback/unknown outcomes retain
safe recovery state. Logout/disconnect, transfer and graceful save/shutdown use
the same documented flush barriers. Unflushed income and ground currency may be
lost on a crash; committed critical spending remains durable.

## Critical spending and collection

An upgrade, purchase, Exchange action or other critical spend validates the
current account/session and settles pending income, spending, reservations and
its item/ledger mutation atomically. Never commit payment independently of the
item change, or use a stale stored balance to reject otherwise available pending
income. Committed revisions reconcile RAM before publication; replay cannot spend
again or reset the current wallet from historical result contents.

Player Shop income is separate claimable revenue. A sale does not directly credit
the spendable wallet. Manual partial collection transfers what fits and leaves
the rest claimable. See [Shop revenue](../development/shop-revenue.md).
A tradable/stacked crafting currency held in Inventory follows immediate item
persistence rather than this wallet policy.

## References and verification

- [Persistence categories and crash window](persistence-policy.md).
- [Wallet commit/reconciliation contract](../development/economy-command-boundary.md).
- [PostgreSQL setup and complete login/restart verification](../development/postgres-full-state.md).
- [Testing commands](../development/testing.md): `run-yang.ps1` retains SQLite and
  two-client ground-currency reference coverage; PostgreSQL runtime/recovery
  suites exercise the normal backend. Network suites on port 18098 run sequentially.

Numerical drop rates, starter balances and collection radii are prototype data,
not architectural guarantees. Consult current content/code when tuning them.
