extends Node

# DK: the dash key, rebound from the panel the way the slot keys are, and the
# rule for a key two things want: the last assignment wins and the other is
# emptied. Local tuning is each peer's own, so both peers run the same
# sequence on their own body and the client reports its count to the host.
#
# Each press goes through Input, so the InputMap decides what it means. With
# the smart key off a slot press arms the slot and the dash key arms the dash,
# so what is read after a press is movement.armed_action().
#
# Also the camera: set_pitch() moved out of _ready() for the blockout scene,
# and the game's view must still sit at the same tilt and offset.

const HOME := Vector3(0.0, 0.9, 11.0)
const CLIENT_HOME := Vector3(-4.0, 0.9, 11.0)
const PRESS_WAIT := 0.3

var _local: Player
var _judge: ServerAuthority
var _peer_id := 0
var _checks := 0
var _failures := 0
var _stage_done := ""
var _client_result := PackedInt32Array()


func expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
	print("DK_CHECK peer=%d %s %s" % [_peer_id, "PASS" if condition else "FAIL", label])


func note(line: String) -> void:
	print("DK_NOTE peer=%d %s" % [_peer_id, line])


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _wait_stage(name_text: String, limit := 25.0) -> bool:
	var waited := 0.0
	while _stage_done != name_text and waited < limit:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	var arrived := _stage_done == name_text
	_stage_done = ""
	return arrived


func _client_peer() -> int:
	var peers := multiplayer.get_peers()
	return peers[0] if peers.size() > 0 else 0


