extends Node

# C-1g-b, step 1: how many degrees the KayKit clips actually draw. The sword
# hangs off the right hand bone (CharacterVisual.attach_weapon: the node's -Z
# is the blade), so the clip alone turns it; the swing pivot only draws the
# trail. This steps each attack clip through its length on the host, reads
# the blade's direction and the hand's position every sample, and prints the
# yaw (about the body's heading, left positive) and pitch (up positive) each
# one covers. Two spans per clip: the whole clip, and the part that plays
# while the server's sweep runs (the last swing_time / (windup + swing_time)
# of it, since the clip is stretched over windup + swing). A measurement,
# not a judgment: nothing here is a PASS/FAIL on the game.

const SAMPLES := 60
const HOME := Vector3(0.0, 0.9, 11.0)

var _world: Node3D
var _local: Player
var _peer_id := 0


func note(line: String) -> void:
	print("C1GB_NOTE peer=%d %s" % [_peer_id, line])


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func run(world: Node3D) -> void:
	_world = world
	_peer_id = multiplayer.get_unique_id()
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	if not multiplayer.is_server():
		return
	await _wait(1.0)
	Net.queue_physics(func() -> void:
		_local.global_position = HOME
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target()
		_local.rotation.y = 0.0
		_local.set_weapon(WeaponKinds.Kind.SWORD))
	await _wait(1.0)
	var visual := _local.visual
	if visual == null or not visual.model_loaded():
		note("no model loaded; nothing to measure")
		print("C1GB_RESULT peer=%d measured=0" % _peer_id)
		get_tree().quit(1)
		return
	var measured := 0
	for row: Array in [["side_cut", "slash_h"], ["overhead_cut", "slash_v"], ["thrust", "thrust"]]:
		var def := Skills.get_def(row[0])
		var clip := CharacterVisual.clip_for(row[1])
		var out := await _measure(def, clip)
		if not out.is_empty():
			measured += 1
	print("C1GB_RESULT peer=%d measured=%d" % [_peer_id, measured])
	await _wait(0.5)
	get_tree().quit(0)


