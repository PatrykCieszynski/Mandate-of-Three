class_name MarketRejectedCommands
extends RefCounted
## Bounded, short-lived negative responses only. Successful receipts stay in SQLite.
## WorldDatabase shares one instance between all shops/Exchange instances.
const MAX_ACCOUNTS := 64
const MAX_PER_ACCOUNT := 64
const TTL_MS := 60000
var _accounts: Dictionary[int, Dictionary] = {}

func remember(account: int, command: String, kind: String, request: String, result: Dictionary, now_ms: int = Time.get_ticks_msec()) -> void:
	if not _accounts.has(account):
		if _accounts.size()>=MAX_ACCOUNTS: _accounts.erase(_accounts.keys()[0])
		_accounts[account]={}
	var entries: Dictionary=_accounts[account]
	if not entries.has(command) and entries.size()>=MAX_PER_ACCOUNT: entries.erase(entries.keys()[0])
	entries[command]={"kind":kind,"request":request,"result":result.duplicate(true),"expires":now_ms+TTL_MS}

func lookup(account: int, command: String, kind: String, request: String, now_ms: int = Time.get_ticks_msec()) -> Dictionary:
	var entry:=_entry(account,command,now_ms)
	if entry.is_empty(): return {}
	if entry.kind!=kind or entry.request!=request: return {"ok":false,"error":"command_conflict"}
	return entry.result.duplicate(true)

func receipt(account: int, command: String, now_ms: int = Time.get_ticks_msec()) -> Dictionary:
	var entry:=_entry(account,command,now_ms)
	return {} if entry.is_empty() else entry.result.duplicate(true)

func _entry(account: int, command: String, now_ms: int) -> Dictionary:
	var entries: Dictionary=_accounts.get(account,{})
	var entry: Dictionary=entries.get(command,{})
	if not entry.is_empty() and now_ms>=int(entry.expires):
		entries.erase(command)
		if entries.is_empty(): _accounts.erase(account)
		return {}
	return entry

func size(account: int = 0) -> int:
	if account>0: return _accounts.get(account,{}).size()
	var count:=0
	for entries: Dictionary in _accounts.values(): count+=entries.size()
	return count
