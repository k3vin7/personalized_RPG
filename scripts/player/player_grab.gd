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
	var aim := player.movement.cursor_point()
	var best: Node3D = null
	var best_score := INF
	for candidate in _candidates():
		var offset := candidate.global_position - player.global_position
		offset.y = 0.0
		if offset.length() - Player.BODY_RADIUS > Tuning.values.grab_range:
			continue
		var score := Vector2(candidate.global_position.x - aim.x, candidate.global_position.z - aim.z).length()
		if score < best_score:
			best_score = score
			best = candidate
	if best == null:
		print("PLAYGROUND_GRAB by=%s none_in_reach" % player.name)
		return false
	_pending_target = best
	_pending_left = ServerAuthority.INTENT_TIMEOUT
	ServerAuthority.submit_intent(
		player, ServerAuthority.Intent.GRAB, {"target": best.get_path()})
	return true


# Everything holdable that is not already held, by the table's word.
func _candidates() -> Array[Node3D]:
	var found: Array[Node3D] = []
	var judge := _judge()
	if judge == null:
		return found
	for node in player.get_tree().get_nodes_in_group(ServerAuthority.HOLDABLE_GROUP):
		var body := node as Node3D
		if body == null or body == player or judge.holder_of(body) != 0:
			continue
		var person := body as Player
		if person != null and (person.state == Player.State.GRABBED or person.state == Player.State.DEAD):
			continue
		# Scarecrows join the table in B-c but are not grabbable until stage E
		# puts them on this list.
		if body is Dummy:
			continue
		found.append(body)
	return found


# DOC: direction is the cursor's heading, tilted up by throw_up_angle_deg.
func throw() -> bool:
	if not is_holding():
		return false
	var direction := throw_direction()
	if direction == Vector3.ZERO:
		return false
	var allowed: Variant = ServerAuthority.submit_intent(
		player, ServerAuthority.Intent.THROW, {"direction": direction})
	# A client's throw lands a round trip later; the host's is already done.
	return allowed if allowed is bool else true


func throw_direction() -> Vector3:
	var flat := player.movement.cursor_direction()
	if flat.length_squared() < 0.01:
		flat = -player.global_transform.basis.z
		flat.y = 0.0
		flat = flat.normalized() if flat.length_squared() > 0.01 else Vector3.FORWARD
	var angle := deg_to_rad(Tuning.values.throw_up_angle_deg)
	return (flat * cos(angle) + Vector3.UP * sin(angle)).normalized()


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
	clear_holder()
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
			_pending_target = null
			_pending_left = 0.0
			if player.movement != null:
				player.movement.cancel_target()
			print("PLAYGROUND_GRAB by=%s target=%s" % [player.name, my_target.name])
		if player.state != Player.State.GRABBING and player.is_grounded_state():
			player.change_state(Player.State.GRABBING)
		return

	held = null
	if player.state == Player.State.GRABBING:
		player.change_state(Player.State.IDLE)


func _show_progress(presses: int) -> void:
	if presses <= 0:
		player.set_overhead_note("")
		return
	player.set_overhead_note("탈출 %d/%d" % [presses, int(Tuning.values.grabbed_escape_presses)])
