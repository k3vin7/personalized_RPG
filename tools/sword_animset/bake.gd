extends Node
## 2026-11-21: writes each sword skill's motion (SkillDef "Motion") off the
## clip the mannequin plays for it: windup, swing, recovery and the root
## bone's path and turn (CharacterVisual.baked_motion). Run as a scene, so
## the autoloads the visual reads are there:
##
##   godot --headless --path . res://tools/sword_animset/bake.tscn
##
## Run again after a skill's clip changes in the mannequin profile
## ("armed_by" / "library_clips"). Prints PLAYGROUND_MOTION_BAKE per skill.

const PROFILE := "mannequin"
const FAMILY := "sword"


func _ready() -> void:
	CharacterVisual.use_profile(PROFILE)
	var visual := CharacterVisual.new()
	add_child(visual)
	visual.setup_preview()
	var armed: Dictionary = CharacterVisual.PROFILES[PROFILE].get("armed_by", {}).get(FAMILY, {})
	var written := 0
	for skill_id in armed:
		var clip := String(armed[skill_id])
		var motion := CharacterVisual.baked_motion(clip)
		var path := "res://data/skills/%s.tres" % skill_id
		if motion.is_empty() or not ResourceLoader.exists(path):
			print("PLAYGROUND_MOTION_BAKE skill=%s clip=%s skipped (not a timed clip)" % [skill_id, clip])
			continue
		var def := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as SkillDef
		def.motion_clip = clip
		def.motion_windup = float(motion["windup"])
		def.motion_swing = float(motion["swing"])
		def.motion_recovery = float(motion["recovery"])
		def.motion_times = motion["times"]
		def.motion_path = motion["path"]
		def.motion_yaw = motion["yaw"]
		def.motion_return_foot = String(motion.get("return_foot", ""))
		def.motion_return_move = motion.get("return_move", Vector3.ZERO)
		var err := ResourceSaver.save(def, path)
		var points: PackedVector3Array = motion["path"]
		var lowest := 0.0
		var highest := 0.0
		var back := 0.0
		for point in points:
			lowest = minf(lowest, point.y)
			highest = maxf(highest, point.y)
			back = minf(back, point.z)
		var turns: PackedFloat32Array = motion["yaw"]
		var turn_most := 0.0
		for turn in turns:
			turn_most = turn if absf(turn) > absf(turn_most) else turn_most
		print("PLAYGROUND_MOTION_BAKE skill=%s clip=%s windup=%.3f swing=%.3f recovery=%.3f samples=%d end=(%.2f, %.2f, %.2f) back_most=%.2f up=%.2f..%.2f turn_most=%.1f return=%s %s saved=%s" % [
			skill_id, clip, def.motion_windup, def.motion_swing, def.motion_recovery, points.size(),
			points[-1].x, points[-1].y, points[-1].z, back, lowest, highest, turn_most,
			def.motion_return_foot, def.motion_return_move, error_string(err)])
		written += 1
	print("PLAYGROUND_MOTION_BAKE done written=%d" % written)
	get_tree().quit()
