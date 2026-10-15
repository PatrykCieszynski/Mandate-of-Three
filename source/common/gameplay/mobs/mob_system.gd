class_name MobSystem
extends RefCounted
## Owns live mobs/packs and their lifecycle. Hit formulas and rewards are callers.
signal mob_died(result: MobDeathResult)
var mobs: Dictionary[int, MobActor3D] = {}
var packs: Dictionary[int, MobPackRuntime] = {}
var _next_mob_id: int = 0
var _next_pack_id: int = 0
var _warned_unknown_mob_keys: Dictionary[StringName, bool] = {}
## Spatial broadphase is rebuilt at most once per physics frame and invalidated
## on actor lifecycle changes. It is never used to authorize combat hits.
var _body_overlap_index := MobBodyOverlapIndex.new()
var _body_overlap_frame := -1
## Most packs have no replacement tickets; do not traverse them 60 times/sec.
var _respawning_pack_ids: Dictionary[int, bool] = {}
var _world: GameWorld3D
var _endpoint: Node
var services: MandateWorldServices

func setup(world: GameWorld3D, endpoint: Node, adapter: MandateWorldServices) -> void:
	_world = world
	_endpoint = endpoint
	services = adapter

func player_body_overlaps(player: PlayerActor3D) -> Variant:
	var frame := Engine.get_physics_frames()
	if _body_overlap_frame != frame:
		_body_overlap_index.rebuild(mobs)
		_body_overlap_frame = frame
	return _body_overlap_index.overlapping(player)

func create_pack(members: Array[MobSpawnEntry], anchor: Vector3, spawn_radius: float, wander_radius: float, leash_radius: float, respawn_seconds: float = 15, source_metinstone_id: String = "", expires_at: int = 0) -> MobPackRuntime:
	assert(GameMode.is_world_server() and anchor.is_finite() and not members.is_empty())
	assert(spawn_radius >= 0 and wander_radius >= spawn_radius and leash_radius > wander_radius and respawn_seconds >= 0)
	# Reject the whole composition before allocating IDs or spawning any members.
	# This guard also runs in release builds where assertions are disabled.
	for entry: MobSpawnEntry in members:
		if entry == null or not entry.valid():
			push_warning("Rejected mob pack: invalid or noncanonical spawn definition")
			return null
	var pack := MobPackRuntime.new()
	_next_pack_id += 1
	pack.pack_instance_id = _next_pack_id
	pack.anchor = anchor
	pack.spawn_radius = spawn_radius
	pack.wander_radius = wander_radius
	pack.leash_radius = leash_radius
	pack.respawn_seconds = respawn_seconds
	pack.respawn_enabled = respawn_seconds > 0
	pack.source_metinstone_id = source_metinstone_id
	pack.expires_at = expires_at
	pack.rng.randomize()
	packs[pack.pack_instance_id] = pack
	for entry: MobSpawnEntry in members:
		for i: int in entry.count: spawn_mob(entry.mob,pack.random_point(spawn_radius),pack)
	return pack

func spawn_mob(definition: MobDefinition, position: Vector3, pack: MobPackRuntime) -> MobActor3D:
	if not MobDefinitions.is_registered(definition) or not definition.valid():
		push_warning("Rejected mob spawn: invalid or noncanonical definition")
		return null
	assert(GameMode.is_world_server() and packs.get(pack.pack_instance_id) == pack)
	_next_mob_id += 1
	var dog := MobActor3D.new()
	dog.name = "Mob_%d" % _next_mob_id
	dog.definition = definition
	dog.reaction_profile = definition.reaction_profile
	dog.mob_key = definition.mob_key
	dog.max_hp = definition.max_hp
	dog.attack_damage = definition.attack_damage
	dog.move_speed = definition.move_speed
	dog.visual_id = definition.visual_id
	dog.proximity_aggro = definition.proximity_aggro
	dog.title = definition.display_name
	dog.pack_instance_id = pack.pack_instance_id
	dog.source_metinstone_id = pack.source_metinstone_id
	dog.respawn_enabled = pack.respawn_enabled
	dog.expires_at = pack.expires_at
	dog.setup_mob(_next_mob_id,position)
	dog.home = pack.anchor
	dog.wander_at_ms = Time.get_ticks_msec() + pack.rng.randi_range(1000,4000)
	_world.add_child(dog)
	mobs[dog.mob_instance_id] = dog
	_body_overlap_frame = -1
	pack.actor_ids.append(dog.mob_instance_id)
	return dog

