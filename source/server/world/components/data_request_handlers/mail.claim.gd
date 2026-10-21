extends DataRequestHandler
## Claims one mail's reward attachments for the requesting character. Reuses the
## redeem grant pipeline: validate → apply → mark claimed. The claimed guard
## (SQL-level) stops double-claims, including one-claim-per-player on broadcasts.
## Returns {"ok": true, "rewards": [...]} or {"ok": false, "reason": ...}.
## See docs/mailbox.md.


func data_request_handler(
	peer_id: int,
	instance: ServerInstance,
	args: Dictionary
) -> Dictionary:
	var pr: PlayerResource = instance.world_server.connected_players.get(peer_id, null)
	if pr == null:
		return {"ok": false, "reason": "no_player"}
	var mail_id: int = int(args.get("mail_id", 0))
	if mail_id <= 0:
		return {"ok": false, "reason": "missing"}

	var store: RefCounted = instance.world_server.database.mail_store
	if store is MailStorePostgres: return _claim_postgres(instance.world_server.database.store,store,pr,mail_id)
	var claimable: Dictionary = store.get_claimable(pr.player_id, mail_id)
	if not bool(claimable.get("ok", false)):
		return {"ok": false, "reason": str(claimable.get("reason", "missing"))}

	var attachments: Array = claimable.get("attachments", [])
	if not RedeemCodes.validate_grants(attachments):
		ServerLog.error("Mail #%d has invalid attachments; refusing to claim." % mail_id)
		return {"ok": false, "reason": "invalid"}

	var rewards: Array = RedeemCodes.apply_grants(pr, attachments)
	store.mark_claimed(pr.player_id, mail_id)
	ServerLog.info("Player #%d (%s) claimed mail #%d." % [pr.player_id, pr.display_name, mail_id])
	return {"ok": true, "rewards": rewards}

func _claim_postgres(profiles: RefCounted, mail: MailStorePostgres, player: PlayerResource, mail_id: int) -> Dictionary:
	var mutation:=RealmProfileMutation.new(profiles)
	if not mutation.started: return mutation.failure()
	if not mail.lock_claim(mail_id): return mutation.abort()
	var claimable: Dictionary=mail.get_claimable(player.player_id,mail_id)
	if not claimable.get("ok",false):
		mutation.abort();return claimable
	var attachments: Array=claimable.attachments
	if not RedeemCodes.validate_grants(attachments):
		mutation.abort();return {"ok":false,"reason":"invalid"}
	# Grant on a detached resource: level signals cannot escape before COMMIT.
	var staged: PlayerResource=player.duplicate(true)
	var rewards: Array=RedeemCodes.apply_grants(staged,attachments)
	if not mutation.save_player(staged) or not mail.mark_claimed(player.player_id,mail_id): return mutation.abort()
	if not mutation.commit(): return mutation.failure()
	var levels: int=staged.level-player.level
	RealmProfileMutation.accept(player,staged)
	for _level: int in levels: player.level_gained.emit()
	return {"ok":true,"rewards":rewards}
