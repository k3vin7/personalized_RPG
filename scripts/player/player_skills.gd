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
# C-1b: the parries the server answered. (What the casts cost is the
# server's count: ServerAuthority.stamina_spent_by.)
var parries_won := 0
var parries_lost := 0
# C-1c: the raised shield. The key holds it up; the server keeps its own
# record (Intent.BLOCK on/off) and rules every blow against that.
var _block_def: SkillDef
var _blocking := false
var _block_recovery_left := 0.0
var blocks_started := 0
var blocks_broken := 0
# C-1c: a cast from the air (the shield slam): the intent is out, the body
# stays AIRBORNE, and the swing is shown when the windup would have ended.
var _air_cast_left := 0.0
var _air_cast_def: SkillDef
# C-1d: how many intents went out claiming a dash combo.
var combos_claimed := 0
# 2026-11-18: the combo chain: the slot's skill it belongs to, the step a
# press casts next, and until when. Read by the checks: steps cast.
var _chain_slot_id := ""
var _chain_next := ""
var _chain_until_msec := 0
var combo_steps_cast := 0
# The slot pressed again while its cast was still going: the next step is
# owed, and follows the moment this one's swing is through.
var _buffered_slot := -1
# The step the server has said is open (a combo_needs_hit cast that landed).
var _combo_open := ""
var presses_buffered := 0
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
	var one_hand_weapon := weapon != WeaponKinds.Kind.NONE and not Weapons.is_off_hand(weapon)
	# No weapon, or only a shield in the off hand: the main hand is bare, so the
	# bare four take the first four and the rest stand empty (shield skills are
	# C-1c's). A one-hand weapon: its WeaponDef's skill_ids take the first
	# four (C-1b: the sword's; a weapon with none yet leaves them empty), and
	# the bare four fill the off hand.
	# C-1c: the off hand. A shield there takes slots 5-8 with its four; an
	# empty off hand beside a weapon gets the bare four; bare + nothing is
	# the bare four and four empty.
	var shield: int = player.offhand
	var first := 4 if one_hand_weapon else 0
	if not (one_hand_weapon and shield != WeaponKinds.Kind.NONE):
		for offset in bare.size():
			slots[first + offset] = bare[offset]
	if one_hand_weapon:
		var def := Weapons.def_for_kind(weapon)
		if def != null:
			for offset in mini(def.skill_ids.size(), 4):
				slots[offset] = Skills.for_holder(def.skill_ids[offset], weapon, shield)
	if shield != WeaponKinds.Kind.NONE:
		var off := Weapons.def_for_kind(shield)
		if off != null:
			for offset in mini(off.skill_ids.size(), 4):
				slots[4 + offset] = Skills.for_holder(off.skill_ids[offset], weapon, shield)


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
	if player.is_mounted():
		# Riding: a skill key casts nothing and gets the body off the horse.
		if player.movement != null:
			player.movement.dismount_for_skill()
		return false
	# 2026-11-18: the same slot again while its cast is still going asks for
	# the next step of its combo. Remembered, not cast: it follows this one.
	if is_busy() and index == _cast_slot and _cast_def != null and _cast_def.combo_next != "":
		if _buffered_slot != index:
			presses_buffered += 1
		_buffered_slot = index
		return true
	var def := slot_def(index)
	if def == null or slot_locked(index) or slot_on_cooldown(index) or is_busy() \
			or player.state == Player.State.DOWNED:
		presses_ignored += 1
		print("PLAYGROUND_SLOT_IGNORED slot=%d why=%s" % [index + 1,
			"empty" if def == null else ("locked" if slot_locked(index) else ("cooldown" if slot_on_cooldown(index) else "busy"))])
		return false
	if not player.is_grounded_state() and not _airborne_cast_allowed(def):
		presses_ignored += 1
		print("PLAYGROUND_SLOT_IGNORED slot=%d why=state_%s" % [index + 1, Player.State.keys()[player.state]])
		return false
	if def.input_mode == SkillDef.InputMode.HOLD_BLOCK:
		return _block_press(def)
	# C-1c: any other key brings the shield down first.
	if _blocking:
		end_block()
	if def.input_mode == SkillDef.InputMode.HOLD_RELEASE:
		return _hold_press(def)
	# C-1b: a skill with no range to show (the parry, the shield raise) casts
	# on the press whatever the smart key says: there is nothing to aim.
	if Tuning.values.smart_key_enabled or not def.shows_range():
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
# threshold the load is put down, over it thrown in an arc, with C held
# thrown in a line. Everything about that is PlayerGrab's already.
func release_slot(index: int) -> bool:
	var def := slot_def(index)
	if def != null and def.input_mode == SkillDef.InputMode.HOLD_BLOCK:
		if _blocking and _block_def == def:
			end_block()
			return true
		return false
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
	if def == null or slot_locked(index) or slot_on_cooldown(index) or is_busy() \
			or (not player.is_grounded_state() and not _airborne_cast_allowed(def)):
		presses_ignored += 1
		return false
	# 2026-11-18: inside the combo window the slot casts its next step.
	def = _chain_step(def)
	if _blocking:
		end_block()
	# C-1c: from the air the intent goes out and the body stays in the air;
	# the server books the impact as for any strike, and the swing is shown
	# when the windup would have ended. No recovery lock: the landing is one.
	if not player.is_grounded_state():
		var air_cost := def.value("stamina_cost")
		if air_cost > 0.0 and player.stamina <= 0.0:
			presses_ignored += 1
			return false
		if player.movement != null:
			player.movement.cancel_armed()
		var air_heading := player.movement.shove_direction() if player.movement != null else -player.global_transform.basis.z
		if air_heading == Vector3.ZERO:
			air_heading = -player.global_transform.basis.z
		casts_started += 1
		ServerAuthority.submit_intent(player, ServerAuthority.Intent.SKILL, _combo_payload(def, {
			"skill": def.id,
			"direction": air_heading,
		}))
		casts_sent += 1
		last_cast_unix = Time.get_unix_time_from_system()
		_air_cast_def = def
		_air_cast_left = def.value("windup")
		var air_cooldown := def.value("cooldown")
		if air_cooldown > 0.0:
			_cooldown_until[def.id] = Time.get_ticks_msec() + int((def.value("windup") + air_cooldown) * 1000.0)
		print("PLAYGROUND_AIR_CAST peer=%s skill=%s" % [player.name, def.id])
		return true
	# C-1b: the stamina column. An empty pool refuses the cast here, off the
	# replica; the server refuses the intent the same way and (C-1b') takes
	# the cost off its own copy, which is the one every screen shows.
	var cost := def.value("stamina_cost")
	if cost > 0.0 and player.stamina <= 0.0:
		presses_ignored += 1
		print("PLAYGROUND_SLOT_IGNORED slot=%d why=no_stamina" % [index + 1])
		return false
	if player.movement != null:
		player.movement.cancel_target()
		player.movement.cancel_armed()
	_cast_def = def
	_cast_slot = index
	_buffered_slot = -1
	_combo_open = ""
	casts_started += 1
	# Shown on the frame of the press, taken back if the server says no.
	player.begin_predicted(def.server_intent())
	# M-7: a strike's intent goes out now, at the start of the windup, aimed
	# now; the server books the ruling for the impact time. The shove and the
	# grab keep their own entries, called when the (zero) windup ends.
	_sent_at_start = false
	var heading := player.movement.shove_direction() if player.movement != null else -player.global_transform.basis.z
	if def.server_intent() == ServerAuthority.Intent.SKILL:
		if heading != Vector3.ZERO:
			player.snap_facing(heading)
		ServerAuthority.submit_intent(player, ServerAuthority.Intent.SKILL, _combo_payload(def, {
			"skill": def.id,
			"direction": heading,
		}))
		last_cast_unix = Time.get_unix_time_from_system()
		_sent_at_start = true
	# 2026-11-04: the walk stops on the press, and the skill's own step (if
	# it has one) goes toward the aim over the windup and the swing. After
	# the intent, so the speed the server reads at the intent (the thrust's
	# C-1b bonus) is the speed the body was pressed at, not the stop.
	if player.movement != null:
		var cast_time := def.value("windup") + def.swing_time()
		player.movement.begin_cast_step(heading, def.step_distance, cast_time, def.step_from, def.step_to)
		if def.recovery_step > 0.0:
			# On through the recovery: from where the cast's own step ends
			# to the end of the recovery, starting a moment after the blow
			# (the picture holds it for 0.05 s before the body goes on).
			var after := maxf(def.value("windup") + def.value("recovery") - cast_time * def.step_to, 0.05)
			player.movement.queue_cast_step(heading, def.recovery_step, after,
				clampf((cast_time * (1.0 - def.step_to) + 0.08) / after, 0.0, 0.9), 1.0)
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


