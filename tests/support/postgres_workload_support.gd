extends RefCounted
## Shared test-only probes and invariant audits. Scenario policies live in separate cases.
const ShopCells = preload("res://source/common/gameplay/items/domain/shop_grid.gd")

class Histogram extends RefCounted:
	var buckets: Dictionary={}
	var count:=0
	var maximum:=0
	var total:=0
	var ceiling_us: int
	func _init(maximum_us: int = 10000000) -> void: ceiling_us=maximum_us
	func add(us: int) -> void:
		us=maxi(us,0);count+=1;total+=us;maximum=maxi(maximum,us)
		var bucket:=ceili(us/100.0)
		if ceiling_us>0: bucket=mini(ceili(ceiling_us/100.0),bucket)
		buckets[bucket]=int(buckets.get(bucket,0))+1
	func summary() -> Dictionary:
		var result: Dictionary={"samples":count,"max_ms":maximum/1000.0,"mean_ms":total/float(maxi(count,1))/1000.0,"bucket_ms":0.1}
		var keys:=buckets.keys();keys.sort()
		for p: int in [50,95,99]:
			var cumulative:=0
			result["p%d_ms" % p]=0.0
			for key: int in keys:
				cumulative+=int(buckets[key])
				if cumulative>=ceili(count*p/100.0): result["p%d_ms" % p]=key/10.0;break
		return result

class SimWorld extends WorldServer:
	var observe_poll: Callable
	func inventory_master_available() -> bool: return true # Fixture grants only.
	func _process(delta: float) -> void:
		var started:=Time.get_ticks_usec()
		super._process(delta)
		if observe_poll.is_valid(): observe_poll.call(Time.get_ticks_usec()-started)
class NoWireCombat extends CombatEndpoint3D:
	func _ground_finished(_peer: int, _ground: RefCounted, _uid: String, _result: Dictionary) -> void: pass
	func _ground_committed(_peer: int, _ground: RefCounted) -> void: pass
	func _send_snapshot() -> void: pass # No synthetic peers passed to RPC transport.
class SimMap extends GameWorld3D:
	var extra_mobs:=32
	func _ready() -> void:
		_server=true;input_enabled=false;_build_arena()
		ground_loot.setup(self,services)
		combat_endpoint=NoWireCombat.new();combat_endpoint.services=services
		mob_system.setup(self,combat_endpoint,services);add_child(combat_endpoint)
		if extra_mobs>0:
			var entry:=MobSpawnEntry.new();entry.mob=MobDefinitions.resolve(&"wild_dog");entry.count=extra_mobs
			mob_system.create_pack([entry],Vector3(-7,0,-7),3,6,12,0)
		for mob: MobActor3D in mob_system.mobs.values(): mob.proximity_aggro=false
	func _broadcast_snapshot() -> void: pass
class Tail extends Node:
	var record: Callable
	func _physics_process(_delta: float) -> void: record.call()


static func item_rows(pg: Object, custody: bool = false) -> Array:
	var rows: Array=[];var after: String=""
	while true:
		var sql: String="SELECT c.*,i.definition_id FROM economy.item_custody c JOIN economy.item_instances i USING(uid) WHERE i.uid>:after ORDER BY i.uid LIMIT 1024;" if custody else "SELECT uid FROM economy.item_instances WHERE uid>:after ORDER BY uid LIMIT 1024;"
		var page: Dictionary=pg.query(sql,{"after":after},1024)
		assert(page.ok and not page.truncated)
		rows.append_array(page.rows)
		if page.rows.size()<1024: return rows
		after=page.rows.back().uid
	return rows

static func audit_economy(pg: Object, expected_uids: Array, expected_money: int, expected_material: int, successful_ids: Dictionary, prefix: String, directory: String) -> Dictionary:
	assert(pg.query("SELECT count(*) AS n FROM economy.item_instances i LEFT JOIN economy.item_custody c USING(uid) WHERE c.uid IS NULL;").rows[0].n==0)
	assert(pg.query("SELECT count(*) AS n FROM economy.item_instances;").rows[0].n==expected_uids.size())
	assert(item_rows(pg).map(func(row: Dictionary)->String:return row.uid)==expected_uids)
	assert(pg.query("SELECT coalesce(sum(yang),0)::bigint AS n FROM (SELECT yang FROM economy.account_wallets UNION ALL SELECT yang FROM economy.account_shop_revenue) t;").rows[0].n==expected_money)
	assert(pg.query("SELECT count(*) AS n FROM economy.account_wallets w WHERE reserved_yang<>coalesce((SELECT sum(reserved_amount) FROM economy.exchange_orders o WHERE o.account_id=w.account_id AND o.side='buy' AND o.status='active'),0);").rows[0].n==0)
	assert(pg.query("SELECT count(*) AS n FROM economy.exchange_assets a WHERE reserved<>coalesce((SELECT sum(reserved_amount) FROM economy.exchange_orders o WHERE o.account_id=a.account_id AND o.base_asset=a.asset_id AND o.side='sell' AND o.status='active'),0);").rows[0].n==0)
	assert(pg.query("SELECT coalesce(sum(free+reserved),0)::bigint AS n FROM economy.exchange_assets;").rows[0].n==expected_material)
	assert(pg.query("SELECT count(*) AS n FROM economy.shop_cells c LEFT JOIN economy.shop_offers o ON c.item_uid=o.item_uid WHERE o.offer_id IS NULL;").rows[0].n==0)
	var occupied: Dictionary={}
	var rows: Array=item_rows(pg,true)
	for row: Dictionary in rows:
		var definition: ItemDefinition=ItemDefinitions.get_definition(StringName(row.definition_id))
		assert(definition!=null and row.location in ["bag","shop_escrow"])
		var cells: Array[int]=InventoryGrid.cells(int(row.position),definition.inventory_height) if row.location=="bag" else ShopCells.cells(int(row.position),definition.inventory_height)
		assert(not cells.is_empty())
		for cell: int in cells:
			var key: String=row.location+":"+str(row.owner_id if row.location=="bag" else row.shop_id)+":"+str(cell)
			assert(not occupied.has(key),"full item footprint overlap")
			occupied[key]=true
	var successful:=successful_ids.size()
	var durable: Dictionary=pg.query("SELECT coalesce(json_agg(command_id),'[]'::json)::text AS ids FROM economy.market_commands WHERE command_id LIKE :prefix AND result_json::jsonb->>'ok'='true';",{"prefix":prefix+"%"})
	assert(durable.ok and not durable.truncated)
	var ids: Array=JSON.parse_string(durable.rows[0].ids)
	var durable_set: Dictionary={}
	for id: String in ids: durable_set[id]=true
	var missing: Array=[];var extra: Array=[]
	for id: String in successful_ids:
		if not durable_set.has(id): missing.append({"id":id,"action":successful_ids[id]})
	for id: String in durable_set:
		if not successful_ids.has(id): extra.append(id)
	var receipt_audit: Dictionary={"expected":successful,"observed_ids":successful_ids.size(),"durable":ids.size(),"missing":missing.slice(0,20),"extra":extra.slice(0,20)}
	FileAccess.open(directory+"/receipt-audit.json",FileAccess.WRITE).store_string(JSON.stringify(receipt_audit,"  "))
	assert(ids.size()==successful and missing.is_empty() and extra.is_empty(),"successful stable IDs correspond to durable receipts exactly once: "+str(receipt_audit))
	return {"ok":true,"successful_receipts":ids.size(),"items":expected_uids.size(),"money":expected_money,"material":expected_material}
