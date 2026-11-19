extends Node3D

# Model swap test (2026-11-06): one CharacterVisual on its own, no body, no
# session, no rulings. It reads what a model profile gives the game -- the
# skeleton, where the clips' tracks land, which pictures have a clip, how the
# sword hangs off handslot.r, the texture -- and prints every number. With a
# window it also saves screenshots to reports/tripo_human/ for the eye.
#
#   headless:  godot --headless --path . res://scenes/tests/tripo_visual_test.tscn -- --model=tripo
#   windowed:  godot --path . res://scenes/tests/tripo_visual_test.tscn -- --model=tripo
#
# --model= is read by CharacterVisual itself; without it the default profile
# is tested, so the same run on kaykit is the baseline.

const CAPSULE_HEIGHT := Player.BODY_HALF_HEIGHT * 2.0
const OUT_DIR := "res://reports/tripo_human/"
const SAMPLES := 24
# Per-profile bone names the facing check reads (toe ahead of heel).
const FEET := {
	"tripo": ["LeftFoot", "LeftToe_End", "RightForeArm", "RightHand"],
	"kaykit": ["foot.l", "toes.l", "lowerarm.r", "hand.r"],
}

var _profile := ""
var _shots := false
var _checks := 0
var _failures := 0
var visual: CharacterVisual
var _camera: Camera3D
var _texture_mem_before := 0
var _video_mem_before := 0


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("TRIPO_CHECK profile=%s %s %s" % [_profile, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("TRIPO_NOTE profile=%s %s" % [_profile, line])


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _ready() -> void:
	_profile = CharacterVisual.profile_name()
	_shots = DisplayServer.get_name() != "headless"
	_build_stage()
	await get_tree().process_frame
	_texture_mem_before = int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED))
	_video_mem_before = int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED))
	visual = CharacterVisual.new()
	visual.name = "CharacterVisual"
	add_child(visual)
	visual.setup_preview()
	await get_tree().process_frame
	await get_tree().process_frame
	_value_cost()
	await _model_checks()
	await _track_checks()
	await _clip_checks()
	await _prop_checks()
	await _texture_checks()
	print("TRIPO_RESULT profile=%s checks=%d failures=%d shots=%s" % [_profile, _checks, _failures, _shots])
	await _wait(0.2)
	get_tree().quit(0 if _failures == 0 else 1)


# What one SkillDef.value() costs: it is asked for several times a frame by a
# swing's picture and several times a physics tick by the server's sweep.
func _value_cost() -> void:
	var calls := 2000
	var began := Time.get_ticks_usec()
	for index in calls:
		Tuning.is_server_field("side_cut_arc_deg")
	var field_us := float(Time.get_ticks_usec() - began) / float(calls)
	var rows: Array[String] = []
	for id in ["side_cut", "side_cut_2", "overhead_cut", "thrust_2"]:
		var def := Skills.get_def(id)
		began = Time.get_ticks_usec()
		for index in calls:
			def.value("arc_deg")
		rows.append("%s %.1f" % [id, float(Time.get_ticks_usec() - began) / float(calls)])
	note("cost in microseconds per call: Tuning.is_server_field %.1f; SkillDef.value(arc_deg): %s" % [field_us, ", ".join(rows)])


# ------------------------------------------------------------------ stage

func _build_stage() -> void:
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(8.0, 8.0)
	floor_mesh.mesh = plane
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = Color(0.35, 0.37, 0.4)
	floor_mesh.material_override = floor_material
	floor_mesh.position.y = -Player.BODY_HALF_HEIGHT
	add_child(floor_mesh)
	# A 1.8 m post beside the model: the capsule's height, for the eye.
	var post := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.05, CAPSULE_HEIGHT, 0.05)
	post.mesh = box
	post.position = Vector3(-1.2, 0.0, 0.0)
	var post_material := StandardMaterial3D.new()
	post_material.albedo_color = Color(0.9, 0.3, 0.2)
	post.material_override = post_material
	add_child(post)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, 35.0, 0.0)
	sun.light_energy = 1.2
	add_child(sun)
	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.12, 0.13, 0.16)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.72, 0.8)
	env.ambient_light_energy = 0.6
	environment.environment = env
	add_child(environment)
	_camera = Camera3D.new()
	_camera.fov = 35.0
	add_child(_camera)
	_look("front")


# Camera spots: the model faces -Z, so "front" stands at -Z looking back.
func _look(spot: String) -> void:
	match spot:
		"front":
			_camera.position = Vector3(0.0, 0.1, -3.4)
			_camera.look_at(Vector3(0.0, 0.0, 0.0))
		"side":
			_camera.position = Vector3(3.4, 0.1, 0.0)
			_camera.look_at(Vector3(0.0, 0.0, 0.0))
		"hands":
			_camera.position = Vector3(-0.9, 0.2, -1.4)
			_camera.look_at(Vector3(-0.25, -0.1, 0.0))
		"three_quarter":
			_camera.position = Vector3(-2.3, 0.6, -2.3)
			_camera.look_at(Vector3(0.0, -0.1, 0.0))
		"right_hand":
			# Close on the right hand wherever it is now, from the front-right.
			var hand: Node3D = visual._hand
			_camera.position = hand.global_position + Vector3(-0.55, 0.25, -0.75)
			_camera.look_at(hand.global_position)


func _shot(name_text: String) -> void:
	if not _shots:
		return
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	if image == null:
		note("no image for %s" % name_text)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var path := OUT_DIR + "%s_%s.png" % [_profile, name_text]
	var err := image.save_png(path)
	note("shot %s (%s)" % [path, "saved" if err == OK else "error %d" % err])


# ------------------------------------------------------------------ 1: the model

func _bone_global(bone: String) -> Vector3:
	var skeleton := visual.skeleton()
	var index := skeleton.find_bone(bone)
	if index < 0:
		return Vector3.INF
	return skeleton.global_transform * skeleton.get_bone_global_pose(index).origin


func _model_checks() -> void:
	expect(visual.model_loaded(), "the_model_and_its_hand_slot_loaded")
	if not visual.model_loaded():
		return
	var skeleton := visual.skeleton()
	var names: Array[String] = []
	for index in skeleton.get_bone_count():
		names.append(skeleton.get_bone_name(index))
	var want_bones := int(CharacterVisual.profile()["bones"])
	note("skeleton: %d bones (profile says %d); first %s" % [names.size(), want_bones, names.slice(0, 6)])
	expect(names.size() == want_bones, "the_skeleton_has_the_profiles_bone_count")
	var colons := names.filter(func(n: String) -> bool: return n.contains(":"))
	expect(colons.is_empty(), "no_bone_name_carries_a_colon")
	for slot in [CharacterVisual.HAND_BONE, CharacterVisual.OFFHAND_BONE]:
		var index := skeleton.find_bone(slot)
		var parent := skeleton.get_bone_name(skeleton.get_bone_parent(index)) if index >= 0 else "none"
		note("%s -> bone %d, parent %s" % [slot, index, parent])
		expect(index >= 0, "the_rig_has_%s" % slot)
	# Height against the capsule (the collider is BODY_HALF_HEIGHT * 2 at the
	# human scale; the model is scaled onto it, not the other way round).
	var height := visual.measured_height()
	var want_scale := CAPSULE_HEIGHT / CharacterVisual.model_height()
	note("height: profile model units %.3f, model_scale %.3f (expected %.3f), measured %.3f m against the capsule's %.2f m" % [
		CharacterVisual.model_height(), visual.model_scale, want_scale, height, CAPSULE_HEIGHT])
	expect(absf(visual.model_scale - want_scale) < 0.001, "model_scale_is_capsule_height_over_model_height")
	expect(absf(height - CAPSULE_HEIGHT) < CAPSULE_HEIGHT * 0.06, "the_model_stands_as_tall_as_the_capsule")
	# Feet on the capsule's bottom, head at its top (rest pose, idle paused).
	var top := -INF
	var bottom := INF
	for node in skeleton.get_children():
		var mesh := node as MeshInstance3D
		if mesh == null:
			continue
		var box := mesh.get_aabb()
		top = maxf(top, box.position.y + box.size.y)
		bottom = minf(bottom, box.position.y)
	var feet_y := bottom * visual.model_scale + visual._model.position.y
	var head_y := top * visual.model_scale + visual._model.position.y
	note("mesh aabb in model units: bottom %.3f top %.3f; on the body: feet y %.3f (capsule bottom %.3f), head y %.3f (capsule top %.3f)" % [
		bottom, top, feet_y, -Player.BODY_HALF_HEIGHT, head_y, Player.BODY_HALF_HEIGHT])
	expect(absf(feet_y + Player.BODY_HALF_HEIGHT) < 0.03, "the_feet_stand_on_the_capsules_bottom")
	# Facing: a body's forward is -Z; the toe must be ahead of the heel.
	var feet: Array = FEET.get(_profile, [])
	if feet.size() == 4:
		var heel := _bone_global(String(feet[0]))
		var toe := _bone_global(String(feet[1]))
		note("facing: heel z %.3f, toe z %.3f (toe - heel = %.3f; negative is forward)" % [heel.z, toe.z, toe.z - heel.z])
		expect(toe.z < heel.z, "the_model_faces_minus_z")
	await _shot("rest_front")
	_look("side")
	await _shot("rest_side")
	_look("front")


