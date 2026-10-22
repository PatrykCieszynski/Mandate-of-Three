extends RefCounted
## Durable rolled-affix projection. Never parse item JSON in a search query.
const ClaimsSchema = preload("res://source/server/world/database/postgres/account_claim_schema_postgres.gd")

static func ensure_schema(db: Object) -> bool:
	if not ClaimsSchema.ensure_schema(db) or not db.begin(): return false
	var result: Dictionary=db.query("SELECT version FROM economy.schema_versions WHERE feature='auction_search';")
	if not result.ok or (not result.rows.is_empty() and int(result.rows[0].version)!=1):
		db.rollback()
		return false
	if result.rows.is_empty():
		for sql: String in [
			"CREATE TABLE economy.item_affix_index(uid TEXT NOT NULL REFERENCES economy.item_instances(uid) ON DELETE CASCADE,ordinal BIGINT NOT NULL CHECK(ordinal>=0),stat_id TEXT NOT NULL,value DOUBLE PRECISION NOT NULL CHECK(value>'-Infinity'::double precision AND value<'Infinity'::double precision),PRIMARY KEY(uid,ordinal));",
			"CREATE INDEX affix_search ON economy.item_affix_index(stat_id,value,uid);",
			"CREATE INDEX affix_item_lookup ON economy.item_affix_index(uid,stat_id,value);",
			"CREATE INDEX market_item_search ON economy.item_instances(definition_id,upgrade_level,uid);",
			"CREATE INDEX market_price_search ON economy.shop_offers(price_yang,offer_id COLLATE \"C\");",
			"INSERT INTO economy.item_affix_index SELECT i.uid,j.ordinality-1,CASE WHEN jsonb_typeof(j.value->'stat')='string' THEN j.value->>'stat' END,CASE WHEN jsonb_typeof(j.value->'value')='number' THEN (j.value->>'value')::double precision END FROM economy.item_instances i CROSS JOIN LATERAL jsonb_array_elements(i.affixes_json::jsonb) WITH ORDINALITY AS j(value,ordinality);",
			"""CREATE FUNCTION economy.refresh_item_affixes() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='UPDATE' AND OLD.affixes_json IS NOT DISTINCT FROM NEW.affixes_json THEN RETURN NULL; END IF;
 DELETE FROM economy.item_affix_index WHERE uid=NEW.uid;
 INSERT INTO economy.item_affix_index
 SELECT NEW.uid,j.ordinality-1,CASE WHEN jsonb_typeof(j.value->'stat')='string' THEN j.value->>'stat' END,CASE WHEN jsonb_typeof(j.value->'value')='number' THEN (j.value->>'value')::double precision END
 FROM jsonb_array_elements(NEW.affixes_json::jsonb) WITH ORDINALITY AS j(value,ordinality);
 RETURN NULL;
END; $$;""",
			"CREATE TRIGGER item_affix_refresh AFTER INSERT OR UPDATE OF affixes_json ON economy.item_instances FOR EACH ROW EXECUTE FUNCTION economy.refresh_item_affixes();",
			"INSERT INTO economy.schema_versions(feature,version) VALUES('auction_search',1);"
		]:
			if not db.execute(sql).ok:
				db.rollback()
				return false
	if db.commit(): return true
	db.close()
	return false
