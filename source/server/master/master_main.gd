extends Node


func _ready() -> void:
	get_tree().auto_accept_quit=false
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_title("Master Server")


## Best-effort "offline" ping. WM_CLOSE_REQUEST fires on a graceful window
## close; headless / kill -9 won't trigger it. The HTTPRequest is async, so
## we await briefly before letting the process exit.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_WM_GO_BACK_REQUEST:
		get_tree().auto_accept_quit=false
		var owner: RefCounted=$WorldManagerServer.economy_bootstrap
		if owner!=null and not $WorldManagerServer.connected_worlds.is_empty() and ($WorldManagerServer.maintenance==null or $WorldManagerServer.maintenance.phase!="QUIESCED"):
			push_error("Master shutdown refused: quiesce the PG realm first.");return
		if owner!=null and not await owner.shutdown_master():
			push_error("Master shutdown refused: unresolved PostgreSQL grants");return
		DiscordNotifier.notify_master_offline()
		await get_tree().create_timer(0.5).timeout
		get_tree().quit()
