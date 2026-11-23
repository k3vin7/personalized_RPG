extends SceneTree
## Gathers every clip of the one-handed sword pack into ONE AnimationLibrary
## file for the preview, on the pack's own bone names (no retarget, see
## setup_import.gd), and checks the clips fit the mannequin.
##
##   godot --headless --path . --script tools/sword_animset/build_library.gd
##
## Clip names are "<Folder>.<File>" with "_Anim" dropped, e.g.
## "RootPlace.Walk_F" (a library name may not hold "/").
##
## Checks printed:
##   - every track of every clip names a bone the mannequin has;
##   - POSE CHECK: a few clips posed halfway through, original FBX (read
##     before any import setting) against the imported clip on the
##     mannequin, angle of each limb bone. Near 0 = plays as shipped.
##   - SWORD: where the sword scene sits under the Weapon_R attachment so its
##     own bone (Bone_Sword, not at identity) lands on Weapon_R.

const PACK := "res://assets/characters_fbx/onehandedsword_asset/"
const OUT := PACK + "onehandedsword_library.res"
const FOLDERS := ["InPlace", "Montage", "RootPlace"]
const SKELETON := "Skeleton3D"
const RENAMES := {"Weapom_R": "Weapon_R"}


func _init() -> void:
	var mannequin := (load(PACK + "Armature.fbx") as PackedScene).instantiate()
	var skeleton := mannequin.get_node(SKELETON) as Skeleton3D
	print("mannequin: %d bones" % skeleton.get_bone_count())
	var library := AnimationLibrary.new()
	var problems := []
	for folder in FOLDERS:
		var files := Array(DirAccess.get_files_at(PACK + folder))
		files.sort()
		for file in files:
			if not file.to_lower().ends_with(".fbx"):
				continue
			var path: String = PACK + folder + "/" + file
			var packed := load(path) as PackedScene
			if packed == null:
				problems.append(path + ": did not load")
				continue
			var root := packed.instantiate()
			var players := root.find_children("*", "AnimationPlayer", true, false)
			if players.is_empty() or (players[0] as AnimationPlayer).get_animation_list().is_empty():
				problems.append(path + ": no clip")
				root.free()
				continue
			var player := players[0] as AnimationPlayer
			var animation := player.get_animation(player.get_animation_list()[0]).duplicate(true) as Animation
			# Bone names put right (Attack_Sprint's "Weapom_R"; the user's
			# call: the name only). The game's profile does the same on load.
			for track in animation.get_track_count():
				var track_path := animation.track_get_path(track)
				if track_path.get_subname_count() > 0 and RENAMES.has(String(track_path.get_subname(0))):
					animation.track_set_path(track, NodePath("%s:%s" % [track_path.get_concatenated_names(),
						RENAMES[String(track_path.get_subname(0))]]))
			var missing := PackedStringArray()
			for track in animation.get_track_count():
				var track_path := animation.track_get_path(track)
				if String(track_path.get_concatenated_names()) != SKELETON or track_path.get_subname_count() == 0:
					missing.append(String(track_path))
				elif skeleton.find_bone(String(track_path.get_subname(0))) < 0:
					missing.append(String(track_path))
			if not missing.is_empty():
				problems.append("%s: %d tracks the mannequin lacks %s" % [path, missing.size(), missing.slice(0, 4)])
			var clip := "%s.%s" % [folder, file.get_basename().trim_suffix("_Anim")]
			library.add_animation(StringName(clip), animation)
			root.free()
	var err := ResourceSaver.save(library, OUT)
	print("build_library: %d clips -> %s err=%d" % [library.get_animation_list().size(), OUT, err])
	for p in problems:
		print("  PROBLEM ", p)
	for file in ["InPlace/Idle_Anim.FBX", "RootPlace/Attack_Combo_01_01_Anim.FBX", "RootPlace/Walk_F_Anim.FBX",
			"Montage/Attack_Combo_02_Anim.FBX", "InPlace/Block_Hold_Anim.FBX"]:
		_pose_check(file, mannequin, skeleton)
	_print_sword()
	mannequin.free()
	quit(0 if err == OK else 1)


# ------------------------------------------------------------------ checks

func _raw_scene(path: String) -> Node:
	var doc := FBXDocument.new()
	var state := FBXState.new()
	state.handle_binary_image = GLTFState.HANDLE_BINARY_DISCARD_TEXTURES
	if doc.append_from_file(path, state) != OK:
		return null
	return doc.generate_scene(state)


# Place of a node against the root of its own scene, built from the local
# transforms (the scenes here are never added to the tree).
func _in_scene(node: Node, scene_root: Node) -> Transform3D:
	var out := Transform3D()
	while node != null and node != scene_root:
		if node is Node3D:
			out = (node as Node3D).transform * out
		node = node.get_parent()
	return out


