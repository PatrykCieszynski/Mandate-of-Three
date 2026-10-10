class_name MetinEncounter
extends Node
@export var definition: MetinDefinition = preload("res://source/common/gameplay/encounters/metin/first_metin.tres")
var runtime := MetinRuntime.new()
var stone: MetinStone3D
var _world: SpikeWorld3D
var _next_mob_id: int = 1000
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
	if not GameMode.is_world_server() or not _world.combat_endpoint._living(peer_id): return false
	if NavigationServer3D.map_get_iteration_id(_world.get_world_3d().navigation_map) == 0: return false
	var result: Dictionary = runtime.damage(_world.combat_endpoint._owner(peer_id),amount,now)
	if result.is_empty(): return false
	for index: int in result.waves: _spawn_wave(definition.waves[index],now)
	if int(result.reward_owner) > 0:
		_world.combat_endpoint.drop_reward(stone.position,int(result.reward_owner),now,definition.reward_yang)
	stone.present(definition.display_name,runtime.hp,definition.max_hp,active())
	return true
func _spawn_wave(wave: MetinWaveDefinition, now: int) -> void:
	var count: int = wave.count + wave.elite_count
	var map: RID = _world.get_world_3d().navigation_map
	for i: int in count:
		var angle: float = TAU * i / count
		var point: Vector3 = stone.position + Vector3(cos(angle),0,sin(angle))*wave.spawn_radius
		if NavigationServer3D.map_get_iteration_id(map) == 0: continue
		point = NavigationServer3D.map_get_closest_point(map,point)
		if absf(point.y-stone.position.y) > 0.5 or point.distance_to(stone.position) < 2: continue
		_next_mob_id += 1
		var elite: bool = i >= wave.count
		var dog := SpikeWildDog3D.new()
		dog.name = "WildDog_%d" % _next_mob_id
		dog.max_hp = 300 if elite else 120
		dog.attack_damage = 12 if elite else 6
		dog.title = "Metin Elite" if elite else "Metin Dog"
		dog.source_metinstone_id = runtime.stone_instance_id
		dog.respawn_enabled = false
		dog.expires_at = now + int(definition.wave_lifetime_seconds*1000)
		dog.setup_dog(_next_mob_id,point)
		_world.add_child(dog)
		_world.combat_endpoint.dogs[_next_mob_id] = dog
		runtime.spawned_mobs.append(_next_mob_id)
func tick(now: int) -> void:
	if not GameMode.is_world_server(): return
	for id: int in runtime.spawned_mobs.duplicate():
		if not _world.combat_endpoint.dogs.has(id): runtime.spawned_mobs.erase(id)
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
