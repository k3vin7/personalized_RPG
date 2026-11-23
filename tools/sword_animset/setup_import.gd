extends SceneTree
## Sets the import of every FBX in the one-handed sword pack (the mannequin
## and all clips; not the sword) so the clips play on the pack's own mannequin
## exactly as shipped -- NO retarget:
##   - every node of the skeleton comes in as a bone (the clips carry no mesh,
##     so without this their bones arrive as plain Node3Ds and their track
##     paths would not match the mannequin's Skeleton3D). All bones are kept:
##     root, twist, IK, Weapon_R.
##   - no bone map / rest fixer: the per-skeleton retarget entry is removed.
##   - every track is kept (the mannequin file and the clips were saved in
##     different rest poses, so a dropped "unchanging" track would leave that
##     bone in the mannequin's rest instead of the clip's pose).
##   - no trimming, and the clips are read at the files' own 60 fps.
## Then `godot --headless --import`.
##
##   godot --headless --path . --script tools/sword_animset/setup_import.gd
##
## assets/retarget/ue_mannequin_bone_map.tres (make_bone_map.gd) is kept for
## the later retarget onto our own character and is not wired anywhere.

const PACK := "res://assets/characters_fbx/onehandedsword_asset/"
const FOLDERS := ["", "InPlace/", "Montage/", "RootPlace/"]
const SKIP := ["weapon_sword.fbx"]
# The clips' own frame rate, read from the FBX GlobalSettings (TimeMode 60).
const FPS := 60


func _init() -> void:
	var done := 0
	for folder in FOLDERS:
		for file in DirAccess.get_files_at(PACK + folder):
			if not file.to_lower().ends_with(".fbx.import"):
				continue
			if SKIP.has(file.to_lower().trim_suffix(".import")):
				continue
			var path: String = PACK + folder + file
			var cfg := ConfigFile.new()
			if cfg.load(path) != OK:
				push_error("setup_import: cannot read " + path)
				continue
			cfg.set_value("params", "nodes/import_as_skeleton_bones", true)
			cfg.set_value("params", "animation/remove_immutable_tracks", false)
			cfg.set_value("params", "animation/trimming", false)
			cfg.set_value("params", "animation/fps", FPS)
			var sub: Dictionary = cfg.get_value("params", "_subresources", {})
			var nodes: Dictionary = sub.get("nodes", {})
			nodes.erase("PATH:Skeleton3D")
			if nodes.is_empty():
				sub.erase("nodes")
			else:
				sub["nodes"] = nodes
			cfg.set_value("params", "_subresources", sub)
			cfg.save(path)
			done += 1
	print("setup_import: ", done, " files")
	quit()