# ------------------------------------------------------------ the combo steps

# The step a press of this slot casts now: the next one while the window the
# last step opened is still open, the slot's own otherwise. The owner's own
# clock; the server keeps the same chain on its own and refuses a step out
# of turn.
func _chain_step(slot_skill: SkillDef) -> SkillDef:
	if _chain_next == "":
		return slot_skill
	if _chain_slot_id != slot_skill.id or Time.get_ticks_msec() > _chain_until_msec:
		_chain_next = ""
		return slot_skill
	var step := Skills.for_holder(_chain_next, player.weapon, player.offhand)
	if step == null:
		_chain_next = ""
		return slot_skill
	combo_steps_cast += 1
	return step


# A cast has ended: the window for its next step opens, or the chain is over.
# With combo_window 0 (the default) nothing opens: the next step has to be
# asked for while this one is still going (_chain_on).
func _note_chain(def: SkillDef) -> void:
	if def == null or def.combo_next == "" or Tuning.server.combo_window <= 0.0 \
			or (def.combo_needs_hit and _combo_open != def.combo_next):
		_chain_next = ""
		return
	_chain_slot_id = def.combo_of if def.combo_of != "" else def.id
	_chain_next = def.combo_next
	_chain_until_msec = Time.get_ticks_msec() + int(Tuning.server.combo_window * 1000.0)


