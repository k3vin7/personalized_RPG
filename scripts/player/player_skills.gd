class_name PlayerSkills
extends Node

# M-1: the eight slots and the cast flow. Local to the owner, like movement and
# climbing: a slot is a key, and a key is this machine's.
#
# A cast is: key -> (smart key off) show the reach and wait for the left button
# / (on) at once -> CASTING for the windup, during which nothing else may be
# ordered -> the intent goes out -> RECOVERING for the recovery, same lock ->
# IDLE. The shove and the grab go through the same flow with a windup of zero
# and call the entries they always had; the server's rulings for them have not
# moved. New strikes go out as Intent.SKILL and are ruled by the SkillDef.
#
# What a slot holds is decided by the hands: one-hand weapon + off hand = eight
# attacks; an empty off hand gets the bare attacks; no weapon at all is the
# bare four and four empty. The weapon four are the combat stage's, so with a
# weapon they are empty for now.

const SLOT_COUNT := 8
# The slot's InputMap action, by index.
const ACTION_PREFIX := "slot_"
# What the panel shows for a slot (or the dash) whose key was taken away.
const EMPTY_KEY_LABEL := "—"
# How long the strike box is shown.
const STRIKE_SHOW := 0.12

var player: Player
var slots: Array[SkillDef] = []
# The cast in progress.
var _cast_def: SkillDef
var _cast_slot := -1
var _phase_left := 0.0
# What the key armed, for the left button to cast.
var _armed_slot := -1
# Client-side mirror of the cooldowns, by id, as msec. The server rules; this
# only stops a press that would be refused from going out.
var _cooldown_until := {}
# Read by the checks.
var casts_started := 0
var casts_sent := 0
var presses_ignored := 0
# M-7: the wall clock when the last intent went out and when the last windup
# ended on this machine, for the latency notes.
var last_cast_unix := 0.0
var last_fire_unix := 0.0
# M-7: whether the cast in progress already sent its intent (at the start of
# the windup) so _fire() does not send it again.
var _sent_at_start := false
# M-6/M-7: the grab key came up before the hold landed; put it down when it does.
var _drop_when_held_until := 0


func setup(owner_player: Player) -> void:
	player = owner_player
	slots.resize(SLOT_COUNT)
	fill_slots()
	apply_bindings()


# ------------------------------------------------------------- the slots

func fill_slots() -> void:
	for index in SLOT_COUNT:
		slots[index] = null
	var bare: Array[SkillDef] = []
	for id in Skills.BARE_IDS:
		bare.append(Skills.get_def(id))
	var weapon: int = player.weapon
	var one_hand_weapon := weapon != WeaponKinds.Kind.NONE and weapon != WeaponKinds.Kind.SHIELD
	# No weapon, or only a shield in the off hand: the main hand is bare, so the
	# bare four take the first four and the rest stand empty (shield skills are
	# the combat stage's). A one-hand weapon: its four attacks are the combat
	# stage's too, so they stand empty, and the bare four fill the off hand.
	var first := 4 if one_hand_weapon else 0
	for offset in bare.size():
		slots[first + offset] = bare[offset]


func slot_def(index: int) -> SkillDef:
	if index < 0 or index >= SLOT_COUNT:
		return null
	return slots[index]


# Empty, or shut while the hands are full (M-2: only the kick is open then).
# M-6: a hold-and-release skill is the hands themselves -- it is what puts the
# load down or throws it -- so full hands never shut it.
func slot_locked(index: int) -> bool:
	var def := slot_def(index)
	if def == null:
		return true
	if def.input_mode == SkillDef.InputMode.HOLD_RELEASE:
		return false
	if player.grab != null and player.grab.is_holding() and not def.usable_while_holding:
		return true
	return false


func slot_on_cooldown(index: int) -> bool:
	var def := slot_def(index)
	if def == null:
		return false
	return Time.get_ticks_msec() < int(_cooldown_until.get(def.id, 0))


# ------------------------------------------------------------- the keys

func key_for(index: int) -> int:
	var keys: PackedInt32Array = Tuning.values.slot_keys
	return keys[index] if index < keys.size() else 0


func key_label(index: int) -> String:
	var key := key_for(index)
	return OS.get_keycode_string(key) if key != 0 else EMPTY_KEY_LABEL


# Writes this peer's bindings into the InputMap. Called at setup and after a
# rebind; the actions themselves are in project.godot with the defaults.
func apply_bindings() -> void:
	for index in SLOT_COUNT:
		var action := ACTION_PREFIX + str(index + 1)
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		InputMap.action_erase_events(action)
		# 0 is an emptied slot (its key went to the dash or another slot):
		# the action stays, with nothing on it.
		if key_for(index) == 0:
			continue
		var key := InputEventKey.new()
		key.physical_keycode = key_for(index) as Key
		InputMap.action_add_event(action, key)


