class_name PlayerGrab
extends Node

# G picks something up, G throws it. Only the local player runs this.
#
# Both sides of a hold watch each other's replicated state rather than trading
# release messages: the holder checks that what it is holding is still GRABBED,
# the held body checks that its holder is still GRABBING, and either one letting
# go is enough. That covers the holder being stunned, thrown, killed or
# disconnected without a case for each.

# How long after taking hold before that mutual check is enforced. The two
# states are set a round trip apart, so without it every grab would cancel
# itself on the frame it was approved.
const HOLD_GRACE := 0.6
const ESCAPE_PUSH := 4.0

var player: Player

# Never both at once: a body that has been grabbed cannot grab.
var held: Node3D
var holder: Player

var _pending_rock: Rock
var _pending_player: Player
var _hold_grace := 0.0
var _escape_presses := 0
var _escape_left := 0.0


func setup(owner_player: Player) -> void:
	player = owner_player
	set_physics_process(true)


func is_holding() -> bool:
	return is_instance_valid(held)


func is_held() -> bool:
	return player.state == Player.State.GRABBED


# DOC: ground only, inside grab_range, and of everything in reach the one
# nearest the cursor. Nothing in reach means nothing happens.
func grab() -> bool:
	if is_holding() or is_held() or not player.is_grounded_state() or is_instance_valid(_pending_rock) or is_instance_valid(_pending_player):
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
	if best is Rock:
		_ask_rock(best as Rock)
	else:
		_ask_player(best as Player)
	return true


func _candidates() -> Array[Node3D]:
	var found: Array[Node3D] = []
	for node in player.get_tree().get_nodes_in_group(Rock.GROUP):
		var rock := node as Rock
		if rock != null and rock.holder_peer == 0:
			found.append(rock)
	if player.get_parent() != null:
		for node in player.get_parent().get_children():
			var other := node as Player
			if other == null or other == player:
				continue
			if other.state == Player.State.GRABBED or other.state == Player.State.DEAD:
				continue
			found.append(other)
	return found


# The host owns every rock, so a grab is a request even when we are the host:
# the same function decides either way.
func _ask_rock(rock: Rock) -> void:
	var me := player.get_multiplayer_authority()
	_pending_rock = rock
	if rock.is_multiplayer_authority() or not multiplayer.has_multiplayer_peer():
		on_rock_answer(rock, rock.host_grab(me))
		return
	rock.request_grab.rpc_id(1)


func on_rock_answer(rock: Rock, approved: bool) -> void:
	if not is_instance_valid(rock) or _pending_rock != rock:
		return
	_pending_rock = null
	if not approved:
		print("PLAYGROUND_GRAB by=%s rock=%s refused" % [player.name, rock.name])
		return
	if is_holding() or not player.is_grounded_state():
		if multiplayer.is_server():
			rock.host_release(player.get_multiplayer_authority())
		else:
			rock.request_release.rpc_id(1)
		return
	_take_hold(rock)


# A player is asked on their own machine, which is where the refusals live.
func _ask_player(target: Player) -> void:
	_pending_player = target
	if target.is_local() or not multiplayer.has_multiplayer_peer():
		on_player_answer(target, target.accept_grab(player.get_multiplayer_authority()))
		return
	target.request_grab.rpc_id(target.get_multiplayer_authority(), player.get_multiplayer_authority())


func on_player_answer(target: Player, approved: bool) -> void:
	if not is_instance_valid(target) or _pending_player != target:
		return
	_pending_player = null
	if not approved or is_holding() or not player.is_grounded_state():
		return
	_take_hold(target)


func _take_hold(target: Node3D) -> void:
	held = target
	_hold_grace = HOLD_GRACE
	if player.movement != null:
		player.movement.cancel_target()
	player.change_state(Player.State.GRABBING)
	print("PLAYGROUND_GRAB by=%s target=%s" % [player.name, target.name])


# Called on the body being grabbed, by its own machine.
func become_held(by: Player) -> void:
	holder = by
	_hold_grace = HOLD_GRACE
	_escape_presses = 0
	_escape_left = 0.0
	if player.climb != null and player.climb.is_climbing():
		player.climb.detach(0.0)
	if player.movement != null:
		player.movement.cancel_target()
	player.velocity = Vector3.ZERO
	player.change_state(Player.State.GRABBED)
	print("PLAYGROUND_GRABBED peer=%s by=%s" % [player.name, by.name])


