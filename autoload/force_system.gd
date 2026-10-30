extends Node

# Every push, throw, knockback and shove in the game goes through send().
# Nothing else may write another object's velocity.
#
# The receiving side does the arithmetic, because the sum depends on the
# target's own weight and the target's client is the one that is certain of it.
# That also puts the result on the machine that owns the body, which is what the
# design doc's authority table asks for.

enum Kind {
	SHOVE,
	THROW,
	KNOCKBACK,
	# Stage D: what a push costs the pusher. A separate kind because it is the
	# one force a body asks to be given.
	RECOIL,
	DEBUG,
}

# Stage D: every event carries an id and the time it was made, so a force can
# be pointed at in a log and in the move check's history rather than described.
static var _next_id := 0


static func make_event(
		kind: int,
		direction: Vector3,
		base_power: float,
		source_strength: float,
		source_peer: int,
		is_ally_source: bool,
		damage: float = 0.0,
		stun_time: float = 0.0) -> Dictionary:
	_next_id += 1
	return {
		"id": _next_id,
		"at": float(Time.get_ticks_msec()) / 1000.0,
		"kind": kind,
		"direction": direction.normalized(),
		"base_power": base_power,
		"source_strength": source_strength,
		"source_peer": source_peer,
		"is_ally_source": is_ally_source,
		"damage": damage,
		"stun_time": stun_time,
	}


# The one way in. Routed to whoever owns the target.
func send(target: Node, event: Dictionary) -> void:
	if target == null or not is_instance_valid(target):
		return
	var authority := target.get_multiplayer_authority()
	if authority == multiplayer.get_unique_id() or not multiplayer.has_multiplayer_peer():
		Net.queue_physics(_apply.bind(target, event.duplicate(true)))
		return
	receive_force.rpc_id(authority, target.get_path(), event)


@rpc("any_peer", "call_remote", "reliable")
func receive_force(path: NodePath, event: Dictionary) -> void:
	if not valid_sender(multiplayer.get_remote_sender_id(), event):
		print("PLAYGROUND_FORCE_REJECTED sender=%d" % multiplayer.get_remote_sender_id())
		return
	var target := get_node_or_null(path)
	if target == null or target.get_multiplayer_authority() != multiplayer.get_unique_id():
		return
	Net.queue_physics(_apply.bind(target, event.duplicate(true)))


# B-a authenticated an owner-to-owner protocol, where a client could send the
# force for its own shove. B-c took the shove ruling away from the client, so
# nothing legitimate sends a force but the server: this is now a plain "the
# server said so", plus the shape test that was always here.
func valid_sender(sender: int, event: Dictionary) -> bool:
	if sender != 1:
		return false
	var direction: Variant = event.get("direction")
	if not direction is Vector3 or not (direction as Vector3).is_finite():
		return false
	for field in ["base_power", "source_strength", "damage", "stun_time"]:
		var value: Variant = event.get(field)
		if not (value is float or value is int) or not is_finite(float(value)) or float(value) < 0.0:
			return false
	return true


func _apply(target: Node, event: Dictionary) -> void:
	if is_instance_valid(target) and target.has_method("apply_force_event"):
		target.apply_force_event(event)


# Shared by everything that can be pushed, so a dummy and a player are shoved
# by the same rule.
#
#     power = base_power x ratio_mult(source_strength / target_weight, k_push)
#
func power_for(event: Dictionary, total_weight: float) -> float:
	var strength := float(event.get("source_strength", 0.0))
	if strength <= 0.0:
		# Environmental force: no one's strength behind it, so no multiplier.
		return float(event.get("base_power", 0.0))
	return float(event.get("base_power", 0.0)) * Tuning.ratio_mult(
		strength / maxf(total_weight, 0.1), Tuning.server.k_push)


# v4 deleted the term that let the target hold part of a push back. Its own
# strength no longer shortens the distance it is pushed -- only its weight
# does, and that is already in power_for. What strength decides now is the
# knockback tolerance below: whether the body holds its ground at all.
#
# The whole of the push, in the one place every push comes through:
#
#     dv = direction x power
#
func change_for(event: Dictionary, total_weight: float) -> Vector3:
	var direction: Vector3 = event.get("direction", Vector3.ZERO)
	return direction * power_for(event, total_weight)


# v4's knockback tolerance: the threshold the target's own strength buys it.
#
#     tolerance = target_strength x tolerance_per_strength x race_tolerance_mult
#
# The race multiplier is the server's table (ServerAuthority.race_tolerance_mult),
# passed in by the caller, which is the server.
#
func tolerance_for(target_strength: float, race_mult: float) -> float:
	# Blocking is out of scope for stage H: 막는 중이면 여기서 보정한다
	# (자세 완성도만큼 허용치를 올리고 스태미나를 깎는다).
	var per: float = maxf(Tuning.server.tolerance_per_strength, 0.0)
	return maxf(target_strength, 0.0) * per * maxf(race_mult, 0.0)


# The comparison, in the same function every force already goes through. The
# server calls this and stamps the answer into the event; the owner applies the
# verdict it was handed and never works one out for itself.
#
#     h_speed = |dv's horizontal part|
#     h_speed <= tolerance -> slide (stays on the ground, keeps what it holds)
#     h_speed >  tolerance -> launch (full dv, lifted to launch_min_up_speed)
#
# Only a body standing on the ground can hold its ground. In the air or on a
# wall the v3 rules stand, so those always read as launched.
#
# A force aimed steeply enough upward -- knock_lift_angle_deg or more above the
# horizontal -- is a lift, not knockback, and is not judged: "judged" says so
# and the owner applies it whole. Read without that, the table swallowed a
# straight-up throw entirely (h_speed 0 is inside every tolerance, and a slide
# throws the upward part away). The angle is the user's ruling on it.
# How far above the horizontal a force points, in degrees. Straight up is 90,
# flat is 0, and anything downward is negative.
func lift_angle_deg(event: Dictionary) -> float:
	var direction: Vector3 = event.get("direction", Vector3.ZERO)
	var flat := Vector2(direction.x, direction.z).length()
	return rad_to_deg(atan2(direction.y, flat))


func judge_knockback(
		event: Dictionary,
		total_weight: float,
		target_strength: float,
		race_mult: float,
		grounded: bool) -> Dictionary:
	var change := change_for(event, total_weight)
	var h_speed := Vector2(change.x, change.z).length()
	var tolerance := tolerance_for(target_strength, race_mult)
	var judged := lift_angle_deg(event) < Tuning.server.knock_lift_angle_deg
	return {
		"h_speed": h_speed,
		"tolerance": tolerance,
		"judged": judged,
		"launched": (not judged) or (not grounded) or h_speed > tolerance,
	}
