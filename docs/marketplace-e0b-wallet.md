# E0b: one Yang wallet per Master account and World

Feature `codex/e0b-account-wallet`, based on locally integrated E0a in `shop`.
The public inventory/character authority remains unchanged. WorldDatabase accepts
authenticated character contexts, resolves/caches their verified Master IDs, and
keeps one RAM balance/pending/dirty entry per account. WalletStoreSqlite operates
only on account IDs. NPC Shop/Upgrade resolve account IDs within their transaction;
item ownership and receiving capacity still use the authenticated character.

## Startup and additive migration v18

Master sends its complete canonical name/ID manifest on the trusted internal World
connection. World remains wallet-not-ready until audit/migration succeeds. New
character creation also receives Master ID server-to-server and binds it before
creating the character; public clients cannot supply it. Registration after the
initial manifest therefore works without a guessed ID or a second full manifest.

Migration runs at startup, after a stopped World's final checkpoints/backup:
audit all world names and character membership, reject orphans/mismatches, bind
unbound names from the explicit manifest, reject orphan wallet rows, sum legacy
wallets by account, create bounded `account_wallets`, drop the old character
wallet table and stamp version 18 in one transaction. Missing old wallets count
as zero. Accounts without any old characters receive no migration grant; their
first future character creates the wallet with 1500 Yang. An existing zero-balance
account never receives another grant for an alt.

All account sums must fit MAX_YANG (9e15). SQL integer/check constraints reject
overflow instead of clipping or silently promoting to real. Any failure, including
the final version marker, rolls back mapping, tables and balances together.
Restart/retry checks the completed version and never resums legacy balances.
After migration, no old `wallets` runtime path remains; its creation helper is
only for the historical v14 migration leading to v18.

## Runtime and economic commits

Income changes shared RAM and pending delta. Dirty checkpoints add account deltas
in a transaction. Critical spend includes pending income and the item mutation;
only commit updates RAM and clears pending. Critical credit has the same rule for
online accounts; offline accounts update only SQL. The in-transaction credit
primitive is ready for E2, where a sale must share buyer/item/seller commit.

Currency presentation still hides other accounts' balances. Its committed-change
publication matches account identity, so multiple on-map alts sharing an account
receive the prepared balance. Ground loot rights keep their existing character
provenance. Disconnect does not evict a shared wallet while another account peer
still uses it; failed saves retain pending RAM for retry/reentry.

## Verification

Existing Yang suites now cover unequal global/local IDs, two alts sharing RAM,
one-time starting Yang, migration/retry/conservation, missing identity, rollback,
overflow, online credit with pending, offline credit/reentry, credit failure and
read-only completed-migration checks. Test-only EconomyFixture performs explicit
Master enrollment for SQLite/network fixtures; production has no ID inference.
Existing stale assertions of character-keyed RAM were updated to account keys.

Passing checks: default smoke; `run-yang`; NPC Shop, Upgrade and NPC network suites;
Web Inventory network suite; existing two-client item session/relog; and the real
Gateway/Master/World four-character identity session. The latter spends 50 Yang
on the first alt, sees 1450 on the second, and confirms the other account's 1500
balance remains isolated. Tests are headless and network suites run sequentially.

The real dev World was gracefully stopped, checkpointed and backed up with the
SQLite backup API plus the matching Master collection. Before migration it held
86 legacy wallet rows totaling **71650 Yang**. After migration and the two new
test accounts (2x1500 grants, 2x50 spends), total was **74550 Yang**, as expected.
Extra item-session guest accounts are separate documented test grants, not an
unexplained conservation difference. Ignored backup:
`.godot/runtime/backups/e0b-pre-character-wallet.db`, with matching Master file.

Rollback requires stopping World and restoring the matching pre-v18 SQLite backup
and compatible server code; v17 code cannot read account_wallets. Do not restore
an unrelated Master collection or migrate while pending RAM is active. Existing
engine/extension shutdown diagnostics and the unrelated Terrain3D editor reopen
error are not claims of clean native editor/GPU verification. No new CEF UI here.
