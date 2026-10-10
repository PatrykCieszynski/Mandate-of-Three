class_name MetinRuntime
extends RefCounted
## Single authoritative lifecycle; no persistent per-kill/event receipts.
var definition: MetinDefinition
var encounter_id: int = 0
var stone_instance_id: String = ""
var state: String = "COOLDOWN"
var hp: int = 0
var site_index: int = -1
var respawn_at: int = 0
var reward_claimed: bool = false
var participants: Dictionary[int,int] = {}
var crossed: Dictionary[int,bool] = {}
var spawned_mobs: Array[int] = []
func spawn(index: int) -> void:
	assert(definition != null and definition.valid() and index >= 0)
	encounter_id += 1
	stone_instance_id = "metin-%d" % encounter_id
	state = "SPAWNED"
	site_index = index
	hp = definition.max_hp
	reward_claimed = false
	participants.clear()
	crossed.clear()
	spawned_mobs.clear()
func damage(owner: int, amount: int, now: int) -> Dictionary:
	if owner <= 0 or amount <= 0 or state not in ["SPAWNED","ACTIVE"]: return {}
	state = "ACTIVE"
	var applied: int = mini(amount,hp)
	hp -= applied
	participants[owner] = participants.get(owner,0) + applied
	var waves: Array[int] = []
	for i: int in definition.waves.size():
		if not crossed.has(i) and hp * 100 <= definition.max_hp * definition.waves[i].hp_percent:
			crossed[i] = true
			waves.append(i)
	var reward_owner: int = 0
	if hp == 0:
		state = "DEAD"
		respawn_at = now + int(definition.respawn_seconds*1000)
		var highest: int = -1
		for id: int in participants:
			if participants[id] > highest or (participants[id] == highest and id < reward_owner):
				reward_owner = id
				highest = participants[id]
		# Claim before delivery; repeated swings cannot issue another reward.
		reward_claimed = true
	return {"waves":waves,"reward_owner":reward_owner,"damage":applied}
func ready_to_respawn(now: int) -> bool:
	return state in ["DEAD","COOLDOWN"] and now >= respawn_at