# ------------------------------------------------------------------ 2: the tracks

func _track_checks() -> void:
	var anim: AnimationPlayer = visual._anim
	var root := anim.get_node(anim.root_node)
	var skeleton := visual.skeleton()
	var clips := anim.get_animation_list()
	var total := 0
	var unresolved := 0
	var unresolved_sample: Array[String] = []
	var lengths := {}
	for clip in clips:
		var animation := anim.get_animation(clip)
		lengths[String(clip)] = snappedf(animation.length, 0.001)
		for track in animation.get_track_count():
			total += 1
			var path := animation.track_get_path(track)
			var node_part := NodePath(String(path).split(":")[0])
			var target := root.get_node_or_null(node_part)
			var bone := path.get_concatenated_subnames()
			var ok := target == skeleton and skeleton.find_bone(bone) >= 0
			if not ok:
				unresolved += 1
				if unresolved_sample.size() < 5:
					unresolved_sample.append(String(path))
	note("clips in the library: %d %s" % [clips.size(), lengths])
	note("tracks: %d, unresolved %d %s" % [total, unresolved, unresolved_sample])
	expect(clips.size() > 0, "the_clip_files_gave_a_library")
	expect(unresolved == 0, "every_track_lands_on_a_bone_of_this_skeleton")
	# Which pictures have a clip and which stay empty.
	var filled: Array[String] = []
	var empty: Array[String] = []
	for key in CharacterVisual.profile()["clips"]:
		var clip := CharacterVisual.clip_for(key)
		if clip == "":
			empty.append(key)
		elif anim.has_animation(clip):
			filled.append("%s=%s" % [key, clip])
		else:
			expect(false, "picture_%s_names_a_missing_clip_%s" % [key, clip])
	# 2026-11-18: the clips that stand in with a weapon in hand, and the
	# upper-body player a draw or a sheathe runs on.
	var armed: Dictionary = CharacterVisual.profile().get("armed", {})
	for key in armed:
		var clip := String(armed[key])
		if anim.has_animation(clip):
			filled.append("armed %s=%s" % [key, clip])
		else:
			expect(false, "armed_picture_%s_names_a_missing_clip_%s" % [key, clip])
	if armed.has("draw"):
		var upper: AnimationPlayer = visual._upper
		expect(upper != null and upper.has_animation(String(armed["draw"])) and upper.has_animation(String(armed["sheathe"])),
			"the_upper_body_player_has_the_draw_and_the_sheathe")
		if upper != null:
			var legs := 0
			var draw := upper.get_animation(String(armed["draw"]))
			for track in draw.get_track_count():
				var bone := String(draw.track_get_path(track).get_subname(0))
				if bone == "Hips" or bone.ends_with("Leg") or bone.ends_with("Foot"):
					legs += 1
			note("draw on the upper player: %.2f s, %d tracks, %d of them on the hips or legs; blade shown after %.2f s" % [
				draw.length, draw.get_track_count(), legs, float(CharacterVisual._first_part.get(String(armed["draw"]), 0.0))])
			expect(legs == 0, "the_draw_leaves_the_legs_alone")
	note("pictures with a clip: %s" % [filled])
	note("pictures without a clip (nothing substituted): %s" % [empty])
	for key in ["idle", "walk", "run", "slash_v"]:
		expect(CharacterVisual.clip_for(key) != "" and anim.has_animation(CharacterVisual.clip_for(key)),
			"picture_%s_has_a_clip" % key)


# ------------------------------------------------------------------ 3: the clips

func _hand_travel(seconds: float) -> float:
	var hand: Node3D = visual._hand
	var start := hand.global_position
	var far := 0.0
	var waited := 0.0
	while waited < seconds:
		await get_tree().process_frame
		waited += get_process_delta_time()
		far = maxf(far, hand.global_position.distance_to(start))
	return far


# Bones a clip has no track for keep their last pose (KayKit's Spawn clips
# scale the root to 0, and the pose stuck): the skeleton is put back to rest
# between clips that are not meant to follow each other.
func _reset_pose() -> void:
	var anim: AnimationPlayer = visual._anim
	anim.stop(false)
	visual.skeleton().reset_bone_poses()
	await get_tree().process_frame