# The slot was pressed again during this cast and its swing is through: the
# next step starts now, out of the pose this one ended in. No recovery, and
# the picture is not sent back to standing in between.
func _chain_on() -> void:
	var index := _cast_slot
	var def := _cast_def
	_buffered_slot = -1
	_chain_slot_id = def.combo_of if def.combo_of != "" else def.id
	_chain_next = def.combo_next
	_chain_until_msec = Time.get_ticks_msec() + 100
	_cast_def = null
	_cast_slot = -1
	if player.movement != null:
		player.movement.cancel_cast_step()
	player.change_state(Player.State.IDLE)
	if not cast_slot(index):
		# Refused here (no stamina, the hands changed): it ends as any cast.
		_chain_next = ""
		player.show_skill_phase(null, "")


func _owes_next_step() -> bool:
	if _cast_def == null or _buffered_slot != _cast_slot or _cast_def.combo_next == "":
		return false
	# A step that needs a hit waits for the server's word that it landed. If
	# the word has not come by the end of the recovery the cast just ends.
	return not _cast_def.combo_needs_hit or _combo_open == _cast_def.combo_next


# Server -> owner: this cast's blow landed on a body, so its next step is open.
func on_combo_open(next_id: String) -> void:
	_combo_open = next_id


func _finish() -> void:
	if _owes_next_step():
		_chain_on()
		return
	var def := _cast_def
	_note_chain(def)
	_cast_def = null
	_cast_slot = -1
	if player.movement != null:
		player.movement.cancel_cast_step()
	player.show_skill_phase(null, "")
	if def != null and def.value("recovery") > 0.0 and player.state == Player.State.RECOVERING:
		player.change_state(Player.State.IDLE)
	elif player.state == Player.State.CASTING:
		player.change_state(Player.State.IDLE)


# ------------------------------------------------------------ C-1c: the block

func is_blocking() -> bool:
	return _blocking


func block_recovery_left() -> float:
	return _block_recovery_left


