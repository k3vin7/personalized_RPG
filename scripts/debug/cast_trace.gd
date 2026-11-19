extends Node

# A recorder for the eye's complaints (2026-11-18: "the side cut comes out
# juddering", which no headless run reproduced). Started from the F1 panel, it
# writes down every drawn frame of this screen's own body for a few seconds --
# the frame time, where the body is and which way it faces, its state, the
# clip and where in it, where the model's sword hand and hips are against the
# body, whether the model is drawn, where the camera is -- and saves them with
# a summary of what changed by more than a moving body does in one frame.
# Drawn-side only: it reads, and rules nothing.

const SECONDS := 8.0
const OUT_PATH := "user://cast_trace.txt"

signal finished(path: String)

var player: Player
var _rows: Array[Dictionary] = []
var _left := 0.0


func start(owner_player: Player) -> void:
	player = owner_player
	_rows.clear()
	_left = SECONDS


func is_recording() -> bool:
	return _left > 0.0


func _process(delta: float) -> void:
	if _left <= 0.0 or not is_instance_valid(player):
		return
	_left -= delta
	var row := {
		"t": float(Time.get_ticks_usec()) / 1000000.0,
		"dt": delta,
		"tick": Engine.get_physics_frames(),
		"body": player.global_position,
		"yaw": rad_to_deg(player.rotation.y),
		"state": player.state,
		"skill": player.sync_skill_id,
		"phase": player.sync_skill_phase,
	}
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		row["camera"] = camera.global_position
	var visual := player.visual
	if visual != null and visual.model_loaded():
		var skeleton := visual.skeleton()
		row["hand"] = skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone("RightHand")).origin
		row["hips"] = skeleton.global_transform * skeleton.get_bone_global_pose(skeleton.find_bone("Hips")).origin
		row["clip"] = visual.current_clip()
		row["at"] = visual._anim.current_animation_position if visual._anim.is_playing() else -1.0
		row["speed"] = visual.clip_speed()
		row["shown"] = visual._model.visible
	_rows.append(row)
	if _left <= 0.0:
		_save()


func _save() -> void:
	var lines: Array[String] = []
	if _rows.size() < 3:
		return
	var t0 := float(_rows[0]["t"])
	var worst_dt := 0.0
	var total_dt := 0.0
	var events: Array[String] = []
	for index in range(1, _rows.size()):
		var a: Dictionary = _rows[index - 1]
		var b: Dictionary = _rows[index]
		var t := float(b["t"]) - t0
		var dt := maxf(float(b["t"]) - float(a["t"]), 0.0001)
		worst_dt = maxf(worst_dt, dt)
		total_dt += dt
		if dt > 0.034:
			events.append("%.3f long frame %.0f ms (%d physics ticks)" % [t, dt * 1000.0, int(b["tick"]) - int(a["tick"])])
		var turn := absf(wrapf(float(b["yaw"]) - float(a["yaw"]), -180.0, 180.0))
		if turn > 2.0:
			events.append("%.3f body turned %.0f deg in one frame" % [t, turn])
		if int(b["state"]) != int(a["state"]):
			events.append("%.3f state %s > %s" % [t, Player.State.keys()[a["state"]], Player.State.keys()[b["state"]]])
		if String(b["skill"]) != String(a["skill"]) or String(b["phase"]) != String(a["phase"]):
			events.append("%.3f skill %s/%s" % [t, b["skill"], b["phase"]])
		var moved := (b["body"] as Vector3).distance_to(a["body"] as Vector3)
		if moved / dt > 9.0:
			events.append("%.3f body moved %.2f m in one frame" % [t, moved])
		if b.has("camera") and a.has("camera"):
			var camera_step := (b["camera"] as Vector3).distance_to(a["camera"] as Vector3) - moved
			if absf(camera_step) / dt > 6.0:
				events.append("%.3f camera moved %.2f m more than the body in one frame" % [t, camera_step])
		if b.has("clip") and a.has("clip"):
			if String(b["clip"]) != String(a["clip"]):
				events.append("%.3f clip %s > %s" % [t, a["clip"], b["clip"]])
			if bool(b["shown"]) != bool(a["shown"]):
				events.append("%.3f model drawn = %s" % [t, b["shown"]])
			if String(b["clip"]) == String(a["clip"]) and float(b["at"]) >= 0.0 and float(a["at"]) >= 0.0 \
					and float(b["at"]) < float(a["at"]) - 0.001:
				events.append("%.3f clip %s went back from %.3f to %.3f" % [t, b["clip"], a["at"], b["at"]])
			var hand_a := (a["hand"] as Vector3) - (a["body"] as Vector3)
			var hand_b := (b["hand"] as Vector3) - (b["body"] as Vector3)
			if hand_a.distance_to(hand_b) / dt > 25.0:
				events.append("%.3f hand moved %.2f m against the body in one frame" % [t, hand_a.distance_to(hand_b)])
			var hips_a := (a["hips"] as Vector3) - (a["body"] as Vector3)
			var hips_b := (b["hips"] as Vector3) - (b["body"] as Vector3)
			if hips_a.distance_to(hips_b) / dt > 6.0:
				events.append("%.3f hips moved %.2f m against the body in one frame" % [t, hips_a.distance_to(hips_b)])
	lines.append("frames %d over %.2f s: average %.1f fps, longest frame %.0f ms" % [
		_rows.size(), total_dt, float(_rows.size() - 1) / maxf(total_dt, 0.001), worst_dt * 1000.0])
	lines.append("physics ticks per second %d, model profile %s" % [Engine.physics_ticks_per_second, CharacterVisual.profile_name()])
	lines.append("")
	lines.append("EVENTS")
	for event in events:
		lines.append("  " + event)
	lines.append("")
	lines.append("FRAMES  t | frame ms | ticks | state | skill/phase | clip @ position x speed | body speed m/s | hand speed against the body m/s | yaw")
	for index in range(1, _rows.size()):
		var a: Dictionary = _rows[index - 1]
		var b: Dictionary = _rows[index]
		var dt := maxf(float(b["t"]) - float(a["t"]), 0.0001)
		var clip_text := "-"
		var hand_speed := 0.0
		if b.has("clip") and a.has("clip"):
			clip_text = "%s @ %.3f x%.2f" % [b["clip"], b["at"], b["speed"]]
			hand_speed = ((a["hand"] as Vector3) - (a["body"] as Vector3)).distance_to(
				(b["hand"] as Vector3) - (b["body"] as Vector3)) / dt
		lines.append("%.3f | %5.1f | %d | %s | %s/%s | %s | %.2f | %.2f | %.0f" % [
			float(b["t"]) - t0, dt * 1000.0, int(b["tick"]) - int(a["tick"]), Player.State.keys()[b["state"]],
			b["skill"], b["phase"], clip_text,
			(b["body"] as Vector3).distance_to(a["body"] as Vector3) / dt, hand_speed, float(b["yaw"])])
	var file := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if file == null:
		push_error("CastTrace: %s would not open" % OUT_PATH)
		return
	file.store_string("\n".join(lines) + "\n")
	file.close()
	print("PLAYGROUND_CAST_TRACE saved=%s frames=%d" % [ProjectSettings.globalize_path(OUT_PATH), _rows.size()])
	finished.emit(ProjectSettings.globalize_path(OUT_PATH))
