class_name VisualAnimationTools
extends RefCounted

static func prepare_in_place(animation_player: AnimationPlayer, looping_clips: Array[StringName]) -> void:
	# Copies prevent mutation of cached resources and other instances' clips.
	for library_name: StringName in animation_player.get_animation_library_list():
		var source_library := animation_player.get_animation_library(library_name)
		var library := AnimationLibrary.new()
		for clip_name: StringName in source_library.get_animation_list():
			var clip := source_library.get_animation(clip_name).duplicate() as Animation
			clip.loop_mode = Animation.LOOP_LINEAR if looping_clips.has(clip_name) else Animation.LOOP_NONE
			# Preserve vertical bob and rotation; remove planar root displacement.
			for track: int in clip.get_track_count():
				if clip.track_get_type(track) != Animation.TYPE_POSITION_3D: continue
				var path := clip.track_get_path(track)
				var target := animation_player.get_node(animation_player.root_node).get_node_or_null(NodePath(path.get_concatenated_names()))
				if not target is Skeleton3D or path.get_subname_count() == 0: continue
				var skeleton := target as Skeleton3D
				var bone := skeleton.find_bone(path.get_subname(0))
				if bone < 0 or skeleton.get_bone_parent(bone) != -1: continue
				if clip.track_get_key_count(track) == 0: continue
				var origin: Vector3 = clip.track_get_key_value(track, 0)
				for key: int in clip.track_get_key_count(track):
					var position: Vector3 = clip.track_get_key_value(track, key)
					position.x = origin.x
					position.z = origin.z
					clip.track_set_key_value(track, key, position)
			library.add_animation(clip_name, clip)
		animation_player.remove_animation_library(library_name)
		animation_player.add_animation_library(library_name, library)

static func align_locomotion_heading(animation_player: AnimationPlayer, clips: Array[StringName], reference_clip: StringName) -> void:
	# In-place clips must agree on facing. Keep each clip's tilt and motion,
	# but remove its constant authored heading relative to the running pose.
	if not animation_player.has_animation(reference_clip): return
	var reference := animation_player.get_animation(reference_clip)
	for clip_name: StringName in clips:
		if not animation_player.has_animation(clip_name): continue
		var clip := animation_player.get_animation(clip_name)
		for track: int in clip.get_track_count():
			if clip.track_get_type(track) != Animation.TYPE_ROTATION_3D or clip.track_get_key_count(track) == 0: continue
			var path := clip.track_get_path(track)
			var target := animation_player.get_node(animation_player.root_node).get_node_or_null(NodePath(path.get_concatenated_names()))
			if not target is Skeleton3D or path.get_subname_count() == 0: continue
			var skeleton := target as Skeleton3D
			var bone := skeleton.find_bone(path.get_subname(0))
			if bone < 0 or skeleton.get_bone_parent(bone) != -1: continue
			var reference_track := reference.find_track(path, Animation.TYPE_ROTATION_3D)
			if reference_track < 0 or reference.track_get_key_count(reference_track) == 0: continue
			var reference_rotation: Quaternion = reference.track_get_key_value(reference_track, 0)
			var initial_rotation: Quaternion = clip.track_get_key_value(track, 0)
			var reference_right := Basis(reference_rotation).x
			var initial_right := Basis(initial_rotation).x
			var correction := Quaternion(Vector3.UP, atan2(-reference_right.z, reference_right.x) - atan2(-initial_right.z, initial_right.x))
			for key: int in clip.track_get_key_count(track):
				var rotation: Quaternion = clip.track_get_key_value(track, key)
				clip.track_set_key_value(track, key, (correction * rotation).normalized())
