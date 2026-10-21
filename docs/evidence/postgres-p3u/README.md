# P3u — coherent stopped-writer backup/restore rehearsal

Date: 2026-10-20. Windows, Python 3.13, Godot 4.7.2, godot-soci 0.4.3,
PostgreSQL 18.6, Node 24.19. Owned disposable cluster, random loopback ports,
private fixture files and generated credentials only. No player data, installed
PostgreSQL service, visible game windows or production cutover used.

| Check | Result | Ignored evidence |
| --- | --- | --- |
| Real processes → maintenance/exit → bundle → second DB/files → normal login | PASS | `.godot/verification/postgres-readiness/run-1ckbshuf/` |
| Default smoke, architecture guards, 14 Godot suites and 88 Web contracts | PASS | `.godot/verification/*.smoke.log` and Web runner output |
| Python AST and `git diff --check` | PASS | Local invocation |

## What the native fixture proves

`python tools/postgres/run_readiness.py --pg-bin Y:/Software/PostgreSQL/bin --suite backup`

1. Retains ordinary Master/Gateway/World account creation, failed foreign identity
   binding/recovery, real client equip and relog. Dirty +37 Yang/+41 XP use the
   existing runtime APIs; the actual authenticated maintenance HTTP barrier
   checkpoints them, revokes grants and closes native workers/profiles.
2. Waits for the three supervised processes to exit, and closes the fixture's
   own SQL control session. An extra PG session is refused by backup. The tool
   never stops another process or manufactures success from an old status file.
3. Adds fixture-only persistent seller revenue (12345), a nonempty Yang
   reservation (90), two Exchange orders and a fill/sequence. An exited writer
   leaves committed SQLite WAL (+11 XP) behind. Capture includes that XP rather
   than copying the old main DB file. The real client's two UIDs/equipment and
   existing receipts are retained.
4. Refuses live grants, mismatched profile identity, mismatched Master accounts,
   checksum damage, populated source-as-target and existing destinations. Failed
   capture publishes no complete manifest; failed restore publishes no verified
   marker. Negative tests use only fixture copies.
5. Restores to `mandate_restored` and another profile/account directory. Per-table
   counts/content fingerprints and sequence values exactly match the captured
   audit, file hashes/realm/profile identities match, and custody/reservation
   checks pass. The next fill sequence value is 2, not a reused ID.
6. Fresh normal processes use the restored DSN and restored file paths. The
   actual client logs in with its original credentials, sees the same equipped
   UID and two items, and a second held client/drain persists new dirty Yang/XP
   through the restored stores. The profile/account assertions explicitly follow
   those configured restored paths.

The backup fixture reuses maintenance's injected ACK/timeout/account-save/profile
save refusal checks. It deliberately does **not** repeat the third native
blocked-wallet case; that unchanged contract was verified in
[P3t](../postgres-p3t/README.md). The generic inherited maintenance success marker
is not additional evidence for that skipped case. Runner success requires exit
codes, backup markers and absence of Godot parse/script errors in parent/normal
child/client logs, then confirms the owned cluster stopped.

Initial iterations exposed an unclosed fixture SQLite connection and the Windows
requirement for a writable descriptor when flushing files. Both were corrected;
the final path explicitly closes SQLite handles and flushes files before atomic
manifest publication. Failed-run output remains ignored, without verified
success markers. Existing Godot teardown resource warnings are not a substitute
for the contract markers or successful exit checks.

## Boundaries

This is a stopped-writer operational rehearsal. Supervisor freeze is explicit
operator responsibility; no distributed lease or auto-restart prevention is
implemented. PG SHARE locks and a SQLite transaction protect the capture interval,
but arbitrary privileged administrators/independent Master writers must stay out.
Restore commits PG before filesystem verification, so failures can leave an
unpublished partial target; no players may be admitted to it. Retry uses another
new empty target, not destructive cleanup or presumed rollback.

No Linux, physical CEF, production-scale memory/timing, off-host retention,
encryption/key management, SQLite economy import, load/soak, multi-World handoff
or cutover claim. Default backend remains SQLite. The operator procedure and
failure handling are in [backup/restore](../../development/postgres-backup-restore.md).
