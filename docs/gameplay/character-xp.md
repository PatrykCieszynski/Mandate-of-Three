# Character progression and Stats V1

The current authoritative World3D path uses `PlayerResource.add_experience()`.
EXP cost remains `70 Ã— current level`; overflow crosses any number of levels.
A kill/encounter grants one runtime EXP pool through existing solo/Party reward
rules, independently of item pickup. No per-kill history or SQL write is added.

## EXP milestones

On each level, crossing 25%, 50% and 75% grants one unspent attribute point.
Integer thresholds round upward: level 1 (70 EXP) uses 18, 35 and 53 EXP.
Reaching 100% advances the level and grants one **skill point**, with no additional
attribute-point grant. New characters start with zero allocated/unspent points.
Skill points are stored only; skill spending and active skills are out of scope.
There is no gameplay cap on attribute investment (runtime/SQL use signed 64-bit
integers; JSON-backed counters use decimal strings to avoid rounding above 2^53).

`exp_thresholds_claimed` records the current level's reached milestones and
resets only on level-up. Large rewards process every crossed level, including
its three milestones, before continuing with overflow. Stored level, EXP,
claimed milestones and point balances form one checkpoint state. Reconnect and
checkpoint recovery never re-award that state's milestones. Party `equal`,
`by_level` and `carry` still conserve and distribute EXP first; each recipient
passes their share through this same authoritative progression procedure.

## Warrior coefficients

`AttributeMap.WARRIOR` is the single V1 coefficient matrix. Values below are
**additive contributions per allocated point**, rather than copies of the old
six-attribute multipliers. `weighted(attributes, weights)` lets a future class or
skill use an independent combination of the four attributes; no class/skill
framework or additional playable class is introduced.

| Attribute | Current Warrior contribution |
| --- | --- |
| STR | +1 physical basic attack damage |
| DEX | +0.25 basic attack damage; +0.1 attack-speed percentage point |
| VIT | +10 maximum HP; +0.25 armor |
| INT | +5 maximum MP; +0.05 MP regeneration/second |

Final basic damage truncates to an integer after combining sources. Attack speed
uses the existing ratio/timeline path, so both server timings and animation
playback use the same derived speed. The existing timeline safety bounds remain;
they do not cap attribute investment. No level-difference damage bonus exists.
Positive armor mitigates incoming physical mob damage by `100 / (100 + armor)`.

World3D retains its 100 HP base and the existing `HEALTH_PER_LEVEL = 5` grant per
level past 1. Raising max HP/MP through allocation does not heal or resurrect;
spawn/respawn retains its normal full-HP lifecycle. MP regeneration runs in RAM
for living actors; no active skill, mana-spend mechanic or new HUD is added.

Equipment stays in its existing committed runtime projection. Attribute and
unexpired buff contributions compose on top without rewriting that projection.
Thus equip/upgrade refresh cannot erase allocated attributes, and spending a
point cannot erase a weapon or a buff. Combat reads RAM only. Stat buffs reuse
existing `Stat` names and runtime expiration timestamps.

Derived combat values are a local World projection, rebuilt on committed attribute
allocation, equipment update/invalidation, level change, buff change and instance
entry/transfer. Combat and MP regeneration read that projection; physics ticks do
not copy equipment or recompute attribute/buff contributions. A cached earliest
buff deadline triggers one refresh on expiry, without scanning buffs on every
read. Disconnect discards the projection; reconnect rebuilds it from current sources.

## Persistence, allocation and retry

XP is soft progression: RAM update, dirty character, approximately 60-second
batch checkpoint. Logout/disconnect, local transfer and graceful shutdown force
that checkpoint. The narrow update writes level, EXP, unspent attribute points,
`attributes_json` and `progression_json` (version, milestone count, skill points,
allocation revision). It does not serialize Inventory, quests or the full profile.
A crash may lose progress after the last successful checkpoint.

Allocating a point is immediate: authenticated admission, one native transaction
that checkpoints pending progression, spends one point, updates attributes and
revision, and inserts the successful command receipt. RAM changes follow COMMIT.
Rejected requests do not create durable receipts. Successful receipts are retained
for replay; the same character/command ID with a different attribute conflicts.
The PG player row lock and allocation revision serialize competing allocations.
This remains a single-World profile owner, not multi-World profile authority.

A failed COMMIT is **outcome_unknown**. The PG profile writer closes/fails closed;
no speculative RAM change or automatic replay is allowed. Recover through a fresh
profile owner/load, then query the same command ID. A receipt replay reports the
current snapshot and does not reapply an old attribute snapshot. This preserves
the existing profile-writer failure policy, rather than adding an in-process
reconnect or transaction-worker framework. The synchronous profile writer remains
a limitation for future higher-frequency allocation/load work.

## Existing-character migration

