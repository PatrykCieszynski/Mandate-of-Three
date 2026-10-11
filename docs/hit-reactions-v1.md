# Hit Reactions v1

World resolves damage and reactions from `AttackHitDefinition` resources. Animation
callbacks never apply damage or end gameplay locks. There is no poise, stagger,
CrowdControlManager or generic effect framework.

## Basic attacks

`BasicAttackHits.COMBO` contains four resources: hits 1–3 request FLINCH, hit 4
requests KNOCKDOWN. Each defines damage multiplier, impact/recovery timing,
reaction/down duration, get-up duration and presentation clip. Timing is defined
on the server; the visual is an independent presentation of the accepted swing.
The v1 finisher has 1.2 seconds down and 0.4 seconds getting up. These are prototype
content values. The attacker can continue its own combo; the target's lock does not
lock the attacker. The former per-hit stun and third-hit physical knockback are
removed from the basic combo.

Stable reaction wire values: NONE=0, FLINCH=1, KNOCKBACK=2, KNOCKDOWN=3. Stun remains
separate (`stunned_until_ms` on the existing mob runtime); flinch never installs it.

## Profiles and authoritative resolution

`MobDefinition.reaction_profile` selects a small resource. Normal mobs and players
allow all reactions. Elite allows flinch and reduced knockback distance, but
rejects knockdown by default. Boss/world boss allow visual flinch and reject
knockback/knockdown. Content can author profile overrides on canonical definitions.
Knockdown resistance is independent of dedicated interrupt resistance.

`HitReactionResolver` returns actual capped damage, accepted reaction, duration,
get-up duration and interrupt decision. A resisted/repeated knockdown falls back
to visual flinch if permitted. Lethal damage wins over reactions. A dedicated
`interrupt_attack` is separate from knockdown immunity; ordinary flinch never
interrupts. KNOCKBACK's contract includes scaled distance and optional interrupt,
but no shipped attack uses physical knockback in this slice. Movement/displacement
for that reaction remains a later server physics task.

Each actor has `HitReactionState` with down/get-up deadlines. Both phases block
new attacks and movement. Re-hits during either phase still deal damage but cannot
extend the lock. Mob AI state/target remains intact and resumes normal chase/attack
after unlock. Mobs currently deal instantaneous range/cooldown damage, so they have
no delayed hit queue to cancel; the AI attack branch cannot run while locked.
Player knockdown erases the pending swing and combo continuity, and the impact
resolver also checks the action lock. Death clears the lock; respawn starts clean.

The existing player-target damage handler uses the same resolver and profile,
including interruption of a player already attacking. No player-target selection,
friendly-fire policy or PvP authorization/attack RPC is added here. Network tests
exercise this server-only handler as the mechanics foundation for future PvP.

## Replication and presentation

Accepted hit events carry presentation results. Full mob snapshots append remaining
down and get-up milliseconds; player combat snapshots carry the same two values
in `hit_locks`. An actor created or reconnected during a lock reconstructs its
presentation from those remaining times. Repeated full snapshots synchronize the
phase without replaying the fall. Buffers remain 1 MiB. Server and client must be
restarted together for the changed wire record.

FLINCH is presentation only. An ongoing player swing keeps its clip and receives
visual feedback; otherwise the hit clip plays. Mob hit presentation returns to its
current attack/locomotion independently of its uninterrupted server cooldown.

Current development GLBs have three attack clips and no knockdown/get-up clips.
The fourth attack temporarily reuses `attack_3`; the server still executes the
fourth definition. `KnockdownVisual` uses supplied `knockdown`/`get_up` clips when
available, otherwise a short visual fall and interpolated upright recovery. Only
the content node rotates; collision, position and server simulation stay intact.
Final attack_4/fall/get-up assets and native feel/timing review remain a manual
milestone. Headless tests prove state/input authority, not animation quality.

## Checks

Default smoke adds one durable `hit_reactions` case: flinch, profile resistance,
interrupt independence, bounded repeated hits, death precedence and late-join
remaining time. Existing two-client `run-combat` covers four directional/multitarget
hits, replicated down/get-up, AI movement/attack lock, player pending-hit cancellation,
immune target continuity, death and respawn. Dog/warrior headless presentation
checks verify state transitions and keep animation out of gameplay authority.