# The original clip file (no import settings) posed at `time`: bone name ->
# place in the scene. Its bones are plain nodes here.
func _raw_posed(raw: Node, time: float) -> Dictionary:
	var animation: Animation = null
	for node in raw.find_children("*", "AnimationPlayer", true, false):
		var ap := node as AnimationPlayer
		animation = ap.get_animation(ap.get_animation_list()[0])
	var out := {}
	for node in raw.find_children("*", "Node3D", true, false):
		var chain: Array[Node3D] = []
		var at: Node = node
		while at != null and at != raw:
			if at is Node3D:
				chain.push_front(at as Node3D)
			at = at.get_parent()
		var place := Transform3D()
		for link in chain:
			var local := link.transform
			var path := NodePath(String(raw.get_path_to(link)))
			var r := animation.find_track(path, Animation.TYPE_ROTATION_3D)
			var p := animation.find_track(path, Animation.TYPE_POSITION_3D)
			var scale := local.basis.get_scale()
			if r >= 0:
				local.basis = Basis(animation.rotation_track_interpolate(r, time)).scaled(scale)
			if p >= 0:
				local.origin = animation.position_track_interpolate(p, time)
			place = place * local
		out[String(node.name)] = place
	return out


# The mannequin's skeleton posed by an imported clip at `time`.
func _skeleton_posed(skeleton: Skeleton3D, scene_root: Node, animation: Animation, time: float) -> Dictionary:
	var base := _in_scene(skeleton, scene_root)
	var places: Array[Transform3D] = []
	var out := {}
	for bone in skeleton.get_bone_count():
		var local := skeleton.get_bone_rest(bone)
		var path := NodePath("%s:%s" % [SKELETON, skeleton.get_bone_name(bone)])
		var r := animation.find_track(path, Animation.TYPE_ROTATION_3D)
		var p := animation.find_track(path, Animation.TYPE_POSITION_3D)
		var s := animation.find_track(path, Animation.TYPE_SCALE_3D)
		var scale := local.basis.get_scale()
		if s >= 0:
			scale = animation.scale_track_interpolate(s, time)
		if r >= 0:
			local.basis = Basis(animation.rotation_track_interpolate(r, time)).scaled(scale)
		if p >= 0:
			local.origin = animation.position_track_interpolate(p, time)
		var parent := skeleton.get_bone_parent(bone)
		places.append((base if parent < 0 else places[parent]) * local)
		out[skeleton.get_bone_name(bone)] = places[bone]
	return out


const LIMBS := [
	["upperarm_r", "lowerarm_r"], ["lowerarm_r", "hand_r"], ["upperarm_l", "lowerarm_l"], ["lowerarm_l", "hand_l"],
	["lowerarm_r", "lowerarm_twist_01_r"], ["hand_r", "Weapon_R"],
	["thigh_r", "calf_r"], ["calf_r", "foot_r"], ["thigh_l", "calf_l"], ["calf_l", "foot_l"], ["spine_01", "neck_01"],
]


func _pose_check(file: String, mannequin: Node, skeleton: Skeleton3D) -> void:
	var raw := _raw_scene(PACK + file)
	var imported := (load(PACK + file) as PackedScene).instantiate()
	var player := imported.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer
	var clip := player.get_animation(player.get_animation_list()[0])
	var half := clip.length * 0.5
	var original := _raw_posed(raw, half)
	var played := _skeleton_posed(skeleton, mannequin, clip, half)
	var worst := 0.0
	var parts := PackedStringArray()
	for limb in LIMBS:
		if not (original.has(limb[0]) and original.has(limb[1]) and played.has(limb[0]) and played.has(limb[1])):
			parts.append("%s ?" % limb[1])
			continue
		var a: Vector3 = (original[limb[1]] as Transform3D).origin - (original[limb[0]] as Transform3D).origin
		var b: Vector3 = (played[limb[1]] as Transform3D).origin - (played[limb[0]] as Transform3D).origin
		var angle := rad_to_deg(a.angle_to(b))
		worst = maxf(worst, angle)
		parts.append("%s %.1f" % [limb[1], angle])
	print("  POSE CHECK %s @%.2fs: worst %.1f deg %s  [%s]" % [file.get_file(), half, worst,
		"OK" if worst < 2.0 else "<-- DIFFERS", ", ".join(parts)])
	raw.free()
	imported.free()


func _print_sword() -> void:
	var sword := (load(PACK + "Weapon_Sword.FBX") as PackedScene).instantiate()
	for node in sword.find_children("*", "Skeleton3D", true, false):
		var sk := node as Skeleton3D
		var rest := _in_scene(sk, sword) * sk.get_bone_global_rest(0)
		print("  sword bone %s rest %s" % [sk.get_bone_name(0), rest])
		print("  SWORD (Weapon_R -> sword scene) = ", var_to_str(rest.affine_inverse()))
	sword.free()
