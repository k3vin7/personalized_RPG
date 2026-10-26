class_name ServerAuthority
extends Node

# The one door between a client's intent and the world changing.
#
# Structure only, which is what B-b is: every action that used to run straight
# off a key press now states an intent, the server peer admits or refuses it,
# and the result comes back out as a server-sent message. What the server
# *decides* is still the old code running on the owner's machine -- moving the
# hit, hold and damage rulings in here is B-c. So the shapes are final and the
# verdicts are not.
#
# Two rules this node exists to keep:
# 1. The host's own input goes through the same submit() -> _intake() path as a
#    client's. The host skips the network hop because there is none, not
#    because it is allowed around the checks.
# 2. Only the server may send a result. Every result RPC is any_peer plus an
#    explicit server_sent() test, so a forged one is refused in our code and
#    counted, rather than relying on the engine's silent drop.

enum Intent {
	SHOVE,
	GRAB,
	THROW,
	ESCAPE,
}

# A request/approve protocol needs a window: the client sets its pending mark
# when it submits and nothing answers a refusal, so the mark has to time out.
# (Same lesson as HOLD_GRACE -- state arrives a round trip late.)
const INTENT_TIMEOUT := 1.0

# The owner's position is a round trip old up here, so the range test is a
# sanity bound rather than the ruling. B-c narrows it with the position history
# the move check already keeps.
const INTENT_RANGE_SLACK := 1.5

# Found by the player scripts, which are spawned under Players and have no
# scene-tree relationship to this node.
static var instance: ServerAuthority

# Counted rather than only printed, so a test can assert a refusal happened
# instead of grepping a log.
var rejected_intents := 0
var rejected_results := 0
var granted_intents := 0


func _ready() -> void:
	# The server rules; every peer still carries the node so the RPC path
	# resolves on both ends.
	set_multiplayer_authority(1)
	instance = self


func _exit_tree() -> void:
	if instance == self:
		instance = null


# True on the peer that judges: the server, or a single process with no peer.
func is_judge() -> bool:
	return not multiplayer.has_multiplayer_peer() or multiplayer.is_server()


# Every receiver of a result message calls this, so refusals are counted in one
# place instead of each script keeping its own tally. Sender 0 is a local call
# rather than an RPC; sender 1 is the server.
static func result_is_server_sent(rpc_name: String, sender: int) -> bool:
	if sender == 0 or sender == 1:
		return true
	note_rejected_result(rpc_name, sender)
	return false


# For the one result that is still owner-sent rather than server-sent, where
# "allowed sender" is a different test but a refusal is the same event.
static func note_rejected_result(rpc_name: String, sender: int) -> void:
	if instance != null:
		instance.rejected_results += 1
	print("PLAYGROUND_RESULT_REJECTED rpc=%s sender=%d" % [rpc_name, sender])


static func submit_intent(actor: Player, kind: int, payload: Dictionary) -> Variant:
	if instance == null:
		push_warning("ServerAuthority is not in the tree: intent %d dropped" % kind)
		return null
	return instance.submit(actor, kind, payload)


# The entrance. Called on the acting peer, host and client alike.
# Returns what the action returned when this peer is also the judge (the host
# acting on itself, or a single process); a client gets null and its result a
# round trip later through authorized().
func submit(actor: Player, kind: int, payload: Dictionary) -> Variant:
	if actor == null or not is_instance_valid(actor) or not actor.is_local():
		return null
	if is_judge():
		return _intake(actor.get_multiplayer_authority(), kind, payload)
	receive_intent.rpc_id(1, kind, payload)
	return null


# Client -> server. The only inbound message a client may send.
@rpc("any_peer", "call_remote", "reliable")
func receive_intent(kind: int, payload: Dictionary) -> void:
	if not is_judge():
		return
	# The sender id comes from the transport, so an actor cannot be claimed.
	_intake(multiplayer.get_remote_sender_id(), kind, payload)


func _intake(sender: int, kind: int, payload: Dictionary) -> Variant:
	if not is_judge():
		return null
	var actor := actor_for(sender)
	if actor == null or not _valid_intent(actor, kind, payload):
		rejected_intents += 1
		print("PLAYGROUND_INTENT_REJECTED sender=%d kind=%d" % [sender, kind])
		return null
	granted_intents += 1
	print("PLAYGROUND_INTENT sender=%d kind=%d" % [sender, kind])
	if actor.is_local():
		# The host acting on its own body: the judge and the owner are the same
		# machine, so there is nothing to send.
		return execute(actor, kind, payload)
	authorized.rpc_id(sender, kind, payload)
	return null


# Server -> owning client. Carries no verdict of its own yet; B-c fills it with
# the resolved hit, hold and damage.
@rpc("any_peer", "call_remote", "reliable")
func authorized(kind: int, payload: Dictionary) -> void:
	if not result_is_server_sent("authorized", multiplayer.get_remote_sender_id()):
		return
	var actor := actor_for(multiplayer.get_unique_id())
	if actor == null or not actor.is_local():
		return
	# Physics changes belong in a physics step, never in an RPC callback.
	Net.queue_physics(func() -> void: execute(actor, kind, payload))


# What the server can check today is what the server can see today: the
# replicated state, position and strength. A remote player's movement, grab and
# climb nodes only exist on its own machine, which is exactly why the rulings
# that need them wait for B-c/B-d.
func _valid_intent(actor: Player, kind: int, payload: Dictionary) -> bool:
	if actor.state == Player.State.DEAD:
		return false
	match kind:
		Intent.SHOVE:
			return actor.is_grounded_state() and _direction_of(payload) != Vector3.ZERO
		Intent.GRAB:
			if not actor.is_grounded_state():
				return false
			var target := _target_for(payload)
			if target == null:
				return false
			return actor.global_position.distance_to(target.global_position) <= (
				Tuning.values.grab_range + Player.BODY_RADIUS + INTENT_RANGE_SLACK)
		Intent.THROW:
			# GRABBING is replicated, so the server knows a holder from a liar.
			return actor.state == Player.State.GRABBING and _direction_of(payload) != Vector3.ZERO
		Intent.ESCAPE:
			return actor.state == Player.State.GRABBED
	return false


func _direction_of(payload: Dictionary) -> Vector3:
	var value: Variant = payload.get("direction")
	if not value is Vector3:
		return Vector3.ZERO
	var direction := value as Vector3
	if not direction.is_finite() or direction.length_squared() < 0.0001:
		return Vector3.ZERO
	return direction


func _target_for(payload: Dictionary) -> Node3D:
	var value: Variant = payload.get("target")
	if not value is NodePath:
		return null
	var node := get_node_or_null(value as NodePath)
	if node is Rock or node is Player:
		return node as Node3D
	return null


# Runs on the machine that owns the acting body, under a physics step.
func execute(actor: Player, kind: int, payload: Dictionary) -> Variant:
	if not is_instance_valid(actor) or not actor.is_local():
		return null
	match kind:
		Intent.SHOVE:
			if actor.movement == null:
				return null
			return actor.movement.apply_shove(_direction_of(payload))
		Intent.GRAB:
			if actor.grab == null:
				return null
			return actor.grab.begin_hold(_target_for(payload))
		Intent.THROW:
			if actor.grab == null:
				return null
			return actor.grab.release_throw(_direction_of(payload))
		Intent.ESCAPE:
			if actor.grab == null:
				return null
			actor.grab.count_escape_press()
			return true
	return null


func actor_for(peer_id: int) -> Player:
	if not is_instance_valid(Net.spawn_root):
		return null
	return Net.spawn_root.get_node_or_null(str(peer_id)) as Player
