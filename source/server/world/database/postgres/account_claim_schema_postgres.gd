extends RefCounted
## Explicit account claim custody; original character remains provenance.
const SettlementSchema = preload("res://source/server/world/database/postgres/shop_settlement_schema_postgres.gd")

static func ensure_schema(db: Object) -> bool:
	if not SettlementSchema.ensure_schema(db) or not db.begin(): return false
	var result: Dictionary=db.query("SELECT version FROM economy.schema_versions WHERE feature='account_claims';")
	if not result.ok or (not result.rows.is_empty() and int(result.rows[0].version)!=1):
		db.rollback()
		return false
	if result.rows.is_empty():
		for sql: String in [
			"ALTER TABLE economy.item_custody ADD COLUMN claim_account_id BIGINT REFERENCES economy.accounts(account_id);",
			"ALTER TABLE economy.item_custody ADD CONSTRAINT claim_provenance_account FOREIGN KEY(owner_id,claim_account_id) REFERENCES economy.characters(character_id,account_id) DEFERRABLE INITIALLY DEFERRED;",
			"ALTER TABLE economy.item_custody DROP CONSTRAINT item_custody_location_check, DROP CONSTRAINT item_custody_check;",
			"ALTER TABLE economy.item_custody ADD CONSTRAINT item_custody_location_check CHECK(location IN ('bag','equipment','account_storage','shop_escrow','account_claim')), ADD CONSTRAINT item_custody_check CHECK((location='bag' AND position BETWEEN 0 AND 179 AND equipment_slot='' AND storage_account_id IS NULL AND escrow_account_id IS NULL AND shop_id IS NULL AND offer_id IS NULL AND claim_account_id IS NULL) OR (location='equipment' AND position=-1 AND equipment_slot<>'' AND storage_account_id IS NULL AND escrow_account_id IS NULL AND shop_id IS NULL AND offer_id IS NULL AND claim_account_id IS NULL) OR (location='account_storage' AND position BETWEEN 0 AND 269 AND equipment_slot='' AND storage_account_id IS NOT NULL AND escrow_account_id IS NULL AND shop_id IS NULL AND offer_id IS NULL AND claim_account_id IS NULL) OR (location='shop_escrow' AND position BETWEEN 0 AND 39 AND equipment_slot='' AND storage_account_id IS NULL AND escrow_account_id IS NOT NULL AND shop_id IS NOT NULL AND offer_id IS NOT NULL AND claim_account_id IS NULL) OR (location='account_claim' AND position=-1 AND equipment_slot='' AND storage_account_id IS NULL AND escrow_account_id IS NULL AND shop_id IS NULL AND offer_id IS NULL AND claim_account_id IS NOT NULL));",
			"CREATE INDEX custody_claim_account_uid ON economy.item_custody(claim_account_id,uid) WHERE location='account_claim';",
			"CREATE INDEX shop_offers_shop_position ON economy.shop_offers(shop_id,position);",
			"INSERT INTO economy.schema_versions(feature,version) VALUES('account_claims',1);"
		]:
			if not db.execute(sql).ok:
				db.rollback()
				return false
	if db.commit(): return true
	db.close()
	return false