func _clip_checks() -> void:
	var anim: AnimationPlayer = visual._anim
	# The pictures the order names: idle, walk, run, and the attack below.
	for key in ["idle", "walk", "run"]:
		var clip := CharacterVisual.clip_for(key)
		if clip == "":
			continue
		visual._play(key)
		await get_tree().process_frame
		var playing := anim.is_playing() and anim.current_animation == clip
		var travel := await _hand_travel(0.5)
		var length := CharacterVisual.clip_length(clip)
		var loops := anim.get_animation(clip).loop_mode == Animation.LOOP_LINEAR
		note("%s -> %s: %.3f s, loop=%s, playing=%s, hand travelled %.3f m in 0.5 s at x%.2f" % [
			key, clip, length, loops, playing, travel, anim.speed_scale])
		expect(playing, "%s_plays_its_clip" % key)
		# An idle only breathes (KayKit's Idle_A: 3 mm in 0.5 s); the gaits swing the arm.
		expect(travel > (0.001 if key == "idle" else 0.01), "%s_moves_the_body" % key)
		expect(loops, "%s_loops" % key)
		if key != "idle":
			await _shot("%s_mid" % key)
	# A still check on the loop seam: the run loop at its end vs its start.
	var run_clip := CharacterVisual.clip_for("run")
	if run_clip != "":
		var seam := await _seam_gap(run_clip)
		note("%s loop seam: hand position gap %.4f m between the last and the first frame" % [run_clip, seam])
		expect(seam < 0.02, "the_run_loop_closes")
	# The attack: slash_v (the only attack picture Tripo has a clip of the
	# same meaning for). Played the way Player does: stretched over
	# windup + swing, then the last frame holds.
	var slash := CharacterVisual.clip_for("slash_v")
	if slash != "":
		var seconds := 0.6
		visual._start_attack(slash, seconds)
		var want_speed := CharacterVisual.clip_length(slash) / seconds
		var speed := anim.speed_scale
		var started := Time.get_ticks_msec()
		while visual.attack_finished_msec == 0 and Time.get_ticks_msec() - started < 3000:
			await get_tree().process_frame
		var took := float(visual.attack_finished_msec - visual.attack_started_msec) / 1000.0
		note("slash_v -> %s: %.3f s clip at x%.3f (want x%.3f) over %.2f s; finished after %.3f s; holds %s" % [
			slash, CharacterVisual.clip_length(slash), speed, want_speed, seconds, took, visual.current_clip()])
		expect(absf(speed - want_speed) < 0.01, "slash_v_runs_at_clip_length_over_the_swing_time")
		expect(visual.attack_finished_msec != 0 and absf(took - seconds) < 0.1, "slash_v_ends_with_the_swing")
		await _sweep(slash)
	visual.show_phase(null, "")
	# Every clip in the file plays (last: some leave a pose behind).
	var silent: Array[String] = []
	for clip in anim.get_animation_list():
		visual._play_at(clip, 1.0)
		await get_tree().process_frame
		if not anim.is_playing() or anim.current_animation != clip:
			silent.append(clip)
	expect(silent.is_empty(), "every_clip_in_the_file_plays")
	if not silent.is_empty():
		note("clips that would not play: %s" % [silent])
	# 2026-11-18: with a weapon in hand each picture goes to its armed clip
	# and comes back to the empty-handed one; the draw runs on the upper
	# player while the legs keep the gait.
	var armed: Dictionary = CharacterVisual.profile().get("armed", {})
	if not armed.is_empty():
		var wrong: Array[String] = []
		for key in ["idle", "walk", "run", "block"]:
			if not armed.has(key):
				continue
			visual.preview_armed = true
			visual._play(key)
			await get_tree().process_frame
			if anim.current_animation != String(armed[key]) or not anim.is_playing():
				wrong.append("armed %s -> %s" % [key, anim.current_animation])
			visual.preview_armed = false
			visual._play(key)
			await get_tree().process_frame
			var bare := CharacterVisual.clip_for(key)
			if bare != "" and anim.current_animation != bare:
				wrong.append("bare %s -> %s" % [key, anim.current_animation])
		note("armed pictures in and out: %s" % ["all as named" if wrong.is_empty() else str(wrong)])
		expect(wrong.is_empty(), "armed_clips_go_in_and_come_back_out")
		visual.preview_armed = true
		visual._play("run")
		var sword := CharacterVisual.build_weapon_mesh(WeaponKinds.Kind.SWORD)
		visual.attach_weapon(sword)
		visual.play_draw(sword)
		await get_tree().process_frame
		var upper: AnimationPlayer = visual._upper
		var hidden_at_start := not sword.visible
		var both := upper != null and upper.is_playing() and anim.is_playing() and anim.current_animation == String(armed["run"])
		await _wait(float(CharacterVisual._first_part.get(String(armed.get("draw", "")), 0.0)) + 0.15)
		note("draw over the run: both players running %s, blade hidden at the start %s, shown after the reach %s" % [
			both, hidden_at_start, sword.visible])
		expect(both and hidden_at_start and sword.visible, "the_draw_plays_over_the_run_and_shows_the_blade")
		await _wait(1.0)
		expect(upper != null and not upper.is_playing() and anim.is_playing(), "the_draw_ends_and_the_run_goes_on")
		# Where the blade points at the end of each armed attack clip: off the
		# forearm (0 = along the arm) and off the body's forward.
		for key in ["thrust", "thrust_2", "side_cut", "side_cut_2", "dash_cut"]:
			var clip := String(armed.get(key, ""))
			if clip == "" or not anim.has_animation(clip):
				continue
			# Played the way a cast plays it, so the turn of the weapon in the
			# hand (the profile's aim_along_arm) has run by the time it is read.
			visual._start_attack(clip, 0.4)
			await _wait(0.9)
			var blade := -sword.global_transform.basis.z.normalized()
			# The forearm as it is drawn: the pose read back, turned by the
			# same turn the modifiers gave the slot it ends in.
			var slot_bone := visual.skeleton().find_bone(CharacterVisual.HAND_BONE)
			var posed := (visual.skeleton().global_transform * visual.skeleton().get_bone_global_pose(slot_bone)).basis.orthonormalized()
			var drawn: Basis = visual._hand.global_transform.basis.orthonormalized()
			var forearm := (drawn * posed.inverse() * (_bone_global("RightHand") - _bone_global("RightForeArm"))).normalized()
			var forward := -visual.global_transform.basis.z
			# The hand as it is drawn: the slot's attachment follows the
			# skeleton after its modifiers (the waist lean), which a pose read
			# back from the skeleton does not show.
			var drawn_hand: Vector3 = visual._hand.global_position
			var lean_now := float(visual._lean.get("degrees")) if visual._lean != null else 0.0
			note("%s -> %s ends (%.2f s): blade %.0f deg off the forearm, %.0f deg off forward, pitch %.0f; hand %.2f m ahead, %.2f m up from the feet; waist lean %.0f deg" % [
				key, clip, CharacterVisual.clip_length(clip),
				rad_to_deg(acos(clampf(blade.dot(forearm), -1.0, 1.0))),
				rad_to_deg(acos(clampf(blade.dot(forward), -1.0, 1.0))),
				rad_to_deg(asin(clampf(blade.y, -1.0, 1.0))),
				(drawn_hand - visual.global_position).dot(forward),
				drawn_hand.y + Player.BODY_HALF_HEIGHT, lean_now])
			visual.show_phase(null, "")
			await _wait(0.4)
		# The thrust held at its end: the blade's tip should stand still. Every
		# frame for half a second after the clip has ended, where the tip is
		# and what turn the weapon has in the hand.
		if anim.has_animation("ss_thrust"):
			visual._start_attack("ss_thrust", 0.27)
			await _wait(0.45)
			var tips: Array[Vector3] = []
			var grips: Array[Quaternion] = []
			var hands: Array[Vector3] = []
			for frame in 40:
				await get_tree().process_frame
				tips.append(sword.to_global(Vector3(0.0, 0.0, -CharacterVisual.SWORD_LENGTH)))
				grips.append(visual._grip.basis.orthonormalized().get_rotation_quaternion())
				hands.append(visual._hand.global_position)
			var tip_step := 0.0
			var grip_step := 0.0
			var hand_step := 0.0
			for frame in range(1, tips.size()):
				tip_step = maxf(tip_step, tips[frame].distance_to(tips[frame - 1]))
				grip_step = maxf(grip_step, rad_to_deg(grips[frame].angle_to(grips[frame - 1])))
				hand_step = maxf(hand_step, hands[frame].distance_to(hands[frame - 1]))
			var sample: Array[String] = []
			for frame in 8:
				sample.append("%.3f" % tips[frame].distance_to(tips[0]))
			note("thrust held at its end, 40 frames: the tip moves at most %.3f m between frames, the weapon turns in the hand at most %.1f deg, the hand moves at most %.3f m; tip from its first place over 8 frames: %s" % [
				tip_step, grip_step, hand_step, " ".join(sample)])
			expect(tip_step < 0.01, "the_blade_stands_still_when_the_thrust_is_held")
			visual.show_phase(null, "")
			await _wait(0.4)
			# The same thrust at 60 frames a second, start to end and back to
			# standing: which way the blade points every frame. A blade that
			# shakes turns one way and then back; counted as the frames where
			# its turn reverses on the frame before by more than a degree.
			Engine.max_fps = 60
			await get_tree().process_frame
			visual._start_attack("ss_thrust", 0.27)
			var pointing: Array[Vector3] = []
			var turned_in_hand: Array[Quaternion] = []
			var stamps_60: Array[float] = []
			var began_60 := Time.get_ticks_usec()
			var ended := false
			while float(Time.get_ticks_usec() - began_60) / 1000000.0 < 0.95:
				await get_tree().process_frame
				var at_60 := float(Time.get_ticks_usec() - began_60) / 1000000.0
				if at_60 > 0.45 and not ended:
					ended = true
					visual.show_phase(null, "")
				stamps_60.append(at_60)
				pointing.append(-sword.global_transform.basis.z.normalized())
				turned_in_hand.append(visual._grip.basis.orthonormalized().get_rotation_quaternion())
			Engine.max_fps = 0
			var reversals: Array[String] = []
			var biggest_turn := 0.0
			for frame in range(2, pointing.size()):
				var before := pointing[frame - 1] - pointing[frame - 2]
				var after := pointing[frame] - pointing[frame - 1]
				var step_deg := rad_to_deg(pointing[frame].angle_to(pointing[frame - 1]))
				biggest_turn = maxf(biggest_turn, step_deg)
				if before.dot(after) < 0.0 and rad_to_deg(before.length()) > 1.0 and rad_to_deg(after.length()) > 1.0:
					reversals.append("%.2fs (%.0f then %.0f deg)" % [stamps_60[frame], rad_to_deg(before.length()), rad_to_deg(after.length())])
			var per_frame: Array[String] = []
			for frame in range(1, pointing.size()):
				per_frame.append("%.2f:%.0f/%.0f" % [stamps_60[frame], rad_to_deg(pointing[frame].angle_to(pointing[frame - 1])),
					rad_to_deg(turned_in_hand[frame].angle_to(turned_in_hand[frame - 1]))])
			note("thrust at 60 fps (%d frames; the clip ends at 0.27 s, the cast at 0.45 s): the blade turns at most %.0f deg in a frame; reversals: %s" % [
				pointing.size(), biggest_turn, reversals])
			note("thrust at 60 fps, per frame time:blade turn/turn in the hand (deg): %s" % " ".join(per_frame))
		# A combo's next step starts from where the body is: two frames into
		# the kick step the hips are still on their way from the thrust's last
		# pose, not already at the kick clip's first one.
		if anim.has_animation("ss_thrust") and anim.has_animation("ss_thrust_kick"):
			var hips := visual.skeleton().find_bone("Hips")
			var kick := anim.get_animation("ss_thrust_kick")
			var hips_track := -1
			for track in kick.get_track_count():
				if kick.track_get_type(track) == Animation.TYPE_ROTATION_3D \
						and String(kick.track_get_path(track).get_subname(0)) == "Hips":
					hips_track = track
			visual._start_attack("ss_thrust", 0.3)
			await _wait(0.6)
			var held := visual.skeleton().get_bone_pose_rotation(hips)
			var first: Quaternion = kick.rotation_track_interpolate(hips_track, 0.0)
			visual._start_attack("ss_thrust_kick", 0.6)
			await get_tree().process_frame
			await get_tree().process_frame
			var now := visual.skeleton().get_bone_pose_rotation(hips)
			var whole := rad_to_deg(held.angle_to(first))
			var gone := rad_to_deg(held.angle_to(now))
			note("thrust -> kick step: the hips have %.0f deg to turn between the two clips; two frames in they have turned %.0f" % [whole, gone])
			expect(gone < whole * 0.8, "the_next_step_is_blended_into_not_snapped_to")
			await _wait(0.8)
			visual.show_phase(null, "")
			await _wait(0.4)
		# The overhead cut's clip through its length: how far the chest tips
		# forward from upright, how high the head and the sword hand are.
		var chop := String(CharacterVisual.clip_for("slash_v"))
		if chop != "" and anim.has_animation(chop):
			var chest_bone := visual.skeleton().find_bone("Spine2")
			var facing_way := -visual.global_transform.basis.z
			# Stepped by hand, with no blend from the clip before it (a blend
			# does not advance while the speed is 0).
			anim.stop(true)
			anim.play(chop)
			anim.speed_scale = 0.0
			# As a cast has it: the clip is the attack on screen, so the
			# waist is straightened (the profile's straighten_clips).
			visual._attack_clip = chop
			# Drawn poses (after the skeleton's modifiers) are read off
			# attachments; a pose read back from the skeleton is the clip's.
			var drawn_chest := BoneAttachment3D.new()
			drawn_chest.bone_name = "Spine2"
			visual.skeleton().add_child(drawn_chest)
			var drawn_head := BoneAttachment3D.new()
			drawn_head.bone_name = "Head"
			visual.skeleton().add_child(drawn_head)
			var chop_length := CharacterVisual.clip_length(chop)
			var chop_rows: Array[String] = []
			for step in 9:
				anim.seek(minf(chop_length * float(step) / 8.0, chop_length - 0.001), true)
				await get_tree().process_frame
				await get_tree().process_frame
				var chest_up := ((visual.skeleton().global_transform * visual.skeleton().get_bone_global_pose(chest_bone)).basis.y).normalized()
				var tip := rad_to_deg(atan2(chest_up.dot(facing_way), chest_up.y))
				var drawn_up := drawn_chest.global_transform.basis.y.normalized()
				var drawn_tip := rad_to_deg(atan2(drawn_up.dot(facing_way), drawn_up.y))
				var hand_drawn: Vector3 = visual._hand.global_position
				chop_rows.append("%.2fs: chest %.0f deg forward in the clip, %.0f drawn; head %.2f m up in the clip, %.2f drawn; hand drawn %.2f m up / %.2f m ahead" % [
					chop_length * float(step) / 8.0, tip, drawn_tip, _bone_global("Head").y + Player.BODY_HALF_HEIGHT,
					drawn_head.global_position.y + Player.BODY_HALF_HEIGHT,
					hand_drawn.y + Player.BODY_HALF_HEIGHT, (hand_drawn - visual.global_position).dot(facing_way)])
			note("overhead cut clip %s (%.2f s), straighten %.2f: %s" % [
				chop, chop_length, float(Tuning.values.visual_chop_straighten), " | ".join(chop_rows)])
			drawn_chest.queue_free()
			drawn_head.queue_free()
			anim.speed_scale = 1.0
			visual.show_phase(null, "")
			await _wait(0.4)
		# The parry is a left-arm block mirrored onto the sword arm: at its end
		# the right hand is the one out in front, and the body is still a
		# body (head up, both feet near the floor).
		if anim.has_animation("ss_parry"):
			visual._start_attack("ss_parry", 0.4)
			await _wait(0.8)
			var facing := -visual.global_transform.basis.z
			var feet_y := -Player.BODY_HALF_HEIGHT
			var right_ahead := (_bone_global("RightHand") - visual.global_position).dot(facing)
			var left_ahead := (_bone_global("LeftHand") - visual.global_position).dot(facing)
			note("parry end: right hand %.2f m ahead / %.2f m up, left hand %.2f m ahead / %.2f m up, head %.2f m up, feet %.2f and %.2f m up" % [
				right_ahead, _bone_global("RightHand").y - feet_y, left_ahead, _bone_global("LeftHand").y - feet_y,
				_bone_global("Head").y - feet_y, _bone_global("LeftFoot").y - feet_y, _bone_global("RightFoot").y - feet_y])
			expect(_bone_global("Head").y - feet_y > 1.3 and _bone_global("LeftFoot").y - feet_y < 0.35
				and _bone_global("RightFoot").y - feet_y < 0.35, "the_mirrored_parry_is_still_a_standing_body")
			expect(_bone_global("RightHand").y > _bone_global("LeftHand").y or right_ahead > left_ahead,
				"the_parry_is_made_with_the_sword_arm")
			visual.show_phase(null, "")
			await _wait(0.4)
		# The side cut's two level cuts and the overhead cut with its step
		# (2026-11-19), each stepped through its length with the sword on:
		# where the blade's tip is against the body, how high the hand is,
		# what the feet do. Then, over the part the blade passes in (from the
		# profile's "strikes" to the end), how far the tip travels sideways,
		# up and down, and ahead: a level cut is nearly all sideways, an
		# upright one nearly all down.
		var cut_facing := -visual.global_transform.basis.z
		var cut_right := cut_facing.cross(Vector3.UP).normalized()
		var strike_table: Dictionary = CharacterVisual.profile().get("strikes", {})
		var ends_of := {}
		for cut_row: Array in [["ss_cut_1", "side cut 1"], ["ss_cut_2", "side cut 2"]]:
			var cut_clip := String(cut_row[0])
			if not anim.has_animation(cut_clip):
				expect(false, "%s_is_in_the_library" % cut_clip)
				continue
			anim.stop(true)
			anim.play(cut_clip)
			anim.speed_scale = 0.0
			var cut_length := CharacterVisual.clip_length(cut_clip)
			var strike_from := float(strike_table.get(cut_clip, 0.0))
			var cut_rows: Array[String] = []
			var span_low := Vector3.INF
			var span_high := -Vector3.INF
			var samples := 24
			for step in samples + 1:
				var at := cut_length * float(step) / float(samples)
				anim.seek(minf(at, cut_length - 0.001), true)
				await get_tree().process_frame
				await get_tree().process_frame
				var tip := sword.to_global(Vector3(0.0, 0.0, -CharacterVisual.BLADE_LENGTH)) - visual.global_position
				var tip_local := Vector3(tip.dot(cut_right), tip.y + Player.BODY_HALF_HEIGHT, tip.dot(cut_facing))
				var hand_up := _bone_global("RightHand").y + Player.BODY_HALF_HEIGHT
				if step == 0:
					ends_of[cut_clip + "/start"] = [_bone_global("RightHand"), sword.to_global(Vector3(0.0, 0.0, -CharacterVisual.BLADE_LENGTH))]
				if step == samples:
					ends_of[cut_clip + "/end"] = [_bone_global("RightHand"), sword.to_global(Vector3(0.0, 0.0, -CharacterVisual.BLADE_LENGTH))]
				if at >= strike_from - 0.001:
					span_low = Vector3(minf(span_low.x, tip_local.x), minf(span_low.y, tip_local.y), minf(span_low.z, tip_local.z))
					span_high = Vector3(maxf(span_high.x, tip_local.x), maxf(span_high.y, tip_local.y), maxf(span_high.z, tip_local.z))
				if step % 3 == 0:
					cut_rows.append("%.2fs%s: tip %.2f right / %.2f up / %.2f ahead, hand %.2f up, left foot %.2f up %.2f ahead, right foot %.2f up %.2f ahead" % [
						at, "*" if at >= strike_from - 0.001 else "", tip_local.x, tip_local.y, tip_local.z, hand_up,
						_bone_global("LeftFoot").y + Player.BODY_HALF_HEIGHT, (_bone_global("LeftFoot") - visual.global_position).dot(cut_facing),
						_bone_global("RightFoot").y + Player.BODY_HALF_HEIGHT, (_bone_global("RightFoot") - visual.global_position).dot(cut_facing)])
			var spread := span_high - span_low
			# How upright the blade's pass is: 0 is level, 90 straight down.
			var steepness := rad_to_deg(atan2(spread.y, maxf(spread.x, 0.001)))
			note("%s (%s, %.2f s, blade passes from %.2f s, rows marked *): %s" % [cut_row[1], cut_clip, cut_length, strike_from, " | ".join(cut_rows)])
			note("%s: over its pass the tip covers %.2f m sideways, %.2f m up-and-down, %.2f m fore-and-aft: %.0f deg off level" % [
				cut_row[1], spread.x, spread.y, spread.z, steepness])
			if cut_clip == "ss_over":
				# A person's own cut, out of a bout: mostly down, and ending
				# ahead of the body (not behind it, as the file has it before
				# the clip is turned round).
				expect(steepness > 45.0 and spread.y > 0.8, "the_overhead_cut_comes_down")
				expect(span_high.z > 0.6, "the_overhead_cut_lands_ahead_of_the_body")
			else:
				expect(steepness < 35.0 and spread.x > 0.8, "%s_is_a_level_cut" % cut_clip)
		if ends_of.has("ss_cut_1/end") and ends_of.has("ss_cut_2/start"):
			var hand_gap := (ends_of["ss_cut_1/end"][0] as Vector3).distance_to(ends_of["ss_cut_2/start"][0] as Vector3)
			var tip_gap := (ends_of["ss_cut_1/end"][1] as Vector3).distance_to(ends_of["ss_cut_2/start"][1] as Vector3)
			note("side cut 1 ends and side cut 2 begins: the hand %.2f m apart, the blade's tip %.2f m apart" % [hand_gap, tip_gap])
			# Two different files: the hand is on the same side (measured 0.35 m
			# apart, mostly height and reach) and the blade is turned back for the
			# backhand. The blend into the second step, 0.12 s, covers both.
			expect(hand_gap < 0.45, "the_second_cut_begins_with_the_hand_on_the_side_the_first_left_it")
		anim.speed_scale = 1.0
		visual.show_phase(null, "")
		await _wait(0.4)
		# The overhead cut's back and off hand, at its start and its end: how
		# far the chest tips forward, and where the left hand is.
		if anim.has_animation("ss_over"):
			anim.stop(true)
			anim.play("ss_over")
			anim.speed_scale = 0.0
			visual._attack_clip = ""
			var back_rows: Array[String] = []
			var tips_forward: Array[float] = []
			for at_part in [0.0, 0.5, 1.0]:
				anim.seek(minf(CharacterVisual.clip_length("ss_over") * at_part, CharacterVisual.clip_length("ss_over") - 0.001), true)
				await get_tree().process_frame
				await get_tree().process_frame
				var chest_long := ((visual.skeleton().global_transform * visual.skeleton().get_bone_global_pose(visual.skeleton().find_bone("Spine2"))).basis.y).normalized()
				var forward_tip := rad_to_deg(atan2(chest_long.dot(cut_facing), chest_long.y))
				tips_forward.append(forward_tip)
				var left_hand := _bone_global("LeftHand") - visual.global_position
				# How open each joint is: 180 is a straight line through it.
				var hips_up := _bone_global("Hips").y + Player.BODY_HALF_HEIGHT
				var pelvis_long := ((visual.skeleton().global_transform * visual.skeleton().get_bone_global_pose(visual.skeleton().find_bone("Hips"))).basis.y).normalized()
				var bends: Array[String] = []
				for side in ["Left", "Right"]:
					var hip := _bone_global(side + "UpLeg")
					var knee := _bone_global(side + "Leg")
					var ankle := _bone_global(side + "Foot")
					bends.append("%s hip %.0f knee %.0f" % [side.to_lower(),
						rad_to_deg(pelvis_long.angle_to((hip - knee).normalized())),
						rad_to_deg((hip - knee).angle_to(ankle - knee))])
				back_rows.append("at %.0f%%: hips %.2f m up, %s (hip: thigh against the pelvis, 0 = in line; knee: 180 = straight), chest %.0f deg forward, left hand %.2f left / %.2f up / %.2f ahead" % [
					at_part * 100.0, hips_up, ", ".join(bends), forward_tip, -left_hand.dot(cut_right), left_hand.y + Player.BODY_HALF_HEIGHT, left_hand.dot(cut_facing)])
			note("overhead cut, back and off hand: %s" % " | ".join(back_rows))
			# The light cut goes into its blow: the chest ends further forward
			# than it stood with the sword drawn back.

			# How it ends (the pose is still at 100%): which way the chest
			# faces, the right arm and leg, where the two feet stand.
			var chest_basis := (visual.skeleton().global_transform * visual.skeleton().get_bone_global_pose(visual.skeleton().find_bone("Spine2"))).basis.orthonormalized()
			# The chest's own front, from the rest pose (where it faces +Z of
			# the skeleton).
			var chest_front_axis := visual.skeleton().get_bone_global_rest(visual.skeleton().find_bone("Spine2")).basis.orthonormalized().inverse() * Vector3(0.0, 0.0, 1.0)
			var chest_front := chest_basis * chest_front_axis
			var turned_left := rad_to_deg(atan2(-chest_front.dot(cut_right), chest_front.dot(cut_facing)))
			var shoulder_at := _bone_global("RightArm")
			var elbow_at := _bone_global("RightForeArm")
			var wrist_at := _bone_global("RightHand")
			var arm_open := rad_to_deg((shoulder_at - elbow_at).angle_to(wrist_at - elbow_at))
			var arm_down := rad_to_deg((wrist_at - shoulder_at).normalized().angle_to(Vector3.DOWN))
			var right_knee := rad_to_deg((_bone_global("RightUpLeg") - _bone_global("RightLeg")).angle_to(_bone_global("RightFoot") - _bone_global("RightLeg")))
			var right_leg_down := rad_to_deg((_bone_global("RightFoot") - _bone_global("RightUpLeg")).normalized().angle_to(Vector3.DOWN))
			var left_foot := _bone_global("LeftFoot") - visual.global_position
			var right_foot := _bone_global("RightFoot") - visual.global_position
			var apart_ahead := right_foot.dot(cut_facing) - left_foot.dot(cut_facing)
			var apart_side := right_foot.dot(cut_right) - left_foot.dot(cut_right)
			note("overhead cut ends: chest faces %.0f deg to the left of the blow; right arm %.0f deg open at the elbow (180 straight) and %.0f deg off straight down; right knee %.0f, the leg %.0f deg off straight down; right foot %.2f m ahead of the left and %.2f m to its right; hips %.2f m up" % [
				turned_left, arm_open, arm_down, right_knee, right_leg_down, apart_ahead, apart_side, _bone_global("Hips").y + Player.BODY_HALF_HEIGHT])
			# The light cut: a part turn to the left, the arm out ahead, the
			# right foot set down just past the left.
			var hand_ahead := (wrist_at - visual.global_position).dot(cut_facing)
			note("overhead cut ends: sword hand %.2f m ahead, %.2f m up" % [hand_ahead, wrist_at.y + Player.BODY_HALF_HEIGHT])

			# The way back: it starts where the cut ended and ends in the
			# stance -- both feet where the stance has them.
			if anim.has_animation("ss_over_end") and anim.has_animation("ss_idle"):
				var feet_at := {}
				for clip_at: Array in [["ss_over", 1.0], ["ss_over_end", 0.0], ["ss_over_end", 1.0], ["ss_idle", 0.0]]:
					anim.stop(true)
					anim.play(String(clip_at[0]))
					anim.speed_scale = 0.0
					var span := CharacterVisual.clip_length(String(clip_at[0]))
					anim.seek(clampf(span * float(clip_at[1]), 0.0, span - 0.001), true)
					await get_tree().process_frame
					await get_tree().process_frame
					feet_at["%s@%.0f" % clip_at] = [_bone_global("LeftFoot"), _bone_global("RightFoot"), _bone_global("Hips")]
				var joins := 0.0
				var lands := 0.0
				for foot in 2:
					joins = maxf(joins, (feet_at["ss_over@1"][foot] as Vector3).distance_to(feet_at["ss_over_end@0"][foot] as Vector3))
				# Against the stance, with the body's advance taken off: the
				# model's own frame is what both are in, so they compare as
				# they stand.
				for foot in 2:
					lands = maxf(lands, (feet_at["ss_over_end@1"][foot] as Vector3).distance_to(feet_at["ss_idle@0"][foot] as Vector3))
				var right_carried := (feet_at["ss_over_end@0"][1] as Vector3).distance_to(feet_at["ss_over_end@1"][1] as Vector3)
				var left_stepped := (feet_at["ss_over_end@0"][0] as Vector3).distance_to(feet_at["ss_over_end@1"][0] as Vector3)
				note("overhead cut's way back: feet where the cut left them within %.2f m; ends with both feet within %.2f m of the stance's; the right foot is carried back %.2f m under the body (it stays on the ground: the body goes on that far) and the left comes %.2f m forward" % [
					joins, lands, right_carried, left_stepped])
				expect(joins < 0.05, "the_way_back_starts_where_the_cut_ended")
				expect(lands < 0.06, "the_way_back_ends_in_the_stance")
				anim.speed_scale = 1.0
			anim.speed_scale = 1.0
		# The overhead cut's head: how far the face is turned from the way the
		# body faces, in the clip as it is and as it is drawn (the modifier
		# keeps it ahead while this clip is the attack on screen).
		if anim.has_animation("ss_over"):
			var rig := visual.skeleton()
			var head_bone := rig.find_bone("Head")
			# Which way the face points, in the head bone's own axes: in the
			# rest pose it points along the skeleton's +Z.
			var face_axis := rig.get_bone_global_rest(head_bone).basis.orthonormalized().inverse() * Vector3(0.0, 0.0, 1.0)
			var head_drawn := BoneAttachment3D.new()
			head_drawn.bone_name = "Head"
			rig.add_child(head_drawn)
			anim.stop(true)
			anim.play("ss_over")
			anim.speed_scale = 0.0
			visual._attack_clip = "ss_over"
			var over_length := CharacterVisual.clip_length("ss_over")
			var head_rows: Array[String] = []
			var worst_clip := 0.0
			var worst_drawn := 0.0
			for step in 9:
				anim.seek(minf(over_length * float(step) / 8.0, over_length - 0.001), true)
				await get_tree().process_frame
				await get_tree().process_frame
				var in_clip := ((rig.global_transform * rig.get_bone_global_pose(head_bone)).basis.orthonormalized() * face_axis).normalized()
				var as_drawn := (head_drawn.global_transform.basis.orthonormalized() * face_axis).normalized()
				var off_clip := rad_to_deg(in_clip.angle_to(cut_facing))
				var off_drawn := rad_to_deg(as_drawn.angle_to(cut_facing))
				worst_clip = maxf(worst_clip, off_clip)
				worst_drawn = maxf(worst_drawn, off_drawn)
				head_rows.append("%.2fs: %.0f in the clip, %.0f drawn" % [over_length * float(step) / 8.0, off_clip, off_drawn])
			note("overhead cut, the face off straight ahead (deg): %s" % " | ".join(head_rows))
			expect(worst_drawn < 12.0, "the_head_faces_ahead_through_the_overhead_cut")
			note("overhead cut: the face is off straight ahead by at most %.0f deg in the clip itself" % worst_clip)
			head_drawn.queue_free()
			anim.speed_scale = 1.0
			visual.show_phase(null, "")
			await _wait(0.4)
		# The trail's fan against the blade it is drawn for (2026-11-19: a
		# screenshot showed the fan standing on the far side of the body from
		# where the sword had come down). Each cut is played the way a cast
		# plays it; through its swing the blade is sampled every frame, as
		# Player samples it, and Player's own fan is worked out from those
		# samples. The fan's last edge should lie along the blade as it is
		# when the swing ends.
		var probe := Player.new()
		for fan_row: Array in [["ss_cut_1", 0.27, 0.18], ["ss_cut_2", 0.10, 0.18]]:
			var fan_clip := String(fan_row[0])
			if not anim.has_animation(fan_clip):
				continue
			var windup_s := float(fan_row[1])
			var swing_s := float(fan_row[2])
			visual._start_attack(fan_clip, windup_s + swing_s, swing_s)
			await _wait(windup_s)
			visual._enter_strike(swing_s)
			probe._trail_samples.clear()
			var swing_began := Time.get_ticks_usec()
			while float(Time.get_ticks_usec() - swing_began) / 1000000.0 < swing_s:
				await get_tree().process_frame
				probe._trail_samples.append({
					"base": sword.global_position,
					"tip": sword.to_global(Vector3(0.0, 0.0, -CharacterVisual.BLADE_LENGTH * Player.TRAIL_OVERREACH)),
					"at": float(Time.get_ticks_usec() - swing_began) / 1000000.0})
			var fan := probe._trail_fan()
			var tip_now := sword.to_global(Vector3(0.0, 0.0, -CharacterVisual.BLADE_LENGTH * Player.TRAIL_OVERREACH))
			var first_tip: Vector3 = probe._trail_samples[0]["tip"]
			if fan.is_empty():
				note("trail fan for %s: none (%d samples)" % [fan_clip, probe._trail_samples.size()])
				expect(false, "%s_has_a_trail" % fan_clip)
			else:
				var centre: Vector3 = fan["centre"]
				var turned_by := float(fan["turned"])
				var last_edge := centre + ((fan["across"] as Vector3) * cos(turned_by) + (fan["along"] as Vector3) * sin(turned_by)) * float(fan["reach_to"])
				var first_edge := centre + (fan["across"] as Vector3) * float(fan["reach_from"])
				note("trail fan for %s (%d samples): turned %.0f deg; its first edge ends %.2f m from the blade's first tip, its last edge %.2f m from the blade's tip now; tip moved %.2f m in all; fan centre %.2f m up, reach %.2f -> %.2f m" % [
					fan_clip, probe._trail_samples.size(), rad_to_deg(turned_by), first_edge.distance_to(first_tip),
					last_edge.distance_to(tip_now), first_tip.distance_to(tip_now), centre.y + Player.BODY_HALF_HEIGHT,
					float(fan["reach_from"]), float(fan["reach_to"])])
				expect(last_edge.distance_to(tip_now) < 0.35, "the_fan_for_%s_ends_at_the_blade" % fan_clip)
			visual.show_phase(null, "")
			await _wait(0.4)
		probe.free()
		# The dash cut's made clip at its start, at the crouch (where the
		# swing starts) and at its end: where the sword hand and the blade's
		# tip are in the body's own terms, how low the hips are, how far the
		# chest is bent, and whether the feet have stayed where they were.
		if anim.has_animation("ss_dash_cut"):
			var dash_facing := -visual.global_transform.basis.z
			var dash_right := dash_facing.cross(Vector3.UP).normalized()
			var dash_length := CharacterVisual.clip_length("ss_dash_cut")
			var floor_y := 0.0
			var feet_first: Array[Vector3] = []
			var feet_worst := 0.0
			var dash_rows: Array[String] = []
			var hand_rows := {}
			for at_part: float in [0.0, 0.745, 1.0]:
				anim.stop(true)
				anim.play("ss_dash_cut")
				anim.seek(minf(dash_length * at_part, dash_length - 0.001), true)
				await get_tree().process_frame
				await get_tree().process_frame
				var feet_now: Array[Vector3] = [_bone_global("LeftFoot"), _bone_global("RightFoot")]
				if feet_first.is_empty():
					feet_first = feet_now
					floor_y = minf(feet_now[0].y, feet_now[1].y)
				for foot in 2:
					feet_worst = maxf(feet_worst, feet_now[foot].distance_to(feet_first[foot]))
				var middle := _bone_global("Hips")
				var hand_off := _bone_global("RightHand") - middle
				var tip_off := sword.to_global(Vector3(0.0, 0.0, -CharacterVisual.BLADE_LENGTH)) - middle
				var chest_up := (_bone_global("Neck") - middle).normalized()
				hand_rows[at_part] = Vector3(hand_off.dot(dash_right), _bone_global("RightHand").y - floor_y, hand_off.dot(dash_facing))
				dash_rows.append("%.0f%%: hips %.2f up; chest %.0f deg forward; hand %.2f right / %.2f up / %.2f ahead; tip %.2f right / %.2f up / %.2f ahead; elbow %.0f deg" % [
					at_part * 100.0, middle.y - floor_y,
					rad_to_deg(atan2(chest_up.dot(dash_facing), chest_up.y)),
					hand_off.dot(dash_right), _bone_global("RightHand").y - floor_y, hand_off.dot(dash_facing),
					tip_off.dot(dash_right), middle.y + tip_off.y - floor_y, tip_off.dot(dash_facing),
					rad_to_deg((_bone_global("RightArm") - _bone_global("RightForeArm")).angle_to(_bone_global("RightHand") - _bone_global("RightForeArm")))])
			note("dash cut (ss_dash_cut, %.2f s; heights from the ankles): %s" % [dash_length, " | ".join(dash_rows)])
			note("dash cut: the feet move at most %.3f m through the clip" % feet_worst)
			expect(feet_worst < 0.03, "the_dash_cut_keeps_its_feet")
			expect((hand_rows[0.745] as Vector3).x < -0.05, "the_sword_hand_is_at_the_left_side_in_the_crouch")
			expect((hand_rows[1.0] as Vector3).x > 0.35, "the_sword_arm_ends_out_to_the_right")
			anim.stop(true)
		else:
			expect(false, "ss_dash_cut_is_in_the_library")
		# The sword model in the hand: how far the mesh reaches along the
		# blade from the hand and how far behind it (the pommel).
		for node in sword.find_children("*", "MeshInstance3D", true, false):
			var sword_mesh := node as MeshInstance3D
			var box := sword_mesh.get_aabb()
			var far_along := -INF
			var far_behind := INF
			for corner in 8:
				var point := box.position + Vector3(box.size.x * float(corner & 1), box.size.y * float((corner >> 1) & 1), box.size.z * float((corner >> 2) & 1))
				var local := sword.global_transform.affine_inverse() * (sword_mesh.global_transform * point)
				far_along = maxf(far_along, -local.z)
				far_behind = minf(far_behind, -local.z)
			note("sword model %s: reaches %.2f m along the blade from the hand and %.2f m behind it (wanted %.2f and about -0.16); %d vertices" % [
				sword_mesh.name, far_along, far_behind, CharacterVisual.BLADE_LENGTH, sword_mesh.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()])
			expect(absf(far_along - CharacterVisual.BLADE_LENGTH) < 0.05 and far_behind < -0.1 and far_behind > -0.25,
				"the_sword_is_held_by_its_grip_with_the_blade_running_out_from_the_hand")
		# A clip cut out of the middle of a file keeps the model over the body:
		# the hips' first and last keys sit where the file itself begins.
		var off: Array[String] = []
		for clip in ["ss_cut_1", "ss_cut_1_end", "ss_cut_2", "ss_cut_2_end", "ss_dash_cut", "ss_thrust", "ss_thrust_kick"]:
			if not anim.has_animation(clip):
				continue
			var cut := anim.get_animation(clip)
			for track in cut.get_track_count():
				if cut.track_get_type(track) != Animation.TYPE_POSITION_3D \
						or String(cut.track_get_path(track).get_subname(0)) != "Hips":
					continue
				var start: Vector3 = cut.track_get_key_value(track, 0)
				var finish: Vector3 = cut.track_get_key_value(track, cut.track_get_key_count(track) - 1)
				# Model units; the human scale is 1.8 m to the unit.
				var far := maxf(Vector2(start.x, start.z).length(), Vector2(finish.x, finish.z).length()) * 1.8
				off.append("%s %.2f m" % [clip, far])
				# (0.08: a clip out of the middle of a bout stands a few
				# centimetres off where the bout began.)
				expect(far < 0.08, "%s_keeps_the_hips_over_the_body" % clip)
		note("hips off the body's centre, the further of each clip's two ends: %s" % [off])
		# The kick step through its length: how far the chest has turned from
		# where the thrust left it, where the sword hand is, where the blade
		# points and how high the right foot is.
		if anim.has_animation("ss_thrust") and anim.has_animation("ss_thrust_kick"):
			var skeleton := visual.skeleton()
			var chest := skeleton.find_bone("Spine2")
			visual._start_attack("ss_thrust", 0.3)
			await _wait(0.7)
			var chest_at_thrust := (skeleton.global_transform * skeleton.get_bone_global_pose(chest)).basis.orthonormalized()
			var forward := -visual.global_transform.basis.z
			visual._start_attack("ss_thrust_kick", 0.6)
			await _wait(0.3)
			anim.speed_scale = 0.0
			var kick_length := CharacterVisual.clip_length("ss_thrust_kick")
			var rows: Array[String] = []
			for step in 5:
				anim.seek(minf(kick_length * float(step) / 4.0, kick_length - 0.001), true)
				await get_tree().process_frame
				await get_tree().process_frame
				var chest_now := (skeleton.global_transform * skeleton.get_bone_global_pose(chest)).basis.orthonormalized()
				var turned := rad_to_deg(chest_at_thrust.get_rotation_quaternion().angle_to(chest_now.get_rotation_quaternion()))
				var blade := -sword.global_transform.basis.z.normalized()
				rows.append("%d%%: chest %.0f deg from the thrust's, hand %.2f m ahead / %.2f m up, blade pitch %.0f, right foot %.2f m up / %.2f m ahead" % [
					step * 25, turned, (_bone_global("RightHand") - visual.global_position).dot(forward),
					_bone_global("RightHand").y + Player.BODY_HALF_HEIGHT, rad_to_deg(asin(clampf(blade.y, -1.0, 1.0))),
					_bone_global("RightFoot").y + Player.BODY_HALF_HEIGHT, (_bone_global("RightFoot") - visual.global_position).dot(forward)])
			note("kick step: " + " | ".join(rows))
			anim.speed_scale = 1.0
			visual.show_phase(null, "")
			await _wait(0.4)
		if visual._play_stop():
			await get_tree().process_frame
			expect(anim.current_animation == CharacterVisual.clip_for("dash_stop"), "the_dash_stop_plays")
		sword.queue_free()
		visual.preview_armed = false
	await _reset_pose()
	visual._play("idle")


