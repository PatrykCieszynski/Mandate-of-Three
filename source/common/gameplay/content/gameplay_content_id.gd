class_name GameplayContentId
extends RefCounted
static func valid(value: StringName) -> bool:
	var regex := RegEx.new()
	regex.compile("^[a-z][a-z0-9_]{0,63}$")
	return regex.search(str(value)) != null
