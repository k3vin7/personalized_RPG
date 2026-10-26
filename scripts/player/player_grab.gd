class_name PlayerGrab
extends Node

# G picks something up, G throws it. Only the local player runs this.
#
# B-c: this no longer decides anything. The server's hold table says who holds
# what; this reads its own two rows out of that table and does the parts that
# belong to the owner of a body -- entering GRABBING or GRABBED, and carrying
# our own body to the hand we are held in. The approval protocol that used to
# live here (ask the rock's host, ask the grabbed player's machine, trade
# answers, watch each other's state to decide a hold was over) is gone: there
# is one row and it is the server's.

# A force always arrives with, or just after, the row that released us. The two
# are separate messages and the force can be applied one physics step earlier,
# so for this long a stale "you are still held" row is ignored. Without it the
# follower below re-pinned the body and zeroed the recoil it had just been
# given, and an escape read as a push of nothing.
const FREED_GRACE := 0.4

var player: Player

# Both are read from the table, never assigned by this script's own decision.
var held: Node3D
var holder: Player

# One intent at a time: a second G while the first is still in the air would
# ask twice. Nothing answers a refusal, so the mark times out.
var _pending_target: Node3D
var _pending_left := 0.0
# Stage E: the one key's charge, and what carrying something weighs.
var _charging := false
var _charge_left := 0.0
var _freed_left := 0.0


func setup(owner_player: Player) -> void:
	player = owner_player
	set_physics_process(true)


func is_holding() -> bool:
	return is_instance_valid(held)


func is_held() -> bool:
	return player.state == Player.State.GRABBED


func _judge() -> ServerAuthority:
	return ServerAuthority.instance


# DOC: ground only, inside grab_range, and of everything in reach the one
# nearest the cursor. Picking the target is the client's job -- it is the one
# with the cursor -- and whether the hold may start is the server's.
func grab() -> bool:
	if is_holding() or is_held() or not player.is_grounded_state() or is_instance_valid(_pending_target):
		return false
	var judge := _judge()
	if judge == null:
		return false
	# DOC (stage E): the cursor names one thing, and that is the thing the
	# intent carries. Everything holdable is considered here, taken or not,
	# because what matters is what is being aimed at -- and if that thing
	# cannot be picked up, the grab fails. It does not fall through to whatever
	# else is nearby: aiming at a rock someone else had just taken used to pick
	# up the person standing behind it.
	var aim := player.movement.cursor_point()
	var aimed: Node3D = null
	var aimed_score := INF
	for node in player.get_tree().get_nodes_in_group(ServerAuthority.HOLDABLE_GROUP):
		var body := node as Node3D
		if body == null or body == player:
			continue
		var score := Vector2(body.global_position.x - aim.x, body.global_position.z - aim.z).length()
		if score < aimed_score:
			aimed_score = score
			aimed = body
	if aimed == null or aimed_score > Tuning.values.grab_cursor_radius + Player.BODY_RADIUS:
		print("PLAYGROUND_GRAB by=%s nothing_under_the_cursor" % player.name)
		return false
	var offset := aimed.global_position - player.global_position
	offset.y = 0.0
	if offset.length() - Player.BODY_RADIUS > Tuning.values.grab_range:
		print("PLAYGROUND_GRAB by=%s target=%s out_of_reach" % [player.name, aimed.name])
		return false
	if judge.holder_of(aimed) != 0:
		print("PLAYGROUND_GRAB by=%s target=%s already_held" % [player.name, aimed.name])
		return false
	var person := aimed as Player
	if person != null and (person.state == Player.State.GRABBED or person.state == Player.State.DEAD):
		print("PLAYGROUND_GRAB by=%s target=%s not_available" % [player.name, aimed.name])
		return false
	_pending_target = aimed
	_pending_left = ServerAuthority.INTENT_TIMEOUT
	player.begin_predicted(ServerAuthority.Intent.GRAB)
	ServerAuthority.submit_intent(
		player, ServerAuthority.Intent.GRAB, {"target": aimed.get_path()})
	return true