func aggro_pack(pack_id: int, peer_id: int) -> void:
	if not GameMode.is_world_server() or not _endpoint.is_player_alive(peer_id) or not packs.has(pack_id): return
	var pack: MobPackRuntime = packs[pack_id]
	if horizontal_distance(_world.characters[peer_id].position,pack.anchor) > pack.leash_radius: return
	for id: int in pack.actor_ids:
		var dog: MobActor3D = mobs.get(id)
		if dog == null or dog.ai_state in [MobState.Value.DEAD,MobState.Value.DISABLED]: continue
		dog.target_peer = peer_id
		dog.ai_state = MobState.Value.CHASE

static func horizontal_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x-b.x,a.z-b.z).length()

func remove_mob(id: int) -> void:
	var dog: MobActor3D = mobs[id]
	dog.collision_layer = 0
	var pack: MobPackRuntime = packs.get(dog.pack_instance_id)
	if pack != null:
		pack.actor_ids.erase(id)
		# An empty, non-respawning pack has no future work. Previously the
		# 60-Hz pack sweep cleaned it on the next tick.
		if not pack.respawn_enabled and pack.actor_ids.is_empty():
			packs.erase(pack.pack_instance_id)
			_respawning_pack_ids.erase(pack.pack_instance_id)
	mobs.erase(id)
	_body_overlap_frame = -1
	dog.queue_free()

func tick(delta: float, now: int) -> void:
	for id: int in mobs.keys():
		var dog: MobActor3D = mobs[id]
		if (dog.expires_at > 0 and now >= dog.expires_at) or (dog.ai_state == MobState.Value.DEAD and now >= dog.dead_until_ms):
			remove_mob(id)
		else: tick_mob(dog,delta,now)
	# Only dead, respawning packs need the time-wheel equivalent of a scan.
	# No duplicate Array allocation or all-pack iteration on the hot path.
	for pack_id: int in _respawning_pack_ids.keys():
		var pack: MobPackRuntime = packs.get(pack_id)
		if pack == null:
			_respawning_pack_ids.erase(pack_id)
			continue
		var index := 0
		while index < pack.replacements.size():
			var ticket: Dictionary = pack.replacements[index]
			if now < int(ticket.at):
				index += 1
				continue
			pack.replacements.remove_at(index)
			spawn_mob(ticket.definition, pack.random_point(pack.spawn_radius), pack)
		if pack.replacements.is_empty():
			_respawning_pack_ids.erase(pack_id)

func die(dog: MobActor3D, now: int) -> void:
	if dog.ai_state == MobState.Value.DEAD: return
	dog.die(now)
	var pack: MobPackRuntime = packs.get(dog.pack_instance_id)
	if dog.respawn_enabled and pack != null:
		pack.replacements.append({"definition":dog.definition,"at":now+int(pack.respawn_seconds*1000)})
		_respawning_pack_ids[pack.pack_instance_id] = true
	_body_overlap_frame = -1
	var death := MobDeathResult.capture(dog,now,services)
	mob_died.emit(death)
	dog.contribution_players.clear()

func begin_return(dog: MobActor3D) -> void:
	var pack: MobPackRuntime = packs.get(dog.pack_instance_id)
	dog.return_target = pack.random_point(pack.wander_radius) if pack != null else dog.home
	dog.ai_state = MobState.Value.RETURN
	dog.target_peer = 0

