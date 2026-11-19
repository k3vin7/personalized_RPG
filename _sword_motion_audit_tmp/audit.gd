extends "res://scripts/tests/tripo_visual_test.gd"

var actor: Player
var weapon: Node3D
var anim: AnimationPlayer


func _ready() -> void:
	_shots = DisplayServer.get_name() != "headless"
	_build_stage()
	_camera.position = Vector3(-2.6, 0.35, -3.35)
	_camera.look_at(Vector3(0, 0.05, 0))
	_camera.make_current()
	await get_tree().process_frame
	actor = preload("res://scenes/player.tscn").instantiate() as Player
	actor.set_multiplayer_authority(2)
	add_child(actor)
	actor.set_physics_process(false)
	actor._label.visible = false
	visual = actor.visual
	anim = visual._anim
	actor._apply_weapon(WeaponKinds.Kind.SWORD)
	weapon = actor._weapon_node
	var upper := visual._upper
	for index in 4:
		await _wait(0.05 if index == 0 else 0.24)
		print("REVIEW draw t=%.2f visible=%s" % [upper.current_animation_position, weapon.is_visible_in_tree()])
		await _capture("draw_%02d" % index)
	await _wait(0.65)
	visual.set_process(false)
	for key: String in ["idle", "walk", "run", "jump", "overhead_cut", "side_cut", "side_cut_2", "side_cut_3", "thrust", "thrust_2", "parry"]:
		await _sample_clip(key)
	visual.set_process(true)
	actor._apply_weapon(WeaponKinds.Kind.NONE)
	await _wait(0.05)
	print("REVIEW sheathe at %.2fs hand sword valid=%s, torso clip=%s" % [upper.current_animation_position, is_instance_valid(weapon), upper.current_animation])
	await _capture("sheathe_00")
	await _wait(0.55)
	await _capture("sheathe_01")
	await _wait(0.55)
	await _capture("sheathe_02")
	print("REVIEW_DONE")
	get_tree().quit()


func _capture(id: String) -> void:
	if _shots:
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("res://_sword_motion_audit_tmp/" + id + ".png")


func _sample_clip(key: String) -> void:
	actor.show_skill_phase(null, "")
	anim.stop(true)
	var skill := Skills.for_holder(key, actor.weapon, actor.offhand)
	var clip := visual.clip_now(key)
	var active_from := 0.0
	if skill != null:
		actor.show_skill_phase(skill, "windup")
		clip = visual._attack_clip
		var windup := skill.value("windup")
		active_from = windup / maxf(windup + skill.swing_time(), 0.001)
	else:
		visual._play(key)
	var length := visual.clip_length(clip)
	if length <= 0.0:
		print("REVIEW ", key, " missing")
		return
	anim.speed_scale = 0.0
	var first := Vector3.ZERO
	var last := Vector3.ZERO
	var tip_min := INF
	var furthest := -INF
	var furthest_at := 0.0
	for index in 25:
		var fraction := float(index) / 24
		anim.seek(minf(length * fraction, length - 0.0005), true)
		await get_tree().process_frame
		await get_tree().process_frame
		visual._aim_grip(1.0)
		var blade := -weapon.global_basis.z.normalized()
		var tip := weapon.global_position + (blade * CharacterVisual.SWORD_LENGTH)
		tip_min = minf(tip_min, tip.y + Player.BODY_HALF_HEIGHT)
		if -tip.z > furthest:
			furthest = -tip.z
			furthest_at = fraction
		if index == 0:
			first = tip
		last = tip
		if index % 4 == 0:
			await _capture("%s_%02d" % [key, index])
	print("REVIEW %s clip=%s length=%.3fs active_from=%.0f%% seam=%.3fm min_tip_floor=%.3fm furthest_forward_at=%.0f%% final_tip=%s" % [
		key, clip, length, active_from * 100, first.distance_to(last), tip_min, furthest_at * 100, last])
