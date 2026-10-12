class_name MetinEncounter
extends Node
var services: MandateWorldServices
@export var definition: MetinDefinition = preload("res://source/common/gameplay/encounters/metin/first_metin.tres")
var runtime := MetinRuntime.new()
var stone: MetinStone3D
var _world: GameWorld3D
func _ready() -> void:
	_world = get_parent()
	assert(definition.valid())
	runtime.definition = definition
	stone = MetinStone3D.new()
	stone.name = "MetinStone"
	_world.add_child(stone)
	if GameMode.is_world_server(): _spawn()
	else: stone.present(definition.display_name,0,definition.max_hp,false)
func active() -> bool:
	return runtime.state in ["SPAWNED","ACTIVE"]
func _spawn() -> void:
	runtime.spawn(randi_range(0,FirstRegionGraybox.METIN_POINTS.size()-1))
	stone.position = FirstRegionGraybox.METIN_POINTS[runtime.site_index]
	stone.present(definition.display_name,runtime.hp,definition.max_hp,true)
func apply_damage(peer_id: int, amount: int, now: int) -> bool:
	if not GameMode.is_world_server() or not _world.combat_endpoint.is_player_alive(peer_id): return false
	var result: Dictionary = runtime.damage(services.player_for_peer(peer_id).player_id,amount,now)
	if result.is_empty(): return false
	for index: int in result.waves: _spawn_wave(definition.waves[index],now,peer_id)
	if int(result.reward_owner) > 0:
		_world.kill_rewards.spawn_reward(stone.position,int(result.reward_owner),now,definition.reward_yang)
	stone.present(definition.display_name,runtime.hp,definition.max_hp,active())
	return true
func _spawn_wave(wave: MetinWaveDefinition, now: int, attacker: int) -> void:
	var pack := _world.mob_system.create_pack(wave.members,stone.position,wave.spawn_radius,wave.spawn_radius+2,maxf(18,wave.spawn_radius+10),0,runtime.stone_instance_id,now+int(definition.wave_lifetime_seconds*1000))
	if pack == null: return # Invalid content is rejected without a partial wave.
	runtime.spawned_mobs.append_array(pack.actor_ids)
	_world.mob_system.aggro_pack(pack.pack_instance_id,attacker)
func tick(now: int) -> void:
	if not GameMode.is_world_server(): return
	for id: int in runtime.spawned_mobs.duplicate():
		if not _world.mob_system.mobs.has(id): runtime.spawned_mobs.erase(id)
	if runtime.state == "DEAD": runtime.state = "COOLDOWN"
	if runtime.ready_to_respawn(now): _spawn()
func snapshot(now: int) -> Dictionary:
	return {"id":runtime.stone_instance_id,"state":runtime.state,"hp":runtime.hp,"max_hp":definition.max_hp,
		"position":stone.position,"title":definition.display_name,"respawn_seconds":maxf(0,(runtime.respawn_at-now)/1000.0)}
func receive_snapshot(data: Dictionary) -> void:
	if GameMode.is_world_server(): return
	runtime.stone_instance_id = str(data.id)
	runtime.state = str(data.state)
	runtime.hp = int(data.hp)
	stone.position = data.position
	stone.present(str(data.title),runtime.hp,int(data.max_hp),active())
