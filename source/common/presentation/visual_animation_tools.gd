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
