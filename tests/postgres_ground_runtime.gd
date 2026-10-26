extends Node
const Schema = preload("res://source/server/world/database/postgres/inventory_session_schema_postgres.gd")
const Executor = preload("res://source/server/world/database/postgres/inventory_executor_postgres.gd")
const Inventory = preload("res://source/server/world/database/postgres/inventory_runtime_postgres.gd")
const GroundRuntime = preload("res://source/server/world/database/postgres/ground_item_runtime_postgres.gd")
const Sessions = preload("res://source/server/world/database/postgres/inventory_session_postgres.gd")
const Items = preload("res://source/server/world/database/postgres/item_store_postgres.gd")
const WalletStore = preload("res://source/server/world/database/postgres/wallet_store_postgres.gd")
var pg: Object
var world:=FixtureWorld.new()
var pools: Array=[]
var answers: Array=[]
var facts: int=0
var ticks: int=0

class FixtureWorld extends WorldServer:
	func inventory_master_available() -> bool: return true # Seeded transport only.

class FaultyExecutor extends "res://source/server/world/database/postgres/inventory_executor_postgres.gd":
	var lose_initialize:=false
	var lose_claim:=false
	func poll() -> Array:
		var events: Array=super.poll()
		for event: Dictionary in events:
			if event.result.get("ok",false) and ((lose_initialize and event.intent=="item_initialize" and event.session.account_id==9800) or (lose_claim and event.intent=="ground_claim")):
				if event.intent=="item_initialize": lose_initialize=false
				else: lose_claim=false
				event.result={"ok":false,"error":"outcome_unknown","outcome_unknown":true}
				event.committed=false
		return events

class Alive extends RefCounted:
	var dead:=false
	func is_player_alive(_peer: int) -> bool: return not dead

class LootMap extends Node3D:
	var characters: Dictionary={}
	var combat_endpoint:=Alive.new()
	var ground_loot:=GroundLootSystem.new()
	var clear_sight:=true
	func has_line_of_sight(_a: Vector3, _b: Vector3) -> bool: return clear_sight

var map:=LootMap.new()
func _physics_process(_delta: float) -> void: ticks+=1
func wait_for(predicate: Callable) -> void:
	var deadline: int=Time.get_ticks_msec()+8000
	while not predicate.call() and Time.get_ticks_msec()<deadline: await get_tree().process_frame
	assert(predicate.call(),"bounded ground runtime acceptance")

func bind(peer: int, character: int, token: String) -> void:
	var player:=PlayerResource.new()
	player.player_id=character
	player.current_peer_id=peer
	world.connected_players[peer]=player
	world.player_id_to_peer_id[character]=peer
	world._session_tokens[peer]=token
	var body:=Node3D.new()
	map.add_child(body)
	map.characters[peer]=body

func grant(account: int, character: int, token: String, epoch: int) -> Dictionary:
	var result: Dictionary=Sessions.new(pg).install_verified_grant(Sessions.identity_from_verified_ticket(account,character,token),epoch)
	assert(result.ok,str(result))
	return result.context

func result(uid: String) -> Dictionary:
	var matches: Array=answers.filter(func(row: Dictionary) -> bool: return row.uid==uid)
	return {} if matches.is_empty() else matches.back().result
func items(character: int) -> Array: return Items.new(pg).inventory(character).items
func ready(peer: int) -> bool: return world.inventory_runtime.mutations_allowed(peer)
func spawn_drop(owner: int, amount: int = 3) -> String:
	return map.ground_loot.spawn_resolved_item(Vector3.ZERO,owner,"fixture",Time.get_ticks_msec(),&"upgrade_ore",amount,[])
func claim(peer: int, uid: String) -> Dictionary:
	answers=answers.filter(func(row: Dictionary) -> bool: return row.uid!=uid)
	var queued: Dictionary=map.ground_loot.pickup_for_peer(peer,uid,Time.get_ticks_msec())
	if not queued.get("queued",false): return queued
	await wait_for(func() -> bool: return not result(uid).is_empty())
	return result(uid)

