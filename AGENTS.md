# Repository workflow

Gameplay priorities and current project direction are documented in
`docs/decisions/project-direction.md`.

Architecture references:

- `docs/architecture/world-instance-architecture.md` — World Processes, MapInstances, dynamic channels and dungeon hosting.
- `docs/architecture/economy/README.md` — accepted Economy V2 contracts C1–C5.
- `docs/architecture/persistence-policy.md` — current runtime persistence behavior.
- `docs/plans/architecture-hardening.md` — staged infrastructure refactoring priorities.
- `docs/development/testing.md` — verification and regression-testing policy.

Distinguish **accepted future architecture** from **currently implemented behavior**.
The runtime currently uses Gateway, Master, a single World Process and SQLite.
The Economy V2 contracts do not imply that a distributed Economy Service,
PostgreSQL or multi-process hosting has already been implemented.

## Development workflow

- Work on a separate `codex/<short-topic>` branch for each coherent change.
- Keep `main` as the integrated baseline. Do not implement new work directly on it.
- Before merging, inspect the diff and run checks appropriate to the change.
- Merge completed branches locally with `git merge --no-ff`. Do not rewrite published history or force-push.
- When the user asks to publish, push the integrated `main`. Push topic branches only when explicitly requested.
- After merging, delete the local topic branch. Delete the remote topic branch only after the merge is published. Never delete unmerged branches.
- Keep runtime databases, accounts, logs, engine binaries and reference checkouts in ignored locations.

## Architecture principles

Prefer explicit ownership, narrow interfaces and independently verifiable
behavior over speculative abstractions or large structural rewrites.

### Responsibility boundaries

- Network endpoints own request admission, authorization,
  routing and response publication, not business transactions.
- Application services coordinate use cases, domain rules,
  committed-state reconciliation and change facts.
- Persistence stores own durable invariants, atomic transactions,
  custody, revisions and idempotent receipts.
- World runtime owns live simulation, combat state and runtime
  projections, not persistent economic authority.
- Client/UI owns input, presentation and feedback, never
  authoritative gameplay or economic decisions.
- Existing mixed-responsibility classes are migration points,
  not patterns to extend. Avoid adding unrelated responsibilities
  to central classes such as WorldDatabase.

### World and instances

- World owns authoritative movement, combat, mob AI and live instance simulation.
- MapInstance is the common runtime concept for public maps, channels and dungeons; their admission and lifecycle policies may differ.
- Realm, map, instance, channel and hosting process identities are distinct.
- The current single-World topology remains valid during local development.
- Do not assume one World Process per channel or one simulation thread per map.
- Client-supplied identity, operation names, instance IDs and gameplay context are untrusted until validated against server authority.

### Economy and persistence

- A realm has one logical authority for durable economic state, independent of channel or instance placement.
- Preserve atomic, durable mutations of unique items, ownership, custody, equipment, critical Yang and trading state.
- Preserve stable operation identity, replay safety and authoritative transaction outcomes where implemented; evolve these toward Economy C1–C5 through explicit milestones.
- Never treat a lost response as proof that an economic operation failed.
- World may cache authoritative economic snapshots, but caches must not become independent write authorities.
- Reconcile runtime state and publish committed changes only after successful transactions. Do not confuse receipt replay with a new commit.
- Combat must not perform database or network round trips per hit.
- Soft progression and eligible grinding Yang may continue using the documented bounded checkpoint policy.
- Keep SQLite until a concrete multi-process milestone requires shared authoritative persistence.

### Refactoring

- Refactor by ownership and domain boundaries, not by arbitrary file size or class count.
- Preserve externally observable behavior unless a change explicitly addresses a bug or approved contract.
- Separate structural refactoring from gameplay changes and schema migrations whenever practical.
- Reuse existing tested components when they already express the correct responsibility.
- Do not introduce an event bus, global command queue, service framework, new database or worker model without a demonstrated requirement.
- For changes crossing session, economy or persistence boundaries, identify failure and recovery behavior before implementation.

## Verification policy

Test observable contracts and critical invariants, not incidental implementation
details. Prefer existing behavior suites, followed by focused integration coverage
for uncovered risks. A new class or extraction alone does not justify a new test.

Existing tests may be updated when implementation ownership changes, but genuine
behavioral regressions must remain covered.

Default checks from the repository root:

```powershell
git diff --check
& .\tests\run-smoke.ps1
```

Run additional verification according to the changed boundary:

- Gateway/session changes: account identity, login, handoff and reconnect tests.
- World RPC/instances: authentication, ownership, instance routing and relevant network suites.
- Economy/items: marketplace, Exchange, inventory, wallet, receipt replay, races and rollback.
- Database/recovery: relevant migration, crash/restart and WAL recovery scenarios.
- Auction performance: existing async search/load fixtures when scheduling, persistence or read/write behavior changes.
- Web UI/CEF: targeted bridge/browser tests, with native validation when changing integration behavior.
- Combat: existing combat/network suites when authoritative simulation behavior changes.

Network suites sharing port 18098 must run sequentially. Do not run every
extended suite for unrelated small changes. Godot 4.7.2 and Node 20.19+
are required for the default smoke checks.

Never run migration or destructive integration tests against real player data.
Use disposable fixtures or verified backups.

Do not add pixel snapshots, exact DOM/geometry, animation-timing assertions or
hardcoded combat balance expectations for routine prototype changes.

See `docs/development/testing.md` for detailed test commands and policy.

## Local artifacts

Use `tools/clean-dev-artifacts.ps1` for disposable verification outputs.
Preserve imports, editor cache, binaries, references, installed CEF and runtime stores.

Keep temporary diagnostics in `.godot/verification`, not at the repository root.