func _seam_gap(clip: String) -> float:
	var anim: AnimationPlayer = visual._anim
	var hand: Node3D = visual._hand
	var length := CharacterVisual.clip_length(clip)
	anim.stop(true)
	anim.play(clip)
	anim.speed_scale = 0.0
	anim.seek(0.0, true)
	await get_tree().process_frame
	await get_tree().process_frame
	var first := hand.global_position
	anim.seek(length - 0.0005, true)
	await get_tree().process_frame
	await get_tree().process_frame
	var last := hand.global_position
	anim.speed_scale = 1.0
	anim.stop(true)
	return first.distance_to(last)


# Steps the attack clip through with the sword on, reading the hand's height
# and the blade's pitch: a vertical cut goes up and comes down.
func _sweep(clip: String) -> void:
	var anim: AnimationPlayer = visual._anim
	var hand: Node3D = visual._hand
	var sword := CharacterVisual.build_weapon_mesh(WeaponKinds.Kind.SWORD)
	visual.attach_weapon(sword)
	var length := CharacterVisual.clip_length(clip)
	anim.stop(true)
	anim.play(clip)
	anim.speed_scale = 0.0
	var rows: Array[String] = []
	var hand_high := -INF
	var hand_low := INF
	var pitch_first := 0.0
	var pitch_last := 0.0
	var pitch_high := -INF
	for index in SAMPLES + 1:
		var t := length * float(index) / float(SAMPLES)
		anim.seek(minf(t, length - 0.0005), true)
		await get_tree().process_frame
		await get_tree().process_frame
		var blade := -sword.global_transform.basis.z.normalized()
		var pitch := rad_to_deg(asin(clampf(blade.y, -1.0, 1.0)))
		var hand_y := hand.global_position.y
		hand_high = maxf(hand_high, hand_y)
		hand_low = minf(hand_low, hand_y)
		pitch_high = maxf(pitch_high, pitch)
		if index == 0:
			pitch_first = pitch
		pitch_last = pitch
		if index % 4 == 0:
			rows.append("t%.2f hand_y%.2f pitch%.0f" % [t, hand_y, pitch])
		if index == 0:
			await _shot("slash_v_start")
		elif index == SAMPLES / 2:
			await _shot("slash_v_mid")
			_look("right_hand")
			await _shot("slash_v_mid_hand")
			_look("front")
			_grip_note("slash_v mid", blade)
		elif index == SAMPLES:
			await _shot("slash_v_end")
			_look("right_hand")
			await _shot("slash_v_end_hand")
			_look("front")
			_grip_note("slash_v end", blade)
	note("slash_v sweep: hand y %.2f..%.2f (range %.2f m), blade pitch first %.0f, highest %.0f, last %.0f; %s" % [
		hand_low, hand_high, hand_high - hand_low, pitch_first, pitch_high, pitch_last, " | ".join(rows)])
	expect(hand_high - hand_low > 0.3, "the_chop_raises_and_drops_the_hand_by_over_30_cm")
	expect(pitch_last < pitch_high - 30.0, "the_blade_comes_down_from_its_highest_pitch")
	anim.speed_scale = 1.0
	anim.stop(true)
	sword.queue_free()
	await get_tree().process_frame