# DOC (stage E): one key. G with something in your hands starts a charge; what
# letting go means depends on how long it was held.
#
#   released before throw_hold_threshold  -> put it down
#   held at least that long               -> an arc, landing where the cursor is
#   shift held as well                    -> a straight line, cursor = heading
#
# The charge runs from the threshold to throw_charge_max and scales how far an
# arc can reach, or how hard a line is thrown. Moving while charging is fine --
# nothing here forbids anything.
func press_throw() -> void:
	if not is_holding():
		return
	_charge_left = 0.0
	_charging = true
	player.begin_predicted(ServerAuthority.Intent.THROW)


func release_throw_key() -> void:
	if not _charging:
		return
	_charging = false
	if not is_holding():
		player.clear_predicted()
		return
	if _charge_left < Tuning.values.throw_hold_threshold:
		# A tap is a put-down.
		ServerAuthority.submit_intent(player, ServerAuthority.Intent.DROP, {})
		return
	var line := Input.is_physical_key_pressed(KEY_SHIFT)
	var charge: float = clampf(
		(_charge_left - Tuning.values.throw_hold_threshold)
			/ maxf(Tuning.values.throw_charge_max - Tuning.values.throw_hold_threshold, 0.01),
		0.0, 1.0)
	ServerAuthority.submit_intent(player, ServerAuthority.Intent.THROW, {
		"direction": throw_direction(),
		"target": player.movement.cursor_jump_target(),
		"charge": charge,
		"line": line,
	})


func charge_seconds() -> float:
	return _charge_left if _charging else 0.0


# Kept for the checks and for anything that wants a throw without the key: a
# full charge, an arc, at the cursor.
func throw() -> bool:
	if not is_holding():
		return false
	player.begin_predicted(ServerAuthority.Intent.THROW)
	var allowed: Variant = ServerAuthority.submit_intent(
		player, ServerAuthority.Intent.THROW, {
			"direction": throw_direction(),
			"target": player.movement.cursor_jump_target(),
			"charge": 1.0,
			"line": false,
		})
	# A client's throw lands a round trip later; the host's is already done.
	return allowed if allowed is bool else true


# The heading only. Where it lands is the target in the payload; this is what a
# straight throw uses and what an arc falls back on with no cursor.
func throw_direction() -> Vector3:
	var flat := player.movement.cursor_direction()
	if flat.length_squared() < 0.01:
		flat = -player.global_transform.basis.z
		flat.y = 0.0
		flat = flat.normalized() if flat.length_squared() > 0.01 else Vector3.FORWARD
	return flat


# Put down rather than thrown. Also an intent: the table is the only thing that
# can end a hold.
func drop() -> void:
	if not is_holding():
		return
	ServerAuthority.submit_intent(player, ServerAuthority.Intent.DROP, {})


# DOC: Space, grabbed_escape_presses times inside grabbed_escape_window. The
# count is kept in the server's table row, not here.
func escape_press() -> void:
	if not is_held():
		return
	player.stamina = maxf(0.0, player.stamina - Tuning.values.stamina_escape_press)
	player.begin_predicted(ServerAuthority.Intent.ESCAPE)
	ServerAuthority.submit_intent(player, ServerAuthority.Intent.ESCAPE, {})


# Leaving GRABBED by any route at all ends up here, death included.
func clear_holder() -> void:
	holder = null
	player.set_overhead_note("")


# 7-6: any force at all frees a held body. The server guarantees it -- every
# force it sends to a held body is preceded by that body's row being erased in
# send_force() -- so a force arriving is proof enough that the hold is over,
# without waiting for the row to confirm it.
func on_force_received() -> void:
	if is_held():
		_freed_left = FREED_GRACE
		_leave_held()


