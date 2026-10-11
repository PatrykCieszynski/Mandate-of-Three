extends "res://tests/pve_network.gd"
## Opt-in contracts for shared speed, one-intent chaining and confirmed feedback.
@rpc("authority", "call_remote", "reliable", 0)
func phase(command: String, _uid: String) -> void:
	if command != "DONE": return
	var view: WarriorVisual3D = world.characters[world.local_peer].player_presentation
	view.set_alive(true)
	view.set_hit_lock(0,0)
	view.play_basic_attack(BasicAttackCombos.BASE.steps[0].animation_key,437,1.22)
	check(is_equal_approx(view._attack_ratio,1.22),"accepted visual speed 1.22")
	if view.player != null: check(is_equal_approx(view.player.speed_scale,1.22),"AnimationPlayer receives accepted ratio")
	if failed: return
	print("FEEL2_CLIENT_OK ",client_number)
	finished.rpc_id(1)
	await get_tree().create_timer(.5).timeout
	peer.close()
	get_tree().quit()
func run_server() -> void:
	await wait_until(func() -> bool: return world.characters.size() == 2 and ready_peers.size() == 2)
	var combat := world.combat_endpoint
	for dog: SpikeWildDog3D in combat.dogs.values(): dog.ai_enabled = false
	var hero: int = world.characters.keys()[0]
	var owner: int = WorldServer.curr.connected_players[hero].player_id
	var runtime: Dictionary = WorldServer.curr.runtime_equipment[owner]
	var sequence := 10000
	for speed: float in [100.0,122.0]:
		combat._clear_attack_intents(hero)
		combat._next_attack_ms.erase(hero)
		combat.combo_state(hero).reset()
		runtime.stats.attack_speed = speed
		var now := Time.get_ticks_msec()
		check(combat.begin_attack(hero,sequence,now),"start at requested authoritative speed")
		sequence += 1
		var active: Dictionary = combat._active_attacks[hero]
		var step: BasicAttackStepDefinition = active.step
		var ratio := speed/100.0
		check(is_equal_approx(active.ratio,ratio) and active.impact-now == int(ceil(step.impact_ms/ratio)),"impact and speed share one ratio")
		check(combat._next_attack_ms[hero]-now == int(ceil(step.direct_input_ms/ratio)),"canonical direct input divided by speed")
		check(active.timing.end == int(ceil(step.recovery_ms/ratio)) and active.timing.preinput == int(ceil(step.preinput_ms/ratio)) and active.timing.limit == int(ceil(step.input_limit_ms/ratio)),"all accepted deadlines share the ratio")
		check(not combat.begin_attack(hero,sequence,now+int(active.timing.preinput)-1),"pre-input boundary enforced")
		sequence += 1
		check(combat.begin_attack(hero,sequence,now+int(active.timing.preinput)),"one intent queues at pre-input")
		var accepted_sequence := sequence
		sequence += 1
		check(not combat.begin_attack(hero,accepted_sequence,now+int(active.timing.preinput)),"replay rejected")
		check(not combat.begin_attack(hero,sequence,now+int(active.timing.preinput)),"second queued intent rejected")
		sequence += 1
		combat.remember_next_facing(hero,Vector2.RIGHT)
		check(is_equal_approx(float(active.yaw),world.characters[hero].rotation.y),"current yaw committed")
		# Equipment changes cannot mutate the accepted ratio; next swing sees new stats.
		runtime.stats.attack_speed = 150.0
		check(is_equal_approx(active.ratio,ratio),"accepted speed frozen across equipment mutation")
		combat._advance_attack_queue(now+int(active.timing.direct)-1)
		check(combat._active_attacks[hero] == active,"no early transition")
		combat._advance_attack_queue(now+int(active.timing.direct))
		var next: Dictionary = combat._active_attacks[hero]
		check(next.step_index == 1 and next.action_id == accepted_sequence and is_equal_approx(next.ratio,1.5),"queued step starts exactly at link without request polling")
		check(is_equal_approx(next.yaw,-PI/2) and not is_equal_approx(next.yaw,active.yaw),"next step receives buffered facing")
		combat._advance_attack_queue(now+int(active.timing.direct)+1)
		check(combat._active_attacks[hero] == next and not combat._queued_attacks.has(hero),"intent consumed exactly once")
		combat._clear_attack_intents(hero)
		world.characters[hero].rotation.y = 0
	# A late intent starts a new chain, never extends the expired input window.
	combat._next_attack_ms.erase(hero)
	combat.combo_state(hero).reset()
	runtime.stats.attack_speed = 100.0
	var late_now := Time.get_ticks_msec()
	check(combat.begin_attack(hero,sequence,late_now),"start late-input fixture")
	sequence += 1
	var late: Dictionary = combat._active_attacks[hero]
	check(combat.begin_attack(hero,sequence,late_now+int(late.timing.limit)+1),"late intent can start a fresh chain")
	sequence += 1
	check(combat._active_attacks[hero].step_index == 0,"expired input limit cannot extend combo")
	combat._clear_attack_intents(hero)
	# The old inactivity timeout must not reset a correctly buffered slow swing.
	combat._next_attack_ms.erase(hero)
	combat.combo_state(hero).reset()
	runtime.stats.attack_speed = 25.0
	var slow_now := Time.get_ticks_msec()
	check(combat.begin_attack(hero,sequence,slow_now),"start slow-speed fixture")
	sequence += 1
	var slow: Dictionary = combat._active_attacks[hero]
	check(combat.begin_attack(hero,sequence,slow_now+int(slow.timing.preinput)),"buffer slow attack")
	sequence += 1
	combat._advance_attack_queue(slow_now+int(slow.timing.direct))
	check(combat._active_attacks[hero].step_index == 1,"slow buffered chain survives inactivity timeout")
	combat._clear_attack_intents(hero)
	# Toggle leaves committed definition/timing intact; knockdown and death discard queue.
	runtime.stats.attack_speed = 100.0
	for lethal: bool in [false,true]:
		combat._next_attack_ms.erase(hero)
		combat.health[hero] = 100
		world.characters[hero].hit_reaction.clear()
		world.characters[hero].knockback_velocity = Vector3.ZERO
		var now := Time.get_ticks_msec()
		check(combat.begin_attack(hero,sequence,now),"start interruption fixture")
		sequence += 1
		var active: Dictionary = combat._active_attacks[hero]
		check(combat.begin_attack(hero,sequence,now+int(active.timing.preinput)),"queue before interrupt")
		sequence += 1
		var frozen: BasicAttackStepDefinition = active.step
		combat.set_combo_skill_level(hero,2)
		combat.set_combo_enabled(hero,true)
		check(active.step == frozen,"toggle cannot rewrite accepted step")
		combat.hurt_player(hero,10000 if lethal else 1,now,BasicAttackCombos.BASE.steps.back(),Vector3.FORWARD)
		check(not combat._queued_attacks.has(hero) and not combat._active_attacks.has(hero),"death/knockdown clear queued and current intent")
	# Client presentation class receives confirmed semantic events, never HP deltas.
	var feedback := CombatFeedback3D.new()
	add_child(feedback)
	feedback.set_process(false)
	var target: SpikeWildDog3D = combat.dogs.values()[0]
	var hp := target.hp
	for count: int in [20,50]:
		var before := feedback.number_events
		var started := Time.get_ticks_usec()
		for id: int in count:
			var event := {"attacker":hero,"action_id":count,"target_kind":"mob","target_id":id,"damage":1,"reaction":HitReaction.Type.FLINCH}
			check(feedback.confirm(event,target,true),"confirmed hit creates feedback")
			check(not feedback.confirm(event,target,true),"duplicate confirmation deduplicated")
		check(feedback.number_events-before == count,"one combat-number event per confirmed target")
		check(target.hp == hp,"feedback cannot mutate authoritative HP")
		feedback._process(1.0)
		check(feedback.numbers.is_empty() and feedback.sparks.is_empty(),"short lived effects return to pools")
		print("FEEL2_PRESENTATION targets=",count," usec=",Time.get_ticks_usec()-started)
	check(not feedback.confirm({"damage":0},target,true),"miss creates no damage number")
	var before := feedback.number_events
	check(feedback.confirm({"attacker":hero+1,"action_id":99,"target_id":1,"damage":5},target,false) and feedback.number_events == before,"remote hit has spark but no outgoing number")
	feedback.free()
	if failed: return
	print("FEEL2_SERVER_OK speed100/122, one-intent buffer, facing, interruption and bounded confirmed feedback")
	set_phase("DONE")
	await wait_until(func() -> bool: return done_peers.size() == 2)
	peer.close()
	db.close_db()
	get_tree().quit()
