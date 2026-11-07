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
	await _model_checks()
	await _track_checks()
	await _clip_checks()
	await _prop_checks()
	await _texture_checks()
	print("TRIPO_RESULT profile=%s checks=%d failures=%d shots=%s" % [_profile, _checks, _failures, _shots])
	await _wait(0.2)
	get_tree().quit(0 if _failures == 0 else 1)


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