# Steps `clip` through its length and reads the blade and the hand.
func _measure(def: SkillDef, clip: String) -> Dictionary:
	var visual := _local.visual
	var anim: AnimationPlayer = visual._anim
	var hand: Node3D = visual._hand
	var weapon: Node3D = _local._weapon_node
	if anim == null or hand == null or weapon == null or not anim.has_animation(clip):
		note("%s: cannot measure (anim=%s hand=%s weapon=%s clip=%s)" % [def.id, anim != null, hand != null, weapon != null, clip])
		return {}
	var length := CharacterVisual.clip_length(clip)
	var heading := -_local.global_transform.basis.z
	heading.y = 0.0
	heading = heading.normalized()
	var right := Vector3(-heading.z, 0.0, heading.x)
	var pivot := _local.global_position + Vector3(0.0, def.strike_height * _local.body_scale(), 0.0)
	var windup := def.value("windup")
	var swing := def.swing_time()
	var swing_from := length * windup / maxf(windup + swing, 0.001)
	var rows: Array[Dictionary] = []
	anim.stop(true)
	anim.play(clip)
	anim.speed_scale = 0.0
	for index in SAMPLES + 1:
		var t := length * float(index) / float(SAMPLES)
		anim.seek(minf(t, length - 0.001), true)
		await get_tree().process_frame
		await get_tree().process_frame
		var blade := -weapon.global_transform.basis.z
		var blade_yaw := rad_to_deg(atan2(-blade.dot(right), blade.dot(heading)))
		var blade_pitch := rad_to_deg(asin(clampf(blade.y, -1.0, 1.0)))
		var hand_offset := hand.global_position - pivot
		var hand_yaw := rad_to_deg(atan2(-hand_offset.dot(right), hand_offset.dot(heading)))
		var hand_ahead := maxf(Vector2(hand_offset.dot(heading), hand_offset.dot(right)).length(), 0.001)
		var hand_pitch := rad_to_deg(atan2(hand_offset.y, hand_ahead))
		var tip := weapon.global_position + blade * CharacterVisual.SWORD_LENGTH
		var tip_offset := tip - pivot
		var tip_yaw := rad_to_deg(atan2(-tip_offset.dot(right), tip_offset.dot(heading)))
		var tip_ahead := maxf(Vector2(tip_offset.dot(heading), tip_offset.dot(right)).length(), 0.001)
		var tip_pitch := rad_to_deg(atan2(tip_offset.y, tip_ahead))
		rows.append({"t": t, "blade_yaw": blade_yaw, "blade_pitch": blade_pitch,
			"hand_yaw": hand_yaw, "hand_pitch": hand_pitch, "tip_yaw": tip_yaw, "tip_pitch": tip_pitch,
			"hand": hand_offset, "tip": tip_offset})
	anim.speed_scale = 1.0
	anim.stop(true)
	visual._pick_state_clip(true)
	var whole := _spans(rows, 0.0)
	var part := _spans(rows, swing_from)
	note("%s <- %s (%.2f s; plays over windup %.2f + swing %.2f; the sweep runs from clip t=%.2f): ruling arc %.0f in %s" % [
		def.id, clip, length, windup, swing, swing_from, def.arc_degrees(), SkillDef.ArcPlane.keys()[def.arc_plane]])
	for key in ["blade_yaw", "blade_pitch", "tip_yaw", "tip_pitch", "hand_yaw", "hand_pitch"]:
		note("  %-12s whole clip %7.1f .. %7.1f (span %6.1f)   |  swing part %7.1f .. %7.1f (span %6.1f)" % [
			key, whole[key]["min"], whole[key]["max"], whole[key]["span"],
			part[key]["min"], part[key]["max"], part[key]["span"]])
	# The path, every 6th sample, so the shape can be read (where it starts,
	# where it turns back).
	var path := []
	for index in range(0, rows.size(), 6):
		var row := rows[index]
		path.append("t%.2f by%.0f bp%.0f ty%.0f tp%.0f" % [row["t"], row["blade_yaw"], row["blade_pitch"], row["tip_yaw"], row["tip_pitch"]])
	note("  path: %s" % " | ".join(path))
	# Net travel in the swing part (signed, first to last), which is what a
	# sweep in one direction would cover; the span above counts a swing that
	# goes out and comes back twice.
	var first := rows[_first_index(rows, swing_from)]
	var last := rows[rows.size() - 1]
	note("  swing part net: blade yaw %.1f -> %.1f (%.1f), blade pitch %.1f -> %.1f (%.1f), tip yaw %.1f -> %.1f (%.1f), tip pitch %.1f -> %.1f (%.1f)" % [
		first["blade_yaw"], last["blade_yaw"], last["blade_yaw"] - first["blade_yaw"],
		first["blade_pitch"], last["blade_pitch"], last["blade_pitch"] - first["blade_pitch"],
		first["tip_yaw"], last["tip_yaw"], last["tip_yaw"] - first["tip_yaw"],
		first["tip_pitch"], last["tip_pitch"], last["tip_pitch"] - first["tip_pitch"]])
	return whole


static func _first_index(rows: Array[Dictionary], from_t: float) -> int:
	for index in rows.size():
		if float(rows[index]["t"]) >= from_t:
			return index
	return rows.size() - 1


static func _spans(rows: Array[Dictionary], from_t: float) -> Dictionary:
	var out := {}
	for key in ["blade_yaw", "blade_pitch", "tip_yaw", "tip_pitch", "hand_yaw", "hand_pitch"]:
		var low := INF
		var high := -INF
		for row in rows:
			if float(row["t"]) < from_t:
				continue
			low = minf(low, float(row[key]))
			high = maxf(high, float(row[key]))
		out[key] = {"min": low, "max": high, "span": high - low}
	return out