# Any key for any slot. Stored in LocalTuning, so it is this peer's alone.
# One key, one meaning: the last assignment wins, and whatever held the key
# before (another slot, or the dash) is emptied rather than left to fire too.
func rebind(index: int, physical_keycode: int) -> void:
	if index < 0 or index >= SLOT_COUNT or physical_keycode == 0:
		return
	release_key(physical_keycode)
	if player.movement != null:
		player.movement.release_key(physical_keycode)
	var keys: PackedInt32Array = Tuning.values.slot_keys
	if keys.size() < SLOT_COUNT:
		keys.resize(SLOT_COUNT)
	keys[index] = physical_keycode
	Tuning.values.slot_keys = keys
	apply_bindings()
	Tuning.notify_changed()
	print("PLAYGROUND_SLOT_KEY slot=%d key=%s" % [index + 1, OS.get_keycode_string(physical_keycode)])


# Empties every slot that holds this key, so the caller can take it. Returns
# how many were emptied. Does not notify: the caller's own write does.
func release_key(physical_keycode: int) -> int:
	var keys: PackedInt32Array = Tuning.values.slot_keys
	var released := 0
	for index in keys.size():
		if keys[index] == physical_keycode:
			keys[index] = 0
			released += 1
			print("PLAYGROUND_KEY_RELEASED from=slot_%d key=%s" % [index + 1, OS.get_keycode_string(physical_keycode)])
	if released > 0:
		Tuning.values.slot_keys = keys
		apply_bindings()
	return released


func _unhandled_input(event: InputEvent) -> void:
	if not player.is_local():
		return
	for index in SLOT_COUNT:
		var action := ACTION_PREFIX + str(index + 1)
		if event.is_action_pressed(action):
			Net.queue_physics(func() -> void: press_slot(index))
			get_viewport().set_input_as_handled()
			return
		if event.is_action_released(action):
			# M-6: only a hold-and-release skill reads its key coming up.
			Net.queue_physics(func() -> void: release_slot(index))
			get_viewport().set_input_as_handled()
			return


# ------------------------------------------------------------- the cast

func is_busy() -> bool:
	return player.state == Player.State.CASTING or player.state == Player.State.RECOVERING


func armed_slot() -> int:
	return _armed_slot


func current_def() -> SkillDef:
	return _cast_def


# The key. Nothing is cast from the air, from a wall or from someone's hands;
# the two that used to work from the air (the shove) still do through their
# own keys' old entry, which the checks call directly.
func press_slot(index: int) -> bool:
	var def := slot_def(index)
	if def == null or slot_locked(index) or slot_on_cooldown(index) or is_busy() \
			or player.state == Player.State.DOWNED:
		presses_ignored += 1
		print("PLAYGROUND_SLOT_IGNORED slot=%d why=%s" % [index + 1,
			"empty" if def == null else ("locked" if slot_locked(index) else ("cooldown" if slot_on_cooldown(index) else "busy"))])
		return false
	if not player.is_grounded_state():
		presses_ignored += 1
		print("PLAYGROUND_SLOT_IGNORED slot=%d why=state_%s" % [index + 1, Player.State.keys()[player.state]])
		return false
	if def.input_mode == SkillDef.InputMode.HOLD_RELEASE:
		return _hold_press(def)
	if Tuning.values.smart_key_enabled:
		return cast_slot(index)
	arm(index)
	return true


# M-6: the press of a hold-and-release skill. With empty hands it is the
# request (the grab, through the same entry the key always had, which also
# asks the stands and the rack); with something in hand it starts the charge
# the release will read. No arming, no left button, no windup.
func _hold_press(def: SkillDef) -> bool:
	if player.movement == null:
		return false
	casts_started += 1
	player.begin_predicted(def.server_intent())
	var acted := player.movement.interact()
	if acted:
		casts_sent += 1
	else:
		player.clear_predicted()
	return acted


# M-6: the key coming up. Only a hold-and-release skill cares: under the
# threshold the load is put down, over it thrown in an arc, with Shift held
# thrown in a line. Everything about that is PlayerGrab's already.
func release_slot(index: int) -> bool:
	var def := slot_def(index)
	if def == null or def.input_mode != SkillDef.InputMode.HOLD_RELEASE:
		return false
	if player.grab == null:
		return false
	# M-7: the key came up while the grab was still being answered (a catch
	# that lifts, a round trip later): the hold is put down the moment it
	# lands, so a tap catches without carrying.
	if not player.grab.is_holding() and player.grab.has_pending():
		_drop_when_held_until = Time.get_ticks_msec() + int(ServerAuthority.INTENT_TIMEOUT * 1000.0)
	player.grab.release_throw_key()
	return true


