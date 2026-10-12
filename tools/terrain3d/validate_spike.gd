extends SceneTree
## Opt-in persisted heightfield/production-body contracts absent from box-map tests.
const SCENE := "res://source/common/gameplay/maps/terrain3d_spike/terrain_spike.tscn"
var failed: bool = false

func _initialize() -> void:
	call_deferred("validate")

func check(ok: bool, detail: String) -> void:
	if not ok:
		failed = true
		push_error("TERRAIN_PERSIST_FAILED: "+detail)

func validate() -> void:
	var packed: PackedScene = load(SCENE)
	print("TERRAIN_ASSETS_FILE ",load("res://source/common/gameplay/maps/terrain3d_spike/terrain_assets.tres").texture_list.size())
	var spike: Terrain3DSpike = packed.instantiate()
	print("TERRAIN_ASSETS_INSTANCE ",spike.get_node("Navigation/Terrain").assets.texture_list.size())
	root.add_child(spike)
	spike.animate_preview = false
	var terrain = spike.terrain
	check(terrain.get_region_size()==64,"cold load derives 64 from saved region data")
	check(terrain.data.get_region_count()==1,"exactly one persisted region")
	check(terrain.data.get_region(Vector2i.ZERO).region_size==64,"region persists its own size")
	check(terrain.assets.texture_list.size()==4,"external grass/dirt/path/rock assets load")
	check(not terrain.material.resource_path.is_empty() and not terrain.assets.resource_path.is_empty(),"normal external resources")
	# Manual sculpting changes the initial formula; validate persisted data itself.
	check(is_finite(terrain.data.get_height(Vector3(13,0,14))),"saved height data present")
	await physics_frame
	await physics_frame
	var ray := PhysicsRayQueryParameters3D.create(Vector3(13,20,14),Vector3(13,-5,14),1)
	var hit: Dictionary = spike.get_world_3d().direct_space_state.intersect_ray(ray)
	check(not hit.is_empty() and absf(hit.position.y-terrain.data.get_height(Vector3(13,0,14)))<0.02,"native terrain raycast matches saved sample")
	for step: int in 30:
		await physics_frame
		spike.player.simulate(1.0/60.0,Vector2.ZERO)
	check(spike.player.is_on_floor(),"production player stands on persisted terrain")
	for walk: Dictionary in [
		{"name":"flat","start":Vector3(13,0,14),"direction":Vector2(1,0)},
		{"name":"uphill","start":Vector3(15,0,30),"direction":Vector2(1,0)},
		{"name":"downhill","start":Vector3(24,0,30),"direction":Vector2(1,0)}]:
		var p: Vector3 = walk.start
		p.y = terrain.data.get_height(p)+0.1
		spike.player.position = p
		spike.player.velocity = Vector3.ZERO
		for step: int in 30:
			await physics_frame
			spike.player.simulate(1.0/60.0,Vector2.ZERO)
		var start: Vector3 = spike.player.position
		for step: int in 48:
			await physics_frame
			spike.player.simulate(1.0/60.0,walk.direction)
		var end: Vector3 = spike.player.position
		check(end.x>start.x+1 and end.is_finite() and spike.player.is_on_floor(),"production walking "+walk.name)
		check(absf(end.y-terrain.data.get_height(end))<0.25,"feet follow authored height without hovering/sinking "+walk.name)
		print("TERRAIN_WALK ",walk.name," ",start," -> ",end)
	if "--save-again" in OS.get_cmdline_user_args():
		for region in terrain.data.get_regions_active(): region.modified = true
		terrain.data.save_directory(terrain.data_directory)
		check(ResourceSaver.save(terrain.material,terrain.material.resource_path)==OK,"save external material again")
		check(ResourceSaver.save(terrain.assets,terrain.assets.resource_path)==OK,"save external assets again")
		var saved := PackedScene.new()
		check(saved.pack(spike)==OK and ResourceSaver.save(saved,SCENE)==OK,"normal PackedScene persistence")
		var state: SceneState = saved.get_state()
		for node: int in state.get_node_count():
			for prop: int in state.get_node_property_count(node):
				check(state.get_node_property_name(node,prop)!=&"region_size","editor-only migration is not serialized by normal save")
		print("TERRAIN_SAVE_AGAIN_OK: scene, regions and external resources")
	if not failed: print("TERRAIN_PERSIST_OK: cold 64x64 native data, material/assets, raycast and production movement")
	quit(1 if failed else 0)
