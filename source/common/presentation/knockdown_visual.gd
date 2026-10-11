class_name KnockdownVisual
extends RefCounted
## Temporary fall/get-up pose for assets without those clips. Never moves the actor.
var phase: HitReaction.Phase = HitReaction.Phase.NONE
var _down: float = 0.0
var _up: float = 0.0
var _up_total: float = 0.4
var _active: bool = false
var _rotation: Vector3
var _fall_weight: float = 0.0
func active() -> bool:
	return _down > 0 or _up > 0
func rebind() -> void:
	_active = false
	phase = HitReaction.Phase.NONE
	if _down > 0: _fall_weight = 1.0
func sync(down: float, get_up: float) -> void:
	if not _active:
		_fall_weight = 0.0 if down > 0 else 1.0
	_down = maxf(0,down)
	_up = maxf(0,get_up)
	_up_total = maxf(0.4,maxf(_up_total,get_up))
func clear(content: Node3D) -> void:
	if _active and content != null: content.rotation = _rotation
	_down = 0
	_up = 0
	phase = HitReaction.Phase.NONE
	_active = false
func update(delta: float, content: Node3D, player: AnimationPlayer) -> bool:
	var overflow := maxf(0,delta-_down)
	_down = maxf(0,_down-delta)
	if _down <= 0: _up = maxf(0,_up-overflow)
	var next: HitReaction.Phase = HitReaction.Phase.DOWN if _down > 0 else (HitReaction.Phase.GETTING_UP if _up > 0 else HitReaction.Phase.NONE)
	if next == HitReaction.Phase.NONE:
		if _active: clear(content)
		return false
	if content == null: return true
	if not _active:
		_rotation = content.rotation
		_active = true
		if player != null: player.stop()
	if phase != next and player != null:
		var clip := &"knockdown" if next == HitReaction.Phase.DOWN else &"get_up"
		if player.has_animation(clip): player.play(clip,0.08)
	phase = next
	if phase == HitReaction.Phase.DOWN: _fall_weight = minf(1.0,_fall_weight+delta*8.0)
	var clip := &"knockdown" if phase == HitReaction.Phase.DOWN else &"get_up"
	if player == null or not player.has_animation(clip):
		content.rotation = _rotation + Vector3(0,0,PI*0.5*(_fall_weight if phase == HitReaction.Phase.DOWN else clampf(_up/_up_total,0,1)))
	return true