func tick_mob(dog: MobActor3D, delta: float, now: int) -> void:
	if dog.ai_state in [MobState.Value.DEAD,MobState.Value.DISABLED]: return
	var pack: MobPackRuntime = packs.get(dog.pack_instance_id)
	if pack == null: return
	if dog.hit_reaction.locked(now) or dog.knockback_active():
		dog.simulate_mob(delta,Vector2.ZERO,now)
		return
	if not dog.ai_enabled: return
	if dog.proximity_aggro and dog.ai_state in [MobState.Value.IDLE,MobState.Value.WANDER]:
		var nearest: float = dog.definition.aggro_radius
		var target: int = 0
		for peer_id: int in _world.characters:
			var distance := horizontal_distance(dog.position,_world.characters[peer_id].position)
			if _endpoint.is_player_alive(peer_id) and distance < nearest and horizontal_distance(_world.characters[peer_id].position,pack.anchor) <= pack.leash_radius:
				target = peer_id
				nearest = distance
		if target != 0: aggro_pack(pack.pack_instance_id,target)
	if dog.ai_state in [MobState.Value.CHASE,MobState.Value.ATTACK]:
		if not _endpoint.is_player_alive(dog.target_peer) or horizontal_distance(dog.position,pack.anchor) > pack.leash_radius or horizontal_distance(_world.characters[dog.target_peer].position,pack.anchor) > pack.leash_radius:
			begin_return(dog)
	var direction := Vector2.ZERO
	if dog.ai_state in [MobState.Value.CHASE,MobState.Value.ATTACK]:
		var body: PlayerActor3D = _world.characters[dog.target_peer]
		var offset: Vector3 = body.position - dog.position
		if horizontal_distance(dog.position,body.position) > dog.definition.attack_reach or absf(offset.y) > 1.2 or not _world.has_line_of_sight(dog.position,body.position):
			dog.ai_state = MobState.Value.CHASE
			direction = Vector2(offset.x,offset.z).normalized()
		else:
			dog.ai_state = MobState.Value.ATTACK
			dog.rotation.y = atan2(-offset.x,-offset.z)
			if now >= dog.stunned_until_ms and now - dog.last_attack_ms >= int(dog.definition.attack_interval*1000):
				dog.last_attack_ms = now
				_endpoint.hurt_player(dog.target_peer,dog.attack_damage,now,dog.definition.basic_attack,offset)
	elif dog.ai_state == MobState.Value.RETURN:
		if horizontal_distance(dog.position,dog.return_target) < 0.4:
			dog.hp = dog.max_hp
			dog.contributions.clear()
			dog.contribution_players.clear()
			dog.target_peer = 0
			dog.ai_state = MobState.Value.IDLE
			dog.knockback_velocity = Vector3.ZERO
			dog.wander_at_ms = now + pack.rng.randi_range(1000,4000)
		else:
			direction = Vector2(dog.return_target.x-dog.position.x,dog.return_target.z-dog.position.z).normalized()
	elif dog.ai_state == MobState.Value.IDLE and pack.wander_radius > 0 and now >= dog.wander_at_ms:
		dog.wander_target = pack.random_point(pack.wander_radius)
		dog.ai_state = MobState.Value.WANDER
	elif dog.ai_state == MobState.Value.WANDER:
		if horizontal_distance(dog.position,dog.wander_target) < 0.4:
			dog.ai_state = MobState.Value.IDLE
			dog.wander_at_ms = now + pack.rng.randi_range(2000,5000)
		else:
			direction = Vector2(dog.wander_target.x-dog.position.x,dog.wander_target.z-dog.position.z).normalized()
	dog.simulate_mob(delta,direction,now)

func snapshot(now: int = Time.get_ticks_msec()) -> Array:
	var records: Array = []
	for mob: MobActor3D in mobs.values(): records.append(MobSnapshot.capture(mob,now))
	return records

func apply_snapshot(records: Array) -> void:
	var present: Dictionary[int, bool] = {}
	for record: Array in records:
		var id: int = record[MobSnapshot.Field.ID]
		var key := StringName(record[MobSnapshot.Field.MOB_KEY])
		var definition := MobDefinitions.resolve(key)
		if definition == null:
			if not _warned_unknown_mob_keys.has(key):
				_warned_unknown_mob_keys[key] = true
				push_warning("Unknown replicated mob definition: %s" % key)
			continue
		present[id] = true
		if not mobs.has(id):
			var mob := MobActor3D.new()
			mob.name = "Mob_%d" % id
			mob.definition = definition
			mob.mob_key = definition.mob_key
			mob.max_hp = definition.max_hp
			mob.title = definition.display_name
			mob.visual_id = definition.visual_id
			mob.source_metinstone_id = record[MobSnapshot.Field.SOURCE_METIN]
			mob.setup_mob(id, record[MobSnapshot.Field.POSITION])
			_world.add_child(mob)
			mobs[id] = mob
		mobs[id].present_snapshot(record)
	# An empty full snapshot removes all actors just like any other snapshot.
	for id: int in mobs.keys():
		if not present.has(id):
			mobs[id].queue_free()
			mobs.erase(id)

func apply_hit(dog: MobActor3D, peer_id: int, result: CombatHitResult, direction: Vector3, now: int) -> void:
	aggro_pack(dog.pack_instance_id,peer_id)
	dog.hp -= result.damage
	var owner_id: int = services.owner_id_for_peer(peer_id)
	dog.contributions[owner_id] = dog.contributions.get(owner_id,0)+result.damage
	dog.contribution_players[owner_id] = services.player_for_peer(peer_id)
	if dog.hp == 0: die(dog,now)
	else:
		dog.hit_reaction.apply(result,now)
		dog.apply_knockback(direction,result.knockback_distance)


func remove_peer(peer_id: int) -> void:
	for mob: MobActor3D in mobs.values():
		if mob.target_peer == peer_id:
			mob.target_peer = 0
			if mob.ai_state not in [MobState.Value.DEAD,MobState.Value.DISABLED]: begin_return(mob)

func interpolate(delta: float) -> void:
	for mob: MobActor3D in mobs.values(): mob.interpolate(delta)
