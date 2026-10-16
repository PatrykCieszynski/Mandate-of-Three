extends RefCounted
## P1c: character Inventory custody and NPC purchase receipts only. No placeholder
## Storage/Shop escrow destinations: those require their own explicit migration.
const WalletSchema = preload("res://source/server/world/database/postgres/wallet_schema_postgres.gd")

static func ensure_schema(db: Object) -> bool:
	if not WalletSchema.ensure_schema(db) or not db.begin(): return false
	var result: Dictionary = db.query("SELECT version FROM economy.schema_versions WHERE feature='npc_shop';")
	if not result.ok or (not result.rows.is_empty() and int(result.rows[0].version)!=1):
		db.rollback()
		return false
	if not result.rows.is_empty():
		if db.commit(): return true
		db.close()
		return false
	var statements: Array[String] = [
		"CREATE TABLE economy.characters (character_id BIGINT PRIMARY KEY CHECK(character_id>0),account_id BIGINT NOT NULL REFERENCES economy.accounts(account_id));",
		"CREATE TABLE economy.account_item_revisions (account_id BIGINT PRIMARY KEY REFERENCES economy.accounts(account_id),revision BIGINT NOT NULL CHECK(revision>=0));",
		"CREATE TABLE economy.item_instances (uid TEXT PRIMARY KEY CHECK(uid ~ '^[0-9a-f]{32}$'),owner_character_id BIGINT NOT NULL REFERENCES economy.characters(character_id),definition_id TEXT NOT NULL,amount BIGINT NOT NULL CHECK(amount>0),upgrade_level BIGINT NOT NULL DEFAULT 0 CHECK(upgrade_level BETWEEN 0 AND 9),affixes_json TEXT NOT NULL CHECK(jsonb_typeof(affixes_json::jsonb)='array'),sockets_json TEXT NOT NULL CHECK(jsonb_typeof(sockets_json::jsonb)='array'),revision BIGINT NOT NULL DEFAULT 0 CHECK(revision>=0),UNIQUE(uid,owner_character_id));",
		"CREATE TABLE economy.item_custody (uid TEXT PRIMARY KEY,location TEXT NOT NULL CHECK(location IN ('bag','equipment')),owner_id BIGINT NOT NULL,position BIGINT NOT NULL,equipment_slot TEXT NOT NULL DEFAULT '',FOREIGN KEY(uid,owner_id) REFERENCES economy.item_instances(uid,owner_character_id) DEFERRABLE INITIALLY DEFERRED,CHECK((location='bag' AND position BETWEEN 0 AND 179 AND equipment_slot='') OR (location='equipment' AND position=-1 AND equipment_slot<>'')));",
		"ALTER TABLE economy.item_instances ADD CONSTRAINT item_has_custody FOREIGN KEY(uid) REFERENCES economy.item_custody(uid) DEFERRABLE INITIALLY DEFERRED;",
		"CREATE UNIQUE INDEX item_bag_position ON economy.item_custody(owner_id,position) WHERE location='bag';",
		"CREATE UNIQUE INDEX item_equipment_slot ON economy.item_custody(owner_id,equipment_slot) WHERE location='equipment';",
		"CREATE INDEX item_owner ON economy.item_instances(owner_character_id);",
		"""CREATE FUNCTION economy.advance_item_revision() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE old_character BIGINT; new_character BIGINT;
BEGIN
 IF TG_OP='UPDATE' AND OLD IS NOT DISTINCT FROM NEW THEN RETURN NULL; END IF;
 IF TG_TABLE_NAME='item_instances' THEN
  IF TG_OP<>'INSERT' THEN old_character:=OLD.owner_character_id; END IF;
  IF TG_OP<>'DELETE' THEN new_character:=NEW.owner_character_id; END IF;
 ELSE
  IF TG_OP<>'INSERT' THEN old_character:=OLD.owner_id; END IF;
  IF TG_OP<>'DELETE' THEN new_character:=NEW.owner_id; END IF;
 END IF;
 INSERT INTO economy.account_item_revisions(account_id,revision)
 SELECT DISTINCT account_id,1 FROM economy.characters WHERE character_id IN (old_character,new_character)
 ON CONFLICT(account_id) DO UPDATE SET revision=economy.account_item_revisions.revision+1;
 RETURN NULL;
END; $$;""",
		"CREATE TRIGGER item_revision_instances AFTER INSERT OR UPDATE OR DELETE ON economy.item_instances FOR EACH ROW EXECUTE FUNCTION economy.advance_item_revision();",
		"CREATE TRIGGER item_revision_custody AFTER INSERT OR UPDATE OR DELETE ON economy.item_custody FOR EACH ROW EXECUTE FUNCTION economy.advance_item_revision();",
		"CREATE TABLE economy.market_commands (account_id BIGINT NOT NULL REFERENCES economy.accounts(account_id),command_id TEXT NOT NULL CHECK(length(command_id) BETWEEN 1 AND 96),character_id BIGINT NOT NULL REFERENCES economy.characters(character_id),kind TEXT NOT NULL,request_json TEXT NOT NULL CHECK(jsonb_typeof(request_json::jsonb)='array'),result_json TEXT NOT NULL CHECK(jsonb_typeof(result_json::jsonb)='object'),PRIMARY KEY(account_id,command_id));",
		"INSERT INTO economy.schema_versions(feature,version) VALUES('npc_shop',1);"
	]
	for sql: String in statements:
		if not db.execute(sql).ok:
			db.rollback()
			return false
	if db.commit(): return true
	db.close()
	return false
