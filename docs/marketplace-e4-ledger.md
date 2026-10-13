# E4: Fungible Exchange ledger

Schema 21 adds account exchange_assets free/reserved quantities and reserved_yang
on the existing account_wallets row. CHECK constraints prevent negative/overflow
quantities and reserved Yang above total balance. No second Yang ledger exists.
Wallet critical spend checks unreserved funds inside the same transaction.

The initial explicit market_fungible whitelist is plain Upgrade Ore. Deposit from
bag or account Storage checks UID/revision/custody, whitelist, stack limit, +0,
empty affixes and sockets. Partial deposit reduces amount/increments revision;
full deposit removes UID/custody atomically. Withdrawal creates a fresh plain stack
in the receiving bag or durable account claim. Each withdrawal is at most one
content stack (200 Ore); full bag rolls back rather than losing ledger quantity.
Both actions use the existing account-scoped durable command receipt. Materials
remain ItemInstances outside Exchange; this feature does not batch ordinary items.

Reservation/release are internal transaction primitives for E5 orders, not arbitrary
web commands. Pending Yang is incorporated by the reservation transaction. Runtime
wallets carry total and reserved values; available derives from their difference.

exchange_ledger verifies 100-35 conservation, bag/Storage alts, enriched rejection,
partial revision, claims, reservation/spend guard, SQL faults, receipt/reopen and
schema rollback. Existing wallet/item/upgrade/NPC Shop/smoke and market purchase
regressions pass. Exchange UI and live order ownership of reservations follow E5.
