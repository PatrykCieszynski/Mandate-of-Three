extends Node
const Replication = preload("res://source/common/gameplay/mobs/mob_replication.gd")

func _ready() -> void:
	var mob := MobActor3D.new()
	mob.mob_instance_id = 1
	mob.mob_key = &"wild_dog"
	var mobs: Dictionary[int, MobActor3D] = {1: mob}
	var replication := Replication.new(10, 12, 200, 5)
	replication.begin_frame(mobs, 0)
	var initial: Dictionary = replication.packet_for(10, Vector3.ZERO, 0)
	assert(initial.mob_ids == [1] and initial.mobs.size() == 1)
	assert(replication.packet_for(20, Vector3(30, 0, 0), 0).mob_ids.is_empty())
	var unchanged: Dictionary = replication.packet_for(10, Vector3.ZERO, 100)
	assert(unchanged.mob_ids == [1] and unchanged.mobs.is_empty(), "idle mobs do not repeat their records")
	mob.position.x = 1
	mob.hp -= 1
	replication.begin_frame(mobs, 100)
	var hurt: Dictionary = replication.packet_for(10, Vector3.ZERO, 100)
	assert(hurt.mobs.size() == 1 and hurt.mobs[0][MobSnapshot.Field.HP] == mob.hp)
	assert(hurt.mobs[0][MobSnapshot.Field.POSITION] == null and hurt.mobs[0][MobSnapshot.Field.YAW] == null, "state-only changes omit transforms")
	replication.begin_frame(mobs, 200)
	var moved: Dictionary = replication.packet_for(10, Vector3.ZERO, 200)
	assert(moved.mobs[0][MobSnapshot.Field.POSITION] == mob.position)
	mob.position.x = 2
	replication.begin_frame(mobs, 250)
	assert(replication.packet_for(10, Vector3.ZERO, 250).mobs.is_empty())
	replication.begin_frame(mobs, 400)
	assert(replication.packet_for(10, Vector3.ZERO, 400).mobs[0][MobSnapshot.Field.POSITION] == mob.position, "the final stopped position eventually arrives")
	# XZ projection, negative cells, and different enter/exit radii.
	assert(replication.packet_for(10, Vector3(-9, 90, 0), 410).mob_ids == [1])
	assert(replication.packet_for(20, Vector3(-9, 0, 0), 410).mob_ids.is_empty())
	assert(replication.packet_for(10, Vector3(-11, 0, 0), 420).mob_ids.is_empty())
	var reentered: Dictionary = replication.packet_for(10, Vector3.ZERO, 430)
	assert(reentered.mobs.size() == 1, "re-entry bootstraps even inside the rate window")
	replication.remove_peer(10)
	assert(replication.packet_for(10, Vector3.ZERO, 440).mobs.size() == 1, "a new attachment must not reuse an old baseline")
	var other_instance := Replication.new(10, 12, 200, 5)
	other_instance.begin_frame({}, 500)
	assert(other_instance.packet_for(10, Vector3.ZERO, 500).mob_ids.is_empty())
	var wide := Replication.new(65536, 65536, 200, 1)
	wide.begin_frame(mobs, 500)
	assert(wide.packet_for(30, Vector3.ZERO, 500).mob_ids == [1], "sparse grids do not enumerate empty world space")
	# Removal is represented even when there are no changed records.
	mobs.clear()
	replication.begin_frame(mobs, 600)
	var removed: Dictionary = replication.packet_for(10, Vector3.ZERO, 600)
	assert(removed.mob_ids.is_empty() and removed.mobs.is_empty())
	var old_bytes := var_to_bytes(initial.mobs).size()
	var idle_bytes := var_to_bytes(unchanged.mobs).size()
	assert(idle_bytes < old_bytes)
	print("MOB_INTEREST_OK idle records bytes: ", old_bytes, " -> ", idle_bytes, "; whole packet: ", var_to_bytes(initial).size(), " -> ", var_to_bytes(unchanged).size())
	mob.free()
	get_tree().quit()
