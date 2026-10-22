extends SceneTree
## Offline trusted-local-resource inspection. Never print credentials.
func _initialize() -> void:
	var args:=OS.get_cmdline_user_args()
	if args.size()!=2: quit(1);return
	var accounts: AccountResourceCollection=load(args[0])
	if accounts==null: quit(1);return
	var ids: Dictionary={}
	var seen: Dictionary={}
	for name: StringName in accounts.collection:
		var account: AccountResource=accounts.collection[name]
		if account==null or account.id<=0 or account.username!=str(name) or seen.has(account.id): quit(1);return
		ids[str(name)]=account.id;seen[account.id]=true
	if accounts.next_account_id<=int(seen.keys().max() if not seen.is_empty() else 0): quit(1);return
	var output:=FileAccess.open(args[1],FileAccess.WRITE)
	if output==null: quit(1);return
	output.store_string(JSON.stringify(ids));output.close();quit()
