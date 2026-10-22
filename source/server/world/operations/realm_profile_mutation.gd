extends RefCounted
class_name RealmProfileMutation
## Short synchronous legacy profile use cases. No retry, queue or publication.
## Preserve live Resource identities on rollback, including dirty references.
var store: RefCounted
var started:=false
var _before: Array=[]

func _init(owner: RefCounted, resources: Array=[]) -> void:
	store=owner
	for resource: Resource in resources:
		if resource==null: continue
		_before.append([resource,resource.duplicate(true)])
	started=store.begin()

static func accept(target: Resource, source: Resource) -> void:
	for property: Dictionary in source.get_property_list():
		if int(property.usage)&PROPERTY_USAGE_SCRIPT_VARIABLE and int(property.usage)&PROPERTY_USAGE_STORAGE:
			target.set(property.name,source.get(property.name))

func _restore() -> void:
	for pair: Array in _before: accept(pair[0],pair[1])
	_before.clear()

func abort() -> Dictionary:
	if started: store.rollback()
	started=false
	_restore()
	return failure()

func commit() -> bool:
	if not started: return false
	started=false
	if not store.commit():
		_restore()
		return false
	_before.clear()
	return true

func failure() -> Dictionary:
	var reason: String=store.last_write_error if store is WorldStorePostgres else "storage"
	return {"ok":false,"error":1,"reason":reason,"message":"Persistent state could not be confirmed.","retryable":reason!="outcome_unknown"}

func save_player(player: PlayerResource) -> bool:
	return started and store.save_player(player)

func save_guild(guild: Guild) -> bool:
	return started and store.save_guild(guild)