func _ready() -> void:
	assert(OS.get_environment("MANDATE_PG_FIXTURE")=="owned-local-cluster")
	var connection: String=OS.get_environment("MANDATE_PG_FIXTURE_CONNECTION")
	pg=ClassDB.instantiate("GodotSociDatabase")
	assert(pg.open("postgresql",connection) and Schema.ensure_schema(pg))
	for account: int in [9800,9801]:
		assert(WalletStore.new(pg).initialize_account(account).ok)
		assert(Items.new(pg).bind_character(account*10,account) and Items.new(pg).bind_character(account*10+1,account))
	var a:=grant(9800,98000,"ground-a",0)
	var b:=grant(9801,98010,"ground-b",0)
	add_child(map)
	bind(100,98000,"ground-a")
	bind(200,98010,"ground-b")
	WorldServer.curr=world
	map.ground_loot.setup(map,MandateWorldServices.new())
	for index: int in 2:
		var pool:=FaultyExecutor.new()
		assert(pool.start(connection,2,2))
		pools.append(pool)
	await wait_for(func() -> bool:
		for pool: RefCounted in pools: pool.poll()
		return pools.all(func(pool: RefCounted) -> bool: return pool.is_ready()))
	pools[0].lose_initialize=true
	world.inventory_runtime=Inventory.new(world,pools[0])
	world.ground_item_runtime=GroundRuntime.new(world.inventory_runtime,pools[1])
	world.ground_item_runtime.finished.connect(func(_peer: int, _ground: RefCounted, uid: String, value: Dictionary) -> void: answers.append({"uid":uid,"result":value}))
	world.ground_item_runtime.committed.connect(func(_peer: int, _ground: RefCounted) -> void: facts+=1)
	add_child(world)
	assert(world.inventory_runtime.attach(100,a) and world.inventory_runtime.attach(200,b))
	await wait_for(func() -> bool: return world.inventory_runtime.status(100)=="paused" and ready(200))
	assert(items(98000).size()==2 and not ready(100) and world.runtime_attack(98000)==-1)
	assert(world.inventory_runtime.retry(100))
	await wait_for(func() -> bool: return ready(100))
	assert(items(98000).size()==2 and items(98010).size()==2,"marker prevents duplicate starter kit after lost successful COMMIT")
	assert(Items.new(pg).initialize_character(98000).error=="session_required")
	var uid:=spawn_drop(98000)
	assert(Items.new(pg).claim_ground_item(98000,uid,GroundLootSystem.prepare_claim_item(uid,98000,map.ground_loot.drops[uid])).error=="session_required")
	assert((await claim(200,uid)).error=="reserved")
	map.characters[100].position=Vector3(20,0,0)
	assert((await claim(100,uid)).error=="distance")
	map.characters[100].position=Vector3.ZERO
	map.clear_sight=false
	assert((await claim(100,uid)).error=="distance")
	map.clear_sight=true
	map.combat_endpoint.dead=true
	assert((await claim(100,uid)).error=="player")
	map.combat_endpoint.dead=false
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9800 FOR NO KEY UPDATE;").ok)
	assert(map.ground_loot.pickup_for_peer(100,uid,Time.get_ticks_msec()).queued)
	var before: int=ticks
	map.ground_loot.expire(Time.get_ticks_msec()+300000)
	assert(map.ground_loot.drops.has(uid) and map.ground_loot.pending_claims.has(uid),"in-flight drop cannot expire before outcome")
	var other:=spawn_drop(98010)
	assert((await claim(200,other)).ok and ticks>before and result(uid).get("ok",false)==false)
	assert(pg.commit())
	await wait_for(func() -> bool: return result(uid).get("ok",false))
	assert(not map.ground_loot.drops.has(uid) and not map.ground_loot.pending_claims.has(uid))
	assert(items(98000).any(func(row: Dictionary) -> bool: return row.uid==uid and row.amount==3 and row.affixes.is_empty()))
	var prior: int=facts
	assert((await claim(100,uid)).ok and facts==prior,"missing drop only reads same-account receipt")
	assert((await claim(200,uid)).error=="claimed")
	# Refusing a full native pool must release the drop reservation and never
	# retain an invisible mutation that executes later when capacity reopens.
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9800 FOR NO KEY UPDATE;").ok)
	for index: int in 4: assert(pools[1].submit_ground_receipt(a,uid).queued)
	var refused:=spawn_drop(98010)
	assert((await claim(200,refused)).error=="busy" and map.ground_loot.drops.has(refused) and not map.ground_loot.pending_claims.has(refused))
	assert(pg.commit())
	await wait_for(func() -> bool: return pools[1].pending_count()==0)
	assert(int(pg.query("SELECT COUNT(*) AS n FROM economy.ground_item_claims WHERE drop_uid=:uid;",{"uid":refused}).rows[0].n)==0)
	assert((await claim(200,refused)).ok)
	# Party-free reservation still funnels one UID through the same PG claim owner.
	assert(world.party_service.command(98000,{"action":"invite","target":98010}).ok)
	assert(world.party_service.command(98010,{"action":"accept"}).ok)
	var party_id: int=world.party_service.membership[98000]
	uid=spawn_drop(0)
	map.ground_loot.protect_party_item(uid,{"owner":0,"allowed":[98000,98010]},party_id)
	assert(map.ground_loot.protection_allows(map.ground_loot.drops[uid],98010,Time.get_ticks_msec()))
	assert(world.party_service.command(98010,{"action":"leave"}).ok)
	assert((await claim(200,uid)).error=="reserved")
	assert(world.party_service.command(98000,{"action":"invite","target":98010}).ok)
	assert(world.party_service.command(98010,{"action":"accept"}).ok)
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9800 FOR NO KEY UPDATE;").ok)
	assert(map.ground_loot.pickup_for_peer(100,uid,Time.get_ticks_msec()).queued)
	assert((await claim(200,uid)).error=="operation_pending")
	assert(pg.commit())
	await wait_for(func() -> bool: return result(uid).get("ok",false))
	assert((await claim(200,uid)).error=="claimed")
	assert(int(pg.query("SELECT COUNT(*) AS n FROM economy.item_instances WHERE uid=:uid;",{"uid":uid}).rows[0].n)==1)
	assert(int(pg.query("SELECT COUNT(*) AS n FROM economy.ground_item_claims WHERE drop_uid=:uid;",{"uid":uid}).rows[0].n)==1)
	# Public drop: the second client cannot enqueue another claim for one UID.
	uid=spawn_drop(0)
	map.ground_loot.drops[uid].protected_until=Time.get_ticks_msec()
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9800 FOR NO KEY UPDATE;").ok)
	assert(map.ground_loot.pickup_for_peer(100,uid,Time.get_ticks_msec()).queued)
	assert((await claim(200,uid)).error=="operation_pending")
	assert(pg.commit())
	await wait_for(func() -> bool: return result(uid).get("ok",false))
	assert((await claim(200,uid)).error=="claimed")
	# Full inventory keeps the rolled drop/UID and creates no durable claim.
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9800 FOR NO KEY UPDATE;").ok)
	var store:=Items.new(pg)
	var filler: String=""
	while true:
		var free: Dictionary=store.resolve_inventory_position(98000,1)
		if not free.ok:
			assert(free.error=="inventory_full")
			break
		var item:=ItemInstance.create(ItemDefinitions.UPGRADE_ORE,98000,[])
		assert(store.receive_item_in_transaction(item,free.position).ok)
		filler=item.uid
	assert(pg.commit())
	assert(world.inventory_runtime.invalidate_item_state(Items.new(pg).inventory(98000).item_state))
	await wait_for(func() -> bool: return ready(100))
	uid=spawn_drop(98000,9)
	prior=facts
	assert((await claim(100,uid)).error=="bag_full" and map.ground_loot.drops.has(uid) and not map.ground_loot.pending_claims.has(uid) and facts==prior)
	assert(int(pg.query("SELECT COUNT(*) AS n FROM economy.ground_item_claims WHERE drop_uid=:uid;",{"uid":uid}).rows[0].n)==0)
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9800 FOR NO KEY UPDATE;").ok)
	assert(pg.execute("DELETE FROM economy.item_custody WHERE uid=:uid;",{"uid":filler}).ok)
	assert(pg.execute("DELETE FROM economy.item_instances WHERE uid=:uid;",{"uid":filler}).ok and pg.commit())
	assert(world.inventory_runtime.invalidate_item_state(Items.new(pg).inventory(98000).item_state))
	await wait_for(func() -> bool: return ready(100))
	assert((await claim(100,uid)).ok)
	# Free two cells for the subsequent fault-injection scenarios.
	assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9800 FOR NO KEY UPDATE;").ok)
	assert(pg.execute("DELETE FROM economy.item_custody WHERE uid IN (SELECT uid FROM economy.item_instances WHERE owner_character_id=98000 AND definition_id='upgrade_ore' ORDER BY uid LIMIT 2);").ok)
	assert(pg.execute("DELETE FROM economy.item_instances i WHERE owner_character_id=98000 AND NOT EXISTS(SELECT 1 FROM economy.item_custody c WHERE c.uid=i.uid);").ok and pg.commit())
	assert(world.inventory_runtime.invalidate_item_state(Items.new(pg).inventory(98000).item_state))
	await wait_for(func() -> bool: return ready(100))
	# Native failed COMMIT leaves the exact rolled drop available after lookup.
	uid=spawn_drop(98000,5)
	assert(pg.execute("CREATE FUNCTION economy.fixture_ground_commit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'ground commit fixture' USING ERRCODE='40001'; END; $$;").ok)
	assert(pg.execute("CREATE CONSTRAINT TRIGGER fixture_ground_commit AFTER INSERT ON economy.ground_item_claims DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION economy.fixture_ground_commit();").ok)
	assert((await claim(100,uid)).error=="outcome_unknown")
	assert(map.ground_loot.drops.has(uid) and map.ground_loot.pending_claims.has(uid))
	assert(world.ground_item_runtime.receipt(100,uid).queued)
	await wait_for(func() -> bool: return world.ground_item_runtime.drained() and ready(100))
	assert(result(uid).error=="unknown_command" and map.ground_loot.drops.has(uid) and not map.ground_loot.pending_claims.has(uid))
	assert(pg.execute("DROP TRIGGER fixture_ground_commit ON economy.ground_item_claims;").ok)
	assert((await claim(100,uid)).ok)
	# A successful COMMIT lost before reconciliation is discovered read-only.
	uid=spawn_drop(98000,7)
	pools[1].lose_claim=true
	assert((await claim(100,uid)).error=="outcome_unknown")
	var alt:=grant(9800,98001,"ground-alt",1)
	world.inventory_runtime.detach(100)
	bind(101,98001,"ground-alt")
	assert(world.inventory_runtime.attach(101,alt))
	await wait_for(func() -> bool: return ready(101) and world.ground_item_runtime.drained())
	assert(items(98001).size()==2 and items(98000).any(func(row: Dictionary) -> bool: return row.uid==uid and row.amount==7))
	assert(not map.ground_loot.drops.has(uid) and not map.ground_loot.pending_claims.has(uid))
	assert((await claim(101,uid)).ok and items(98001).size()==2)
	# C2 natural equipment freezes six versioned affixes before pickup. Losing
	# completion must recover the same UID/effects instead of drawing again.
	var profile: Resource=preload("res://source/common/gameplay/loot/natural_affix_loot.gd").DEFAULT.duplicate(true)
	profile.bands.clear();profile.bands.append({"quality":"test","weight":1,"prefixes":3,"suffixes":3})
	var quality_rng:=RandomNumberGenerator.new();quality_rng.seed=74
	var generated: Dictionary=preload("res://source/common/gameplay/loot/natural_affix_loot.gd").resolve([{"definition_id":&"iron_sword","amount":1,"affixes":[]}],quality_rng,profile)
	assert(generated.ok and generated.items[0].affixes.size()==6)
	var frozen: Array=generated.items[0].affixes.duplicate(true)
	uid=map.ground_loot.spawn_resolved_item(Vector3.ZERO,98010,"fixture",Time.get_ticks_msec(),&"iron_sword",1,frozen)
	assert(not uid.is_empty())
	profile.pool.clear() # Future authoring changes cannot reinterpret a frozen drop.
	pools[1].lose_claim=true
	assert((await claim(200,uid)).error=="outcome_unknown")
	assert(world.ground_item_runtime.receipt(200,uid).queued)
	await wait_for(func()->bool:return world.ground_item_runtime.drained() and ready(200))
	var saved: Dictionary=items(98010).filter(func(i: Dictionary)->bool:return i.uid==uid)[0]
	assert(saved.affixes==frozen and not map.ground_loot.drops.has(uid),"lost completion retains all resolved affix metadata")
	assert((await claim(200,uid)).ok and (await claim(101,uid)).error=="claimed")
	assert(int(pg.query("SELECT COUNT(*) AS n FROM economy.item_instances WHERE uid=:uid;",{"uid":uid}).rows[0].n)==1)
	assert(int(pg.query("SELECT COUNT(*) AS n FROM economy.ground_item_claims WHERE drop_uid=:uid;",{"uid":uid}).rows[0].n)==1)
	# Real authored ordinary tables -> currency ground UID -> native PG pickup.
	var currency_rules=preload("res://source/common/gameplay/items/crafting/crafting_rules.gd")
	var currency_resolver:=KillRewardResolver.new();currency_resolver._region_key=&"first_region"
	var currency_death:=MobDeathResult.new();currency_death.mob_key=&"wild_dog";currency_death.category=&"beast";currency_death.spawn_base_loot_rolls=4
	var currency_rewards: Dictionary={}
	for source_seed: int in 20000:
		currency_resolver._rng.seed=source_seed;currency_resolver._affix_rng.seed=source_seed+20
		var currency_outcome: Dictionary=currency_resolver.resolve_ordinary(currency_death,0)
		assert(currency_outcome.ok and currency_outcome.attempts==4)
		for raw: Dictionary in currency_outcome.items:
			if currency_rules.CURRENCIES.has(str(raw.definition_id)): currency_rewards[raw.definition_id]=raw.duplicate(true)
		if currency_rewards.size()==currency_rules.CURRENCIES.size(): break
	assert(currency_rewards.size()==currency_rules.CURRENCIES.size())
	var currency_uids: Dictionary={}
	for raw: Dictionary in currency_rewards.values():
		assert(raw.amount==1 and raw.affixes.is_empty())
		var currency_uid: String=map.ground_loot.spawn_resolved_item(Vector3.ZERO,0,"",Time.get_ticks_msec(),StringName(raw.definition_id),raw.amount,raw.affixes)
		assert(not currency_uid.is_empty() and not currency_uids.has(currency_uid))
		map.ground_loot.drops[currency_uid].protected_until=Time.get_ticks_msec()
		if currency_uids.is_empty():
			assert(pg.begin() and pg.query("SELECT account_id FROM economy.accounts WHERE account_id=9801 FOR NO KEY UPDATE;").ok)
			pools[1].lose_claim=true
			assert(map.ground_loot.pickup_for_peer(200,currency_uid,Time.get_ticks_msec()).queued)
			assert((await claim(101,currency_uid)).error=="operation_pending")
			assert(pg.commit())
			await wait_for(func()->bool:return result(currency_uid).get("error","")=="outcome_unknown")
			assert(world.ground_item_runtime.receipt(200,currency_uid).queued)
			await wait_for(func()->bool:return world.ground_item_runtime.drained() and ready(200))
		else: assert((await claim(200,currency_uid)).ok)
		var currency_saved: Array=items(98010).filter(func(i: Dictionary)->bool:return i.uid==currency_uid)
		assert(currency_saved.size()==1 and currency_saved[0].definition_id==str(raw.definition_id) and currency_saved[0].amount==1 and currency_saved[0].affixes.is_empty())
		assert(ItemDefinitions.get_definition(StringName(raw.definition_id)).primary_action==ItemDefinition.PrimaryAction.USE)
		var prior_currency_facts: int=facts
		assert((await claim(200,currency_uid)).ok and facts==prior_currency_facts)
		assert((await claim(101,currency_uid)).error=="claimed")
		assert(int(pg.query("SELECT COUNT(*) AS n FROM economy.item_instances WHERE uid=:uid;",{"uid":currency_uid}).rows[0].n)==1)
		assert(int(pg.query("SELECT COUNT(*) AS n FROM economy.ground_item_claims WHERE drop_uid=:uid;",{"uid":currency_uid}).rows[0].n)==1)
		currency_uids[currency_uid]=true
	# Close the loot -> pickup -> crafting loop with an actually looted currency.
	# Replaying its ground receipt after consumption must not resurrect the UID.
	var looted_prism: Dictionary=items(98010).filter(func(i: Dictionary)->bool:return i.definition_id=="attunement_prism")[0]
	var craft_base: Dictionary=items(98010).filter(func(i: Dictionary)->bool:return i.uid==uid)[0]
	var craft=preload("res://source/server/world/database/postgres/crafting_store_postgres.gd").new(pg)
	craft.authorize_session(b,"")
	var crafted: Dictionary=craft.execute(98010,0,craft_base.uid,craft_base.revision,looted_prism.uid,looted_prism.revision,"looted-currency-craft")
	assert(crafted.ok and craft.committed and crafted.affixes.size()==craft_base.affixes.size())
	assert(world.inventory_runtime.invalidate_item_state(Items.new(pg).inventory(98010).item_state))
	await wait_for(func()->bool:return ready(200))
	assert(items(98010).filter(func(i: Dictionary)->bool:return i.uid==looted_prism.uid).is_empty())
	assert((await claim(200,looted_prism.uid)).ok and items(98010).filter(func(i: Dictionary)->bool:return i.uid==looted_prism.uid).is_empty())
	assert(craft.execute(98010,0,craft_base.uid,craft_base.revision,looted_prism.uid,looted_prism.revision,"looted-currency-craft")==crafted and craft.receipt_replay)
	assert(await world.flush_postgres_wallets(true))
	pools[0].begin_drain()
	await wait_for(func() -> bool: return pools.all(func(pool: RefCounted) -> bool: return pool.is_stopped()))
	map.free()
	world.free()
	WorldServer.curr=null
	pg.close()
	print("POSTGRES_GROUND_RUNTIME_OK idempotent starter hydration, ground authority, independent progress, atomic claim/COMMIT recovery, original issuer and drain")
	get_tree().quit()