func arm(index: int) -> void:
	_armed_slot = index
	if player.movement != null:
		player.movement.arm_skill(index)


func disarm() -> void:
	_armed_slot = -1


# The left button, with a slot armed.
func cast_armed() -> bool:
	if _armed_slot < 0:
		return false
	var index := _armed_slot
	_armed_slot = -1
	return cast_slot(index)


func cast_slot(index: int) -> bool:
	var def := slot_def(index)
	if def == null or slot_locked(index) or slot_on_cooldown(index) or is_busy() or not player.is_grounded_state():
		presses_ignored += 1
		return false
	if player.movement != null:
		player.movement.cancel_target()
		player.movement.cancel_armed()
	_cast_def = def
	_cast_slot = index
	casts_started += 1
	# Shown on the frame of the press, taken back if the server says no.
	player.begin_predicted(def.server_intent())
	# M-7: a strike's intent goes out now, at the start of the windup, aimed
	# now; the server books the ruling for the impact time. The shove and the
	# grab keep their own entries, called when the (zero) windup ends.
	_sent_at_start = false
	if def.server_intent() == ServerAuthority.Intent.SKILL:
		var heading := player.movement.shove_direction() if player.movement != null else -player.global_transform.basis.z
		if heading != Vector3.ZERO:
			player.snap_facing(heading)
		ServerAuthority.submit_intent(player, ServerAuthority.Intent.SKILL, {
			"skill": def.id,
			"direction": heading,
		})
		last_cast_unix = Time.get_unix_time_from_system()
		_sent_at_start = true
	var windup := def.value("windup")
	if windup > 0.0:
		_phase_left = windup
		player.change_state(Player.State.CASTING)
		player.show_skill_phase(def, "windup")
	else:
		_fire()
	return true


# The ruling goes out. Aimed now, not at the press: the windup is the time the
# aim can still move.
func _fire() -> void:
	var def := _cast_def
	if def == null:
		return
	var direction := player.movement.shove_direction() if player.movement != null else -player.global_transform.basis.z
	if direction != Vector3.ZERO and not _sent_at_start:
		player.snap_facing(direction)
	match def.id:
		"shove":
			if player.movement != null:
				player.movement.shove()
		"grab":
			if player.movement != null:
				player.movement.interact()
		_:
			if not _sent_at_start:
				ServerAuthority.submit_intent(player, ServerAuthority.Intent.SKILL, {
					"skill": def.id,
					"direction": direction,
				})
	casts_sent += 1
	last_fire_unix = Time.get_unix_time_from_system()
	var cooldown := def.value("cooldown")
	if cooldown > 0.0:
		_cooldown_until[def.id] = Time.get_ticks_msec() + int(cooldown * 1000.0)
	player.show_skill_phase(def, "strike")
	var recovery := def.value("recovery")
	if recovery > 0.0:
		_phase_left = recovery
		player.change_state(Player.State.RECOVERING)
	else:
		_finish()


func _finish() -> void:
	var def := _cast_def
	_cast_def = null
	_cast_slot = -1
	player.show_skill_phase(null, "")
	if def != null and def.value("recovery") > 0.0 and player.state == Player.State.RECOVERING:
		player.change_state(Player.State.IDLE)
	elif player.state == Player.State.CASTING:
		player.change_state(Player.State.IDLE)


# The body was taken out of the cast by something else: a stun, a grab, a
# death, a fall. The picture goes with it.
func on_interrupted() -> void:
	if _cast_def == null and _armed_slot < 0:
		return
	_cast_def = null
	_cast_slot = -1
	_armed_slot = -1
	_phase_left = 0.0
	player.show_skill_phase(null, "")
	player.clear_predicted()


func _physics_process(delta: float) -> void:
	if not player.is_local():
		return
	if _drop_when_held_until > 0:
		if Time.get_ticks_msec() > _drop_when_held_until:
			_drop_when_held_until = 0
		elif player.grab != null and player.grab.is_holding():
			_drop_when_held_until = 0
			player.grab.drop()
	if _cast_def == null:
		return
	if player.state == Player.State.CASTING:
		_phase_left -= delta
		if _phase_left <= 0.0:
			_fire()
	elif player.state == Player.State.RECOVERING:
		_phase_left -= delta
		if _phase_left <= 0.0:
			_finish()