# Where the blade points against the fist's own geometry at this moment: along
# the knuckle row from the pinky to the index (the thumb side, where a hilt's
# blade end leaves a closed fist) and along the thumb. Both near +1 is a
# hammer grip; near -1 is the hilt the other way round.
func _grip_note(label: String, blade: Vector3) -> void:
	if _profile != "tripo":
		return
	var index1 := _bone_global("RightHandIndex1")
	var pinky1 := _bone_global("RightHandPinky1")
	var thumb1 := _bone_global("RightHandThumb1")
	var thumb4 := _bone_global("RightHandThumb4")
	var knuckles := (index1 - pinky1).normalized()
	var thumb := (thumb4 - thumb1).normalized()
	note("%s grip: blade %s . pinky->index = %.2f, . thumb = %.2f; blade pitch %.0f" % [
		label, blade.snapped(Vector3.ONE * 0.01), blade.dot(knuckles), blade.dot(thumb),
		rad_to_deg(asin(clampf(blade.y, -1.0, 1.0)))])


# ------------------------------------------------------------------ 4: the props

func _prop_checks() -> void:
	var anim: AnimationPlayer = visual._anim
	var feet: Array = FEET.get(_profile, [])
	await _reset_pose()
	visual._play("idle")
	await get_tree().process_frame
	anim.speed_scale = 0.0
	anim.seek(0.0, true)
	var sword := CharacterVisual.build_weapon_mesh(WeaponKinds.Kind.SWORD)
	expect(visual.attach_weapon(sword), "the_sword_hangs_off_handslot_r")
	var shield := CharacterVisual.build_weapon_mesh(WeaponKinds.Kind.SHIELD)
	expect(visual.attach_offhand(shield), "the_shield_hangs_off_handslot_l")
	await get_tree().process_frame
	await get_tree().process_frame
	# The slot's axes as Godot has them, in the body's frame (forward is -Z),
	# against the hand's own geometry: the way the knuckles run and the way
	# the fingers point. The blade should leave the fist on the thumb side.
	var skeleton := visual.skeleton()
	var slot_index := skeleton.find_bone(CharacterVisual.HAND_BONE)
	var slot_pose := skeleton.global_transform * skeleton.get_bone_global_pose(slot_index)
	var slot_y := slot_pose.basis.y.normalized()
	var slot_z := slot_pose.basis.z.normalized()
	var blade_now := -sword.global_transform.basis.z.normalized()
	note("handslot.r axes now: +Y %s (blade follows it: %s, dot %.2f), +Z %s" % [
		slot_y.snapped(Vector3.ONE * 0.01), blade_now.snapped(Vector3.ONE * 0.01), slot_y.dot(blade_now), slot_z.snapped(Vector3.ONE * 0.01)])
	if _profile == "tripo":
		var index1 := _bone_global("RightHandIndex1")
		var pinky1 := _bone_global("RightHandPinky1")
		var middle1 := _bone_global("RightHandMiddle1")
		var thumb1 := _bone_global("RightHandThumb1")
		var thumb4 := _bone_global("RightHandThumb4")
		var hand_bone := _bone_global("RightHand")
		var knuckles := (index1 - pinky1).normalized()
		var fingers := (middle1 - hand_bone).normalized()
		var thumb := (thumb4 - thumb1).normalized()
		note("hand geometry now: pinky->index %s, wrist->middle %s, thumb %s; blade . pinky->index = %.2f, blade . thumb = %.2f" % [
			knuckles.snapped(Vector3.ONE * 0.01), fingers.snapped(Vector3.ONE * 0.01), thumb.snapped(Vector3.ONE * 0.01),
			blade_now.dot(knuckles), blade_now.dot(thumb)])
	if feet.size() == 4:
		var forearm := _bone_global(String(feet[2]))
		var hand := _bone_global(String(feet[3]))
		var grip := sword.global_position
		var blade := -sword.global_transform.basis.z.normalized()
		var forearm_dir := (hand - forearm).normalized()
		var tip := grip + blade * CharacterVisual.SWORD_LENGTH
		var body_forward := -visual.global_transform.basis.z
		note("sword: grip %.3f m from the hand bone (%s), blade pitch %.0f deg, %.0f deg off the forearm, %.0f deg off the body's forward; tip at y %.2f (feet at %.2f, head at %.2f)" % [
			grip.distance_to(hand), feet[3], rad_to_deg(asin(clampf(blade.y, -1.0, 1.0))),
			rad_to_deg(acos(clampf(blade.dot(forearm_dir), -1.0, 1.0))),
			rad_to_deg(acos(clampf(blade.dot(body_forward), -1.0, 1.0))),
			tip.y, -Player.BODY_HALF_HEIGHT, Player.BODY_HALF_HEIGHT])
		expect(grip.distance_to(hand) < 0.12, "the_grip_sits_in_the_hand")
		var angle := rad_to_deg(acos(clampf(blade.dot(forearm_dir), -1.0, 1.0)))
		expect(angle > 45.0 and angle < 135.0, "the_blade_crosses_the_forearm_like_a_held_sword")
		var off_hand := _bone_global(String(feet[3]).replace("Right", "Left").replace(".r", ".l"))
		note("shield: %.3f m from the left hand bone" % shield.global_position.distance_to(off_hand))
		expect(shield.global_position.distance_to(off_hand) < 0.12, "the_shield_sits_in_the_left_hand")
	_look("front")
	await _shot("idle_sword_shield_front")
	_look("side")
	await _shot("idle_sword_shield_side")
	_look("right_hand")
	await _shot("idle_sword_hand_closeup")
	_look("three_quarter")
	await _shot("idle_sword_shield_three_quarter")
	_look("front")
	anim.speed_scale = 1.0
	sword.queue_free()
	shield.queue_free()
	await get_tree().process_frame