func _leave_held() -> void:
	# Stage E: put down beside whoever was holding us, not dropped from hand
	# height above their head. A body freed over the holder landed back on that
	# head, and the ground step then wiped the recoil it had just been given --
	# which is why the escape push measured nothing at all.
	if is_instance_valid(holder):
		var away := player.global_position - holder.global_position
		away.y = 0.0
		if away.length_squared() < 0.0001:
			# Pinned to the holder's own x and z, so there is no "away" to use:
			# out behind them, the same side the server's recoil pushes.
			away = -holder.global_transform.basis.z
			away.y = 0.0
		if away.length_squared() < 0.0001:
			away = Vector3.FORWARD
		if away.length_squared() > 0.0001:
			away = away.normalized()
			player.global_position = Vector3(
				holder.global_position.x + away.x * Player.BODY_RADIUS * 2.2,
				holder.global_position.y,
				holder.global_position.z + away.z * Player.BODY_RADIUS * 2.2)
	clear_holder()
	player.clear_predicted()
	if player.state == Player.State.GRABBED:
		player.change_state(Player.State.AIRBORNE)


# The owner's half of a hold, and nothing else: follow the table.
func _physics_process(delta: float) -> void:
	if not player.is_local():
		return
	_freed_left = maxf(0.0, _freed_left - delta)
	if _pending_left > 0.0:
		_pending_left -= delta
		if _pending_left <= 0.0:
			# Refused, or the answer was lost. Either way the hand is free to
			# try again rather than staying pending for the rest of the session.
			_pending_target = null

	var judge := _judge()
	if judge == null:
		return

	# Stage E: what we are carrying is part of what we weigh, which is how a
	# heavy load slows the walk and lowers the jump without a rule of its own.
	var load := 0.0
	if is_instance_valid(held):
		load = judge.weight_of(held)
		if is_inf(load):
			load = 0.0
	player.stats.held_weight = load

	if _charging:
		_charge_left += delta
		player.stamina = maxf(0.0, player.stamina
			- Tuning.values.stamina_charge_per_sec * delta)
	elif is_instance_valid(held):
		player.stamina = maxf(0.0, player.stamina
			- Tuning.values.stamina_hold_per_sec * delta)

	var holder_peer := judge.holder_of(player)
	var my_target := judge.held_by(player.get_multiplayer_authority())

	if holder_peer != 0 and _freed_left > 0.0:
		# A force already freed us and the row saying otherwise is still in
		# flight. If the server really does still hold us, the row outlives the
		# grace and the branch below takes over again.
		return

	if holder_peer != 0:
		# Being carried. Our own position is still ours to write, which is why
		# it is written here and not by the server.
		holder = judge.actor_for(holder_peer)
		held = null
		player.clear_predicted()
		if player.state != Player.State.GRABBED:
			if player.climb != null and player.climb.is_climbing():
				player.climb.detach(0.0)
			if player.movement != null:
				player.movement.cancel_target()
			player.change_state(Player.State.GRABBED)
			print("PLAYGROUND_GRABBED peer=%s by=%d" % [player.name, holder_peer])
		if is_instance_valid(holder):
			player.global_position = holder.hand_position()
			player.velocity = Vector3.ZERO
		_show_progress(judge.escape_presses(player))
		return

	if player.state == Player.State.GRABBED:
		# The row is gone: freed, escaped, thrown or the holder let go. The
		# push that goes with it arrives as a force event of its own.
		_leave_held()

	if my_target != null:
		if held != my_target:
			held = my_target
			player.clear_predicted()
			_pending_target = null
			_pending_left = 0.0
			if player.movement != null:
				player.movement.cancel_target()
			print("PLAYGROUND_GRAB by=%s target=%s" % [player.name, my_target.name])
		if player.state != Player.State.GRABBING and player.is_grounded_state():
			player.change_state(Player.State.GRABBING)
		return

	if held != null:
		# The hand emptied: a throw or a put-down has been answered.
		player.clear_predicted()
		_charging = false
		_charge_left = 0.0
		player.stats.held_weight = 0.0
	held = null
	if player.state == Player.State.GRABBING:
		player.change_state(Player.State.IDLE)


func _show_progress(presses: int) -> void:
	if presses <= 0:
		player.set_overhead_note("")
		return
	player.set_overhead_note("탈출 %d/%d" % [presses, int(Tuning.values.grabbed_escape_presses)])