Offline provisioning adds `progression_json` and `stats_commands`; selected PG
startup requires `character_stats` schema version 1. Provision using the existing
operator command before upgrading the server; runtime login does not perform DDL.
SQLite parity fixtures provision the equivalent additive schema.

Rows without Stats V1 metadata are decoded as legacy. All positive spent points
across the six old keys are refunded to their existing unspent balance, and the
old attribute allocation is cleared. No guessed STR/DEX/VIT/INT conversion occurs.
Current EXP initializes the milestone marker **without paying those milestones**;
old levels do not award retroactive skill or attribute points. The existing pool,
including any old creation points, is preserved. The migrated version, cleared
attributes and refund are committed together by checkpoint/allocation/profile
save. Until commit, reloading repeats the same deterministic conversion from the
unchanged old row; after commit it cannot refund again. Item/economy state is not
part of the conversion.

## Stats CEF and backend contract

Use existing authenticated World data requests with matching client/server build
**0.33.0**. Character · V uses these existing RPCs; this UI adds no new network
method, stat authority or speculative allocation.

- `attribute.spend`: `{ "command_id": "stable-intent-id", "attribute": "STR" }`.
  Exactly one point; accepted keys are STR, DEX, VIT, INT. Identity and amounts
  are never client-controlled. Keep the same ID/payload after a lost response.
- Success: `{ "ok": true, "replay": false, "stats": { ... } }`.
- `attribute.get` returns `{ "ok": true, "stats": { ... } }`.
- `progression.get` retains top-level progression fields and also includes the
  four attributes, skill points, allocation revision and derived combat values.
- Snapshot keys: `version`, `revision`, `attributes`, `available_points`,
  `available_skill_points`, `level`, `experience`, `xp_to_next`,
  `thresholds_claimed`, `combat`.
- Failures include `payload`, `points`, `command_conflict`, `stale`,
  `rate_limited`, `storage`, `outcome_unknown`, plus existing session/transfer
  admission failures. `[runtime].stats_attempts_per_second` defaults to eight attempts/second per
  live peer. A bounded cache resolves the last 32 successful IDs/conflicts before
  charging this limiter; cache misses/reconnect lookup still use durable receipts
  and admission. Retrying later preserves the receipt identity.

The compact, draggable CEF **Character · V** window shows level/EXP, the four
attributes, unspent attribute/skill points and derived attack, defense, attack
speed, HP, MP and MP regeneration. V toggles it (C remains the combo toggle).
Each `+` sends one attribute intention; skill points are display-only. Escape and
the close button hide the window without discarding pending allocations.

The client saves one unresolved allocation before send using the existing local
journal, scoped to authority/account/character from authenticated Inventory.
Timeout, reload, local transfer or relog do not mint a new command ID. An explicit
**Retry allocation** resends the stored ID/attribute; other allocations stay blocked
until a terminal result is confirmed and the journal is cleared. Storage/session/
unknown outcomes remain pending. Reopening/refreshing only reads state and never
silently executes an allocation. A corrupt/unwritable journal fails closed.

While open, the window refreshes the RAM-only `attribute.get` snapshot at most
once per second, plus on open/manual refresh. HP/MP follow existing combat
snapshots. Hidden windows do not poll. Late reads cannot overwrite allocation
results; disposed adapters cannot publish to replacement UI. Decimal strings
preserve 64-bit point/attribute counters across JSON/JavaScript without introducing
a gameplay investment cap. Combat totals retain the existing floating-point model.
The standalone preview supplies development-only stats fixtures and local command
feedback; it is not an authoritative gameplay simulator.

The legacy privileged `/setlevel` tool is forward-only and uses the same EXP
milestone path; it cannot rewind EXP to mint previously earned points.
Legacy `attribute.reset` is removed from generic RPC admission. Its old
Inventory-gold mutation is not a supported Stats V1 respec path.

## Verification

`tests/stats_v1.tscn` covers quarter thresholds, multi-level/small-versus-bulk
rewards, no retroactive migration grants, all Party EXP modes, additive stat
sources, revision races, replay/conflict, checkpoint/reload and rollback.
The same persistence contract runs on real PostgreSQL in the existing
`python tools/postgres/run_readiness.py --suite full-state` disposable runner.
`tests/run-combat.ps1 -Scene stats_network -MarkerPrefix STATS` exercises two
clients through actual World RPCs. Run port-18098 network suites sequentially.
Existing XP, PvE, Metin, Party and economy suites remain regression gates.

`tests/run-combat.ps1 -Scene stats_ui_network -MarkerPrefix STATS_UI` verifies
client journal recovery after deliberately losing a committed response, replacement
adapter restoration and stable intent identity with actual World RPCs.
Add `-NativeClient1` for real CEF `+` submission and UI reload. This uses synthetic
browser actions, not physical keyboard/IME/Alt-Tab acceptance. Browser preview tests
exercise the production view through the loopback fixture host.
