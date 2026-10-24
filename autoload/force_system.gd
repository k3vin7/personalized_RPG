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
	DEBUG,
}

const UPWARD_LAUNCH := 0.5


static func make_event(
		kind: int,
		direction: Vector3,
		base_power: float,
		source_strength: float,
		source_peer: int,
		is_ally_source: bool,
		damage: float = 0.0,
		stun_time: float = 0.0) -> Dictionary:
	return {
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
		_apply(target, event)
		return
	receive_force.rpc_id(authority, target.get_path(), event)


@rpc("any_peer", "call_remote", "reliable")
func receive_force(path: NodePath, event: Dictionary) -> void:
	var target := get_node_or_null(path)
	if target == null or target.get_multiplayer_authority() != multiplayer.get_unique_id():
		return
	_apply(target, event)


func _apply(target: Node, event: Dictionary) -> void:
	if target.has_method("apply_force_event"):
		target.apply_force_event(event)


# Shared by everything that can be pushed, so a dummy and a player are shoved
# by the same rule.
func power_for(event: Dictionary, total_weight: float) -> float:
	var strength := float(event.get("source_strength", 0.0))
	if strength <= 0.0:
		# Environmental force: no one's strength behind it, so no multiplier.
		return float(event.get("base_power", 0.0))
	return float(event.get("base_power", 0.0)) * Tuning.ratio_mult(
		strength / maxf(total_weight, 0.1), Tuning.values.ratio_k_jump)