func run(world: Node3D) -> void:
	_peer_id = multiplayer.get_unique_id()
	_local = Net.spawn_root.get_node(str(_peer_id)) as Player
	_judge = world.get_node_or_null("ServerAuthority") as ServerAuthority
	if not multiplayer.is_server():
		stage_done.rpc_id(1, "client_ready")
		return
	expect(await _wait_stage("client_ready"), "both_peers_present")
	await _park(HOME)
	client_run.rpc_id(_client_peer(), CLIENT_HOME)
	await _key_checks()
	await _arc_check()
	await _camera_checks()
	expect(await _wait_stage("client_done", 40.0), "client_finished_its_checks")
	if _client_result.size() == 2:
		note("client: checks=%d failures=%d" % [_client_result[0], _client_result[1]])
		expect(_client_result[1] == 0, "client_had_no_failures")
	print("DK_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	await _wait(1.0)
	get_tree().quit(0 if _failures == 0 else 1)


func _park(at: Vector3) -> void:
	Net.queue_physics(func() -> void:
		if _judge != null:
			if _judge.is_judge():
				_judge.forgive_move(multiplayer.get_unique_id(), "")
			else:
				_judge.harness_forgive_move.rpc_id(1)
		_local.global_position = at
		_local.velocity = Vector3.ZERO
		_local.movement.cancel_target())
	await _wait(0.6)


func _press(physical_keycode: int) -> void:
	var down := InputEventKey.new()
	down.physical_keycode = physical_keycode as Key
	down.pressed = true
	Input.parse_input_event(down)
	var up := InputEventKey.new()
	up.physical_keycode = physical_keycode as Key
	up.pressed = false
	Input.parse_input_event(up)


# Presses a key and says what it armed, then clears it.
func _armed_by(physical_keycode: int) -> String:
	_local.movement.cancel_armed()
	_press(physical_keycode)
	await _wait(PRESS_WAIT)
	var armed: String = PlayerMovement.Armed.keys()[_local.movement.armed_action()]
	_local.movement.cancel_armed()
	return armed


func _events(action: String) -> int:
	return InputMap.action_get_events(action).size()


func _key_checks() -> void:
	Tuning.values.smart_key_enabled = false
	var dash_was := int(Tuning.values.dash_key)
	var slot1_was := _local.skills.key_for(0)
	var slot2_was := _local.skills.key_for(1)
	note("defaults: dash=%s slot1=%s slot2=%s" % [
		_local.movement.dash_key_label(), _local.skills.key_label(0), _local.skills.key_label(1)])
	expect(dash_was == KEY_SHIFT and slot1_was == KEY_Q, "dash_defaults_to_shift_and_slot_1_to_q")
	expect(await _armed_by(KEY_SHIFT) == "DASH", "the_default_dash_key_arms_the_dash")
	expect(await _armed_by(KEY_Q) == "SKILL", "the_default_slot_1_key_arms_the_slot")

	# 1) The dash takes Q: slot 1 is emptied.
	_local.movement.rebind_dash(KEY_Q)
	expect(int(Tuning.values.dash_key) == KEY_Q, "the_dash_rebind_is_stored_in_the_local_tuning")
	expect(_local.skills.key_for(0) == 0, "slot_1_lost_the_key_the_dash_took")
	expect(_events("dash") == 1 and _events("slot_1") == 0, "the_input_map_shows_q_on_the_dash_only")
	expect(_local.skills.key_label(0) == PlayerSkills.EMPTY_KEY_LABEL, "the_emptied_slot_shows_as_empty")
	expect(await _armed_by(KEY_Q) == "DASH", "q_now_arms_the_dash")
	expect(await _armed_by(KEY_SHIFT) == "NONE", "the_old_dash_key_does_nothing")

	# 2) Slot 1 takes Q back: the dash is emptied.
	_local.skills.rebind(0, KEY_Q)
	expect(_local.skills.key_for(0) == KEY_Q, "the_slot_rebind_is_stored")
	expect(int(Tuning.values.dash_key) == 0, "the_dash_lost_the_key_the_slot_took")
	expect(_events("dash") == 0 and _events("slot_1") == 1, "the_input_map_shows_q_on_slot_1_only")
	expect(_local.movement.dash_key_label() == PlayerSkills.EMPTY_KEY_LABEL, "the_emptied_dash_shows_as_empty")
	expect(await _armed_by(KEY_Q) == "SKILL", "q_arms_the_slot_again")
	expect(await _armed_by(KEY_SHIFT) == "NONE", "shift_is_still_nothing_while_the_dash_is_empty")

	# 3) The dash gets its own key again (C, a free key); slot 1 keeps Q.
	_local.movement.rebind_dash(KEY_C)
	expect(_local.skills.key_for(0) == KEY_Q, "giving_the_dash_c_leaves_slot_1_alone")
	expect(await _armed_by(KEY_C) == "DASH", "c_arms_the_dash_again")

	# 4) Two slots, same rule: slot 2 takes Q, slot 1 is emptied.
	_local.skills.rebind(1, KEY_Q)
	expect(_local.skills.key_for(1) == KEY_Q and _local.skills.key_for(0) == 0,
		"a_slot_taking_another_slots_key_empties_that_slot")
	expect(_events("slot_1") == 0 and _events("slot_2") == 1, "the_input_map_agrees")
	# Back to the defaults: slot 1 takes Q (emptying slot 2), slot 2 takes W.
	_local.skills.rebind(0, slot1_was)
	_local.skills.rebind(1, slot2_was)
	_local.movement.rebind_dash(dash_was)
	expect(_local.skills.key_for(0) == slot1_was and _local.skills.key_for(1) == slot2_was
		and int(Tuning.values.dash_key) == dash_was, "the_defaults_are_restored")
	note("after: dash=%s slot1=%s slot2=%s" % [
		_local.movement.dash_key_label(), _local.skills.key_label(0), _local.skills.key_label(1)])

	# 5) The line-throw modifier is C, read while held; Shift (the dash) is not it.
	# (parse_input_event buffers; flushed so the state is read the same frame.)
	var hold := InputEventKey.new()
	hold.physical_keycode = KEY_C
	hold.pressed = true
	Input.parse_input_event(hold)
	Input.flush_buffered_events()
	await get_tree().physics_frame
	var c_held := _local.grab.line_throw_held()
	var lift := InputEventKey.new()
	lift.physical_keycode = KEY_C
	lift.pressed = false
	Input.parse_input_event(lift)
	Input.flush_buffered_events()
	await get_tree().physics_frame
	var c_lifted := _local.grab.line_throw_held()
	hold = InputEventKey.new()
	hold.physical_keycode = KEY_SHIFT
	hold.pressed = true
	Input.parse_input_event(hold)
	Input.flush_buffered_events()
	await get_tree().physics_frame
	var shift_held := _local.grab.line_throw_held()
	lift = InputEventKey.new()
	lift.physical_keycode = KEY_SHIFT
	lift.pressed = false
	Input.parse_input_event(lift)
	Input.flush_buffered_events()
	await get_tree().physics_frame
	_local.movement.cancel_armed()
	note("line throw: C held=%s, lifted=%s, Shift held=%s (key %s)" % [c_held, c_lifted, shift_held, OS.get_keycode_string(PlayerGrab.LINE_THROW_KEY)])
	expect(PlayerGrab.LINE_THROW_KEY == KEY_C and c_held and not c_lifted and not shift_held, "the_line_throw_modifier_is_c_and_not_shift")


# The debug panel's jump arc (the line along the jump the cursor would get)
# is off by default: nothing is drawn while standing.
func _arc_check() -> void:
	await _wait(0.5)
	var arc := get_tree().current_scene.get_node_or_null("JumpArc") as MeshInstance3D
	note("jump arc node: %s visible=%s grounded=%s" % [
		arc != null, arc.visible if arc != null else false, _local.is_grounded_state()])
	expect(arc == null or not arc.visible, "the_jump_arc_preview_is_off_by_default")


func _camera_checks() -> void:
	var cam := _local.camera
	expect(cam != null, "the_local_body_has_its_camera")
	if cam == null:
		return
	# Let the follow settle on a still body.
	await _wait(1.0)
	var pitch := deg_to_rad(QuarterCamera.PITCH_DEGREES)
	var wanted := _local.global_position + Vector3(0.0, sin(pitch), cos(pitch)) * QuarterCamera.DISTANCE
	var gap := cam.global_position.distance_to(wanted)
	note("camera tilt %.2f deg, offset gap %.3f m" % [rad_to_deg(-cam.rotation.x), gap])
	expect(absf(rad_to_deg(-cam.rotation.x) - QuarterCamera.PITCH_DEGREES) < 0.01, "the_game_keeps_its_55_degree_tilt")
	expect(gap < 0.05, "the_camera_sits_at_the_same_offset_as_before")


# --------------------------------------------------------------------- RPCs

@rpc("any_peer", "call_remote", "reliable")
func stage_done(name_text: String) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_stage_done = name_text


@rpc("any_peer", "call_remote", "reliable")
func report_result(values: PackedInt32Array) -> void:
	if multiplayer.is_server() and multiplayer.get_peers().has(multiplayer.get_remote_sender_id()):
		_client_result = values


@rpc("authority", "call_remote", "reliable")
func client_run(home: Vector3) -> void:
	await _park(home)
	await _key_checks()
	await _arc_check()
	await _camera_checks()
	print("DK_RESULT peer=%d checks=%d failures=%d" % [_peer_id, _checks, _failures])
	report_result.rpc_id(1, PackedInt32Array([_checks, _failures]))
	stage_done.rpc_id(1, "client_done")
