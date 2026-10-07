class_name CombatHit
## The single place every melee / projectile hitbox routes a hit through, so the
## target rules (PvP zones and guild friendly-fire) and the shared
## collision mask live in ONE spot. Adding a new weapon means "spawn an Area2D
## with TARGET_MASK and call try_damage" — it can't forget the flag path or the
## friendly-fire gate the way each hitbox used to re-implement them.

## Collision mask every combat hitbox uses (Area2D.collision_mask): hurtboxes (damage) +
## world (block). NOT character bodies — those are navigation
## only, so attacks hit the body-sized HurtBox instead. See PhysicsLayers + docs/combat_layers.md.
## Projectiles read this; melee arcs set their mask from PhysicsLayers in their own _ready.
const TARGET_MASK: int = PhysicsLayers.COMBAT_TARGET_MASK

## Damage types. Physical is mitigated by ARMOR, magic by MR — pass the right
## one to try_damage (melee/arrows default to physical; wand bolts send magic).
const DAMAGE_PHYSICAL: StringName = &"physical"
const DAMAGE_MAGIC: StringName = &"magic"

enum Result {
	IGNORED,  ## pass through — not a valid target (self, friendly, safe zone…)
	DAMAGED,  ## a combatant took the hit
	BLOCKED,  ## a solid non-combatant (wall / door) — a projectile should stop here
}


## Resolve a hit on [param body] from [param source] for [param damage]. Applies
## the damage when valid and returns how the caller should react: a projectile
## queue_frees on DAMAGED/BLOCKED and passes through on IGNORED; a melee arc just
## ignores the result and lets the damage land. Server-authoritative — call only
## where damage is owned (the hitboxes already gate on multiplayer.is_server()).
static func try_damage(source: Character, body: Node2D, damage: float, damage_type: StringName = DAMAGE_PHYSICAL, deflectable: bool = false) -> Result:
	# Combat hitboxes detect a character's HurtBox area (not its navigation body) — resolve
	# the hurtbox to its owning Character so the target rules below work unchanged.
	if body is HurtBox:
		body = (body as HurtBox).character
	if body == null or body == source:
		return Result.IGNORED

	# A solid body that isn't a combatant = environment (wall / door): blocks
	# projectiles, deals no damage.
	if body is not Character:
		return Result.BLOCKED

	# Only a hostile mob or another player is a valid combatant. Friendly NPCs (shops, quest
	# givers, trainers) + champion statues + any other Character are non-combatants — the hit
	# passes through them. Without this a player one-shots a shopkeeper into a "dead but still
	# standing" state (is_dead latches, die() is a base no-op), and no later hit registers.
	if body is not HostileNpc and body is not Player:
		return Result.IGNORED

	# No NPC-vs-NPC friendly fire (until proper teams exist).
	if source is not Player and body is not Player:
		return Result.IGNORED

	# Player-vs-player respects group/guild allegiance and the target zone.
	if source is Player and body is Player:
		if not can_damage(source as Player, body as Player):
			return Result.IGNORED

	# Sword Deflect: a parry window destroys an incoming projectile (no damage). Only
	# deflectable hits (projectiles opt in) — a melee swing still lands through it. The
	# body is a confirmed enemy here, so a parrying ally never eats a friendly shot.
	if deflectable and (body as Character).is_deflecting():
		return Result.BLOCKED  # caller (the projectile) queue_frees; no damage dealt

	body.take_damage(damage, source, damage_type)
	return Result.DAMAGED


## The single melee-detection path. Server-only. Runs a deterministic physics
## shape query against [param hitbox]'s "CollisionShape2D" child and returns the
## bodies currently inside it. Every melee weapon (sword, pickaxe, sickle, …)
## routes through this, so they all hit the same things — STILL targets included
## (a territory flag, a motionless mob), which an Area2D's enter-events and
## get_overlapping_bodies() miss for a hitbox spawned on top of them. Must be
## called from _physics_process (direct_space_state is only valid during physics).
static func overlapping_bodies(hitbox: Area2D) -> Array[Node2D]:
	var out: Array[Node2D] = []
	var shape_node: CollisionShape2D = hitbox.get_node_or_null(^"CollisionShape2D")
	if shape_node == null or shape_node.shape == null:
		return out
	var space: PhysicsDirectSpaceState2D = hitbox.get_world_2d().direct_space_state
	if space == null:
		return out
	var params := PhysicsShapeQueryParameters2D.new()
	params.shape = shape_node.shape
	params.transform = shape_node.global_transform
	params.collision_mask = hitbox.collision_mask
	params.collide_with_bodies = true
	params.collide_with_areas = true # also catch HurtBox areas (the hit target), not just bodies
	for hit: Dictionary in space.intersect_shape(params, 16):
		var collider: Object = hit.get("collider")
		if collider is Node2D:
			out.append(collider as Node2D)
	return out


## Allies are the same player, co-op groupmates or members of the same guild.
static func are_allied(a: Player, b: Player) -> bool:
	if a == null or b == null:
		return false
	if a == b:
		return true
	if a.player_resource == null or b.player_resource == null:
		return false
	# Co-op group (dungeon) — groupmates are allies regardless of guild.
	if GroupService.are_grouped(int(a.player_resource.current_peer_id), int(b.player_resource.current_peer_id)):
		return true
	var guild: int = a.player_resource.active_guild_id
	return guild > 0 and guild == b.player_resource.active_guild_id


## THE mob-side allegiance check (the faction seam — refactor P3). Two NPCs are
## on the same side iff they share an owner: wild mobs (owner_guild_id 0) ally
## with each other, a guild's flag guards ally with each other, and the two
## never mix. When summons / escort NPCs / real factions arrive, extend HERE
## ("side = the summoner's side"), never at call sites.
static func are_allied_npcs(a: HostileNpc, b: HostileNpc) -> bool:
	if a == null or b == null:
		return false
	return a.owner_guild_id == b.owner_guild_id


## Player damage respects allegiance, respawn immunity and the target PvP zone.
static func can_damage(source: Player, target: Player) -> bool:
	if source == null or target == null or source == target:
		return false
	if are_allied(source, target):
		return false
	# Post-respawn spawn protection.
	if target.is_pvp_immune():
		return false
	return target.is_pvp()
