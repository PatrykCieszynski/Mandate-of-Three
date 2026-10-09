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
- When the user asks to publish, push the integrated `main`. Push a topic branch
  only when explicitly requested.
- After merging a topic, delete its local branch. Once the merge is published on
  remote `main`, delete the corresponding remote topic branch if present. Never
  delete unmerged branches; `--no-ff` preserves merged topic history.
- Keep runtime databases, accounts, logs, engine binaries and reference checkouts
  in their ignored locations; commit source, documentation and repeatable tests.

## Prototype verification policy

Keep the default checks small, headless and based on durable contracts:
item ownership/revision/rollback, inventory footprints/migration, progression
checkpoints, wallet delta/spend transactions and explicit Web bridge commands.
Do not add pixel snapshots, exact DOM/geometry, animation timings or hardcoded
combat balance assertions for routine prototype changes. Native/manual checks
belong at a milestone or when changing CEF/input/rendering integration.

Default checks from the repository root in PowerShell:

```powershell
git diff --check
& .\tests\run-smoke.ps1
```

The smoke runner needs Godot and Node (`-NodeExecutable` accepts a bundled path),
no running servers, plugin download, browser, port or real player accounts.
It keeps fixed-name diagnostic logs and removes its disposable DBs after success.

Existing extended suites are optional. Run the relevant one for changes to its
network/gameplay flow: run-spike3d, run-pve, run-combat, run-progression, run-xp,
run-yang, run-web-inventory. PvE-derived network suites use port 18098 and must
run sequentially. Do not run every extended suite after a small UI/style change.
Full item-session integration (`run-items.ps1 -WithSession`) needs gateway/master/
world and creates guest accounts/test characters; use it for login/session changes.

Use `tools/clean-dev-artifacts.ps1` to remove disposable verification outputs
and retired spike caches. Keep imports, editor cache, binaries, references,
installed root CEF addon and actual runtime stores. Avoid ad-hoc scripts at the .godot root;
put temporary diagnostics in .godot/verification and remove them after use.