# The press: the shield comes up, and the server is told so it can rule the
# blows that follow. Refused on this machine where the server would refuse
# it too: busy, off the ground, in the raise's recovery, or (the replica's
# word) a pool under the fraction a broken block waits for.
func _block_press(def: SkillDef) -> bool:
	if _blocking or is_busy() or _block_recovery_left > 0.0 or not player.is_grounded_state():
		presses_ignored += 1
		print("PLAYGROUND_SLOT_IGNORED slot=block why=%s" % ("blocking" if _blocking else ("busy" if is_busy() else "recovery")))
		return false
	# An empty pool cannot raise it; the lockout after a break is the
	# server's, which refuses the intent and that brings the shield down.
	if player.stamina <= 0.0:
		presses_ignored += 1
		print("PLAYGROUND_SLOT_IGNORED slot=block why=stamina")
		return false
	_blocking = true
	_block_def = def
	blocks_started += 1
	if player.movement != null:
		player.movement.cancel_armed()
	ServerAuthority.submit_intent(player, ServerAuthority.Intent.BLOCK, {"on": true})
	player.show_block(true)
	return true


# The release, or anything that takes the shield down: a cast, a fall, the
# server breaking it. The raise's recovery (후딜 0.1) runs from here.
func end_block() -> void:
	if not _blocking:
		return
	_blocking = false
	_block_def = null
	_block_recovery_left = Tuning.server.shield_raise_recovery
	ServerAuthority.submit_intent(player, ServerAuthority.Intent.BLOCK, {"on": false})
	player.show_block(false)


# C-1c: the server's word: the block broke (the pool hit 0) or was refused.
func on_block_result(raised: bool) -> void:
	if raised or not _blocking:
		return
	blocks_broken += 1
	_blocking = false
	_block_def = null
	_block_recovery_left = Tuning.server.shield_raise_recovery
	player.show_block(false)
	print("PLAYGROUND_BLOCK_BROKEN peer=%s" % player.name)


# C-1c: a skill that may be cast from the air, while the body is in it.
# C-1d: and a combo skill from a dash, while the body is dashing.
func _airborne_cast_allowed(def: SkillDef) -> bool:
	if def == null:
		return false
	if def.usable_airborne and player.state == Player.State.AIRBORNE:
		return true
	return def.dash_combo and player.state == Player.State.DASH


# C-1d: the combo's gap, when this press is one: the owner's own time since
# its dash started, inside the window. Carried on the intent; the server
# rules on it.
func _combo_payload(def: SkillDef, payload: Dictionary) -> Dictionary:
	if def.dash_combo and player.movement != null:
		var gap := player.movement.seconds_since_dash()
		if gap >= 0.0 and gap <= Tuning.server.dash_combo_window:
			payload["dash_gap"] = gap
			combos_claimed += 1
	return payload


# C-1b: the server's word on a parry. A success ends the recovery now (the
# recovery was the failed parry's cost); a failure changes nothing.
func on_parry_result(success: bool) -> void:
	if success:
		parries_won += 1
		if _cast_def != null and _cast_def.id == "parry" and player.state == Player.State.RECOVERING:
			var parry := _cast_def
			_finish()
			# Shown after the cast has ended, on the stamp every screen replays.
			player.show_skill_phase(parry, "parried")
	else:
		parries_lost += 1


# The body was taken out of the cast by something else: a stun, a grab, a
# death, a fall. The picture goes with it.
func on_interrupted() -> void:
	if _cast_def == null and _armed_slot < 0:
		return
	_cast_def = null
	_cast_slot = -1
	_armed_slot = -1
	_chain_next = ""
	_buffered_slot = -1
	_phase_left = 0.0
	if player.movement != null:
		player.movement.cancel_cast_step()
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
	# C-1c: the raise's recovery, and a block that cannot stand (the body
	# left the ground, was stunned, died).
	_block_recovery_left = maxf(0.0, _block_recovery_left - delta)
	if _blocking and (not player.is_grounded_state() or player.sync_dead or player.state == Player.State.DEAD):
		end_block()
	if _air_cast_def != null:
		_air_cast_left -= delta
		if _air_cast_left <= 0.0:
			player.show_skill_phase(_air_cast_def, "strike")
			_air_cast_def = null
			player.show_skill_phase(null, "")
	if _cast_def == null:
		return
	if player.state == Player.State.CASTING:
		_phase_left -= delta
		if _phase_left <= 0.0:
			_fire()
	elif player.state == Player.State.RECOVERING:
		_phase_left -= delta
		# A step that is owed follows once this swing is through.
		if _owes_next_step() and _cast_def.value("recovery") - _phase_left >= _cast_def.swing_time():
			_chain_on()
		elif _phase_left <= 0.0:
			_finish()
