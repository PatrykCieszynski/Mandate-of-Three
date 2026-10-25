extends RefCounted
## Shared legal 10k-offer fixture for SQL and live-World measurements.
static func seed(db: SqliteSoci, owner: int, distributed_owners: bool = false) -> void:
	# 500 account shops x 20 two-cell swords, inserted atomically in fixture batches.
	# Historical SQL parity cases retain one legacy character owner. Live D2
	# distributes it as well as canonical custody; otherwise refreshing the hero's
	# inventory scans a pathological 10k-item legacy ownership bucket.
	var owners: Dictionary={}
	if distributed_owners:
		var store:=WorldStoreSqlite.new(db)
		for shop: int in 500:
			var name:="catalog%d" % shop
			assert(store.bind_account_identity(name,2000+shop,true))
			owners[2000+shop]=store.create_player_character(name,{"name":"Catalog%d" % shop,"skin":1})
			assert(int(owners[2000+shop])>0)
	assert(db.query("BEGIN IMMEDIATE;"))
	for shop: int in 500:
		var account:=2000+shop
		if not distributed_owners: assert(db.query_with_bindings("INSERT INTO accounts(account_name,master_account_id) VALUES(?,?);",["catalog%d" % shop,account]))
		assert(db.query_with_bindings("INSERT INTO account_shops(shop_id,account_id) VALUES(?,?);",[shop+1,account]))
		var instances: Array[String]=[];var custody: Array[String]=[];var offers: Array[String]=[];var cells: Array[String]=[]
		for slot: int in 20:
			var n:=shop*20+slot
			var uid:="%032x" % (n+1);var offer:="%032x" % (n+20000)
			var level:=int(n/10)%10
			var rolls:=JSON.stringify([{"stat":"monster_damage","value":15 if n%3==0 else 5},{"stat":"critical_chance","value":7 if n%5==0 else 2}])
			var definition:="iron_sword"
			var position:=slot
			instances.append("('%s',%d,'%s',1,%d,'%s','[]',0,'rare')" % [uid,int(owners.get(account,owner)),definition,level,rolls])
			custody.append("('%s','shop_escrow',%d,%d,'',%d,'%s')" % [uid,account,position,shop+1,offer])
			offers.append("('%s',%d,%d,'%s',%d,%d,0)" % [offer,shop+1,account,uid,position,n+1])
			cells.append("(%d,%d,'%s'),(%d,%d,'%s')" % [shop+1,position,uid,shop+1,position+20,uid])
		assert(db.query("INSERT INTO item_instances VALUES "+",".join(instances)+";"))
		assert(db.query("INSERT INTO item_custody VALUES "+",".join(custody)+";"))
		assert(db.query("INSERT INTO shop_offers(offer_id,shop_id,account_id,item_uid,position,price_yang,revision) VALUES "+",".join(offers)+";"))
		assert(db.query("INSERT INTO shop_cells VALUES "+",".join(cells)+";"))
	assert(db.query("COMMIT;"))