# DOC: direction is the cursor's heading, tilted up by throw_up_angle_deg.
func throw() -> bool:
	if not is_holding():
		return false
	var direction := throw_direction()
	var target := held
	held = null
	player.change_state(Player.State.IDLE)
	if target is Rock:
		var rock := target as Rock
		if rock.is_multiplayer_authority() or not multiplayer.has_multiplayer_peer():
			rock.host_throw(player.get_multiplayer_authority(), direction)
		else:
			rock.request_throw.rpc_id(1, direction)
	else:
		# A thrown team mate arrives in the air with no damage, which is what
		# lets a third player push them again on the way.
		ForceSystem.send(target, ForceSystem.make_event(
			ForceSystem.Kind.THROW,
			direction,
			Tuning.values.throw_power,
			player.stats.strength,
			player.get_multiplayer_authority(),
			true,
			0.0,
			0.0))
	print("PLAYGROUND_THROW by=%s target=%s dir=(%.2f, %.2f, %.2f)" % [
		player.name, target.name, direction.x, direction.y, direction.z])
	return true


func throw_direction() -> Vector3:
	var flat := player.movement.cursor_direction()
	if flat.length_squared() < 0.01:
		flat = -player.global_transform.basis.z
		flat.y = 0.0
		flat = flat.normalized() if flat.length_squared() > 0.01 else Vector3.FORWARD
	var angle := deg_to_rad(Tuning.values.throw_up_angle_deg)
	return (flat * cos(angle) + Vector3.UP * sin(angle)).normalized()


# Dropped rather than thrown: the holder was stunned, thrown, killed or walked
# off an edge.
func drop() -> void:
	if not is_holding():
		return
	var target := held
	held = null
	if target is Rock:
		var rock := target as Rock
		if rock.is_multiplayer_authority() or not multiplayer.has_multiplayer_peer():
			rock.host_release(player.get_multiplayer_authority())
		else:
			rock.request_release.rpc_id(1)
	print("PLAYGROUND_DROP by=%s target=%s" % [player.name, target.name])


# DOC: Space, grabbed_escape_presses times inside grabbed_escape_window.
func escape_press() -> void:
	if not is_held():
		return
	if _escape_left <= 0.0:
		_escape_presses = 0
		_escape_left = Tuning.values.grabbed_escape_window
	_escape_presses += 1
	_show_progress()
	if _escape_presses < Tuning.values.grabbed_escape_presses:
		return
	var away := Vector3.ZERO
	if is_instance_valid(holder):
		away = player.global_position - holder.global_position
	print("PLAYGROUND_ESCAPE peer=%s presses=%d" % [player.name, _escape_presses])
	_let_go(ESCAPE_PUSH, away)


# Leaving GRABBED by any route at all ends up here, death included.
func clear_holder() -> void:
	holder = null
	_escape_presses = 0
	_escape_left = 0.0
	player.set_overhead_note("")


# Any force at all frees a held body, which then takes that force in the air.
func on_force_received() -> void:
	if is_held():
		_let_go(0.0)
	elif is_holding():
		drop()


func _let_go(push: float, away := Vector3.ZERO) -> void:
	clear_holder()
	var flat := Vector3(away.x, 0.0, away.z)
	if push > 0.0 and flat.length_squared() > 0.0001:
		player.velocity = flat.normalized() * push
	else:
		player.velocity = Vector3.ZERO
	player.change_state(Player.State.AIRBORNE)


func _physics_process(delta: float) -> void:
	if not player.is_local():
		return
	_hold_grace = maxf(0.0, _hold_grace - delta)

	if is_held():
		if not is_instance_valid(holder) or (_hold_grace == 0.0 and holder.state != Player.State.GRABBING):
			# Whatever happened to the holder, the hold is over.
			_let_go(0.0)
			return
		player.global_position = holder.hand_position()
		player.velocity = Vector3.ZERO
		_escape_left = maxf(0.0, _escape_left - delta)
		if _escape_left == 0.0 and _escape_presses > 0:
			_escape_presses = 0
			_show_progress()
		return

	if is_holding():
		if held is Player:
			# The held body follows the hand on its own machine; here we only
			# check that it is still holding on.
			if _hold_grace == 0.0 and (held as Player).state != Player.State.GRABBED:
				held = null
				if player.state == Player.State.GRABBING:
					player.change_state(Player.State.IDLE)
		elif (held as Rock).holder_peer != player.get_multiplayer_authority() and _hold_grace == 0.0:
			held = null
			if player.state == Player.State.GRABBING:
				player.change_state(Player.State.IDLE)


func _show_progress() -> void:
	if _escape_presses <= 0:
		player.set_overhead_note("")
		return
	player.set_overhead_note("탈출 %d/%d" % [_escape_presses, int(Tuning.values.grabbed_escape_presses)])
