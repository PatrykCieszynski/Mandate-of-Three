# Repository workflow

Gameplay priorities and accepted scope are recorded in `docs/project-direction.md`.
Follow them when deciding the next implementation; avoid speculative frameworks.
Persistence policy is in `docs/persistence-policy.md`: progression uses RAM and
dirty checkpoints; item/economy changes remain immediate atomic transactions.

- Work on a separate `codex/<short-topic>` branch for each coherent change.
- Keep `main` as the integrated baseline. Do not implement new work directly on it.
- Before merging, inspect the diff and run checks appropriate to the change.
- Merge completed branches locally with `git merge --no-ff` so the topic remains
  visible in history. Do not rewrite published history or force-push.
- Push the topic branch and the integrated `main` when the user asks to publish.
- Keep runtime databases, accounts, logs, engine binaries and reference checkouts
  in their ignored locations; commit source, documentation and repeatable tests.

## Current verification commands

Run from the repository root in PowerShell:

```powershell
git diff --check
& .\tests\run-items.ps1
& .\tests\run-spike3d.ps1
& .\tests\run-pve.ps1
& .\tests\run-combat.ps1
& .\tests\run-progression.ps1
& .\tests\run-xp.ps1
& .\tests\run-yang.ps1
```

Run PvE, combat, progression, XP and Yang tests sequentially: all use port 18098.
Progression accepts `-Preview` to render its inventory comparison during the test.
XP also accepts `-Preview` to render its HUD and level-up notice.

Full item-session integration additionally uses `& .\tests\run-items.ps1 -WithSession`.
It requires running gateway/master/world roles and creates local
guest accounts and test characters. Use it when session/persistence changes need
verification, with awareness that it writes to the local runtime stores.