# ------------------------------------------------------------------ 5: the texture

func _texture_checks() -> void:
	var skeleton := visual.skeleton()
	var found := false
	for node in skeleton.get_children():
		var mesh := node as MeshInstance3D
		if mesh == null:
			continue
		for surface in mesh.mesh.get_surface_count():
			var material := mesh.get_active_material(surface) as BaseMaterial3D
			var texture := material.albedo_texture if material != null else null
			if texture != null:
				found = true
				note("mesh %s surface %d: albedo texture %dx%d (%s), albedo colour %s" % [
					mesh.name, surface, texture.get_width(), texture.get_height(), texture.get_class(), material.albedo_color])
				if _profile == "tripo":
					expect(texture.get_width() == 2048 and texture.get_height() == 2048, "the_tripo_albedo_is_the_2k_texture")
			else:
				note("mesh %s surface %d: no albedo texture (colour %s)" % [mesh.name, surface, material.albedo_color if material != null else "none"])
	expect(found, "the_model_carries_an_albedo_texture")
	await get_tree().process_frame
	var texture_mem := int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED))
	var video_mem := int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED))
	note("vram: texture %.1f MB (+%.1f MB since before the model), video %.1f MB (+%.1f MB); %s" % [
		texture_mem / 1048576.0, (texture_mem - _texture_mem_before) / 1048576.0,
		video_mem / 1048576.0, (video_mem - _video_mem_before) / 1048576.0,
		"measured with a window" if _shots else "headless: the dummy renderer reports 0, not a measurement"])
