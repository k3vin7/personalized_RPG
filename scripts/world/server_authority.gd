class_name ServerAuthority
extends Node

# The server's judge, and the one door a client's intent comes through.
#
# B-b built the door. B-c moved the rulings behind it: the shove's hit test,
# whether a hold may start, when it ends, the escape count and the throw all
# happen here, on the server peer, and leave again as force events or as the
# hold table. A client states a direction or a target and nothing else.
#
# Rules this node keeps:
# 1. The host's own input goes through the same submit() -> _intake() path as a
#    client's. The host skips the network hop because there is none, not
#    because it is allowed around the checks.
# 2. Only the server sends a result. Every result RPC is any_peer plus an
#    explicit sender test, so a forged one is refused in our code and counted.
# 3. There is one hold table, here, for rocks, people and scarecrows alike.
#    Every body's own holder_peer is a read-only copy of a row in it. Nothing
#    else may write a hold, so no two places can disagree about one.

enum Intent {
	SHOVE,
	GRAB,
	THROW,
	DROP,
	ESCAPE,
	# B-d: a fall is reported, not claimed. The owner says where it fell from
	# and where it landed; the server checks that against what it watched.
	FALL,
	RESPAWN,
}

# Anything that can be picked up joins this group and offers
# set_hold_display(): that is the whole contract for being in the table.
const HOLDABLE_GROUP := "holdable"

# A request/approve protocol needs a window: the client marks itself pending
# when it submits and nothing answers a refusal, so the mark has to time out.
const INTENT_TIMEOUT := 1.0

# The owner's position and state reach the server a round trip late, so a hold
# is left alone this long before the holder is required to look like a holder.
# Without it the server granted a hold and withdrew it on the next tick,
# because the state proving it had not arrived yet.
const HOLD_GRACE := 0.6

# The table is small and it matters: pushed on every change, plus a heartbeat
# so a lost packet cannot leave a client holding a row the server has dropped.
const VIEW_HEARTBEAT := 0.5

# A sanity bound on distance, not the ruling: what the server sees of a remote
# body is a round trip old.
const INTENT_RANGE_SLACK := 1.5

# A scarecrow has no stats resource of its own.
const DUMMY_WEIGHT := 12.0

# How far a reported fall may differ from the one the server watched before the
# server stops believing it. A client's own peak is the better number -- it is
# the one that owns the body and samples every frame -- so it is used unless it
# disagrees with the replicated history by more than this.
const FALL_REPORT_TOLERANCE := 1.5

# A landing seen by the server keeps its peak around this long, because the
# owner's report can arrive either side of the server seeing the landing.
const FALL_PEAK_HOLD := 0.6

# Found by the player scripts, which are spawned under Players and have no
# scene-tree relationship to this node.
static var instance: ServerAuthority

# Counted rather than only printed, so a test can assert a refusal happened
# instead of grepping a log.
var rejected_intents := 0
var rejected_results := 0
var granted_intents := 0
# Why holds ended, by reason. The E-5 exception table is read straight off it.
var release_reasons := {}

# Server truth. holder peer -> {target: NodePath, grace, presses, window}
var _holds := {}
# Every peer's read-only copy. target NodePath -> {holder: int, presses: int}
var _view := {}
var _view_dirty := true
var _heartbeat_left := 0.0

# peer -> seconds of shove cooldown left. The server's, not the client's.
var _shove_cooldown := {}

# B-d vitals bookkeeping, all server side.
# peer -> {peak: float, tracking: bool, hold: float}
var _fall_watch := {}
# peer -> seconds until the body comes back
var _respawn_left := {}
var fall_mismatches := 0


func _ready() -> void:
	# The server rules; every peer still carries the node so the intent path
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
# place. Sender 0 is a local call rather than an RPC; sender 1 is the server.
static func result_is_server_sent(rpc_name: String, sender: int) -> bool:
	if sender == 0 or sender == 1:
		return true
	note_rejected_result(rpc_name, sender)
	return false


static func note_rejected_result(rpc_name: String, sender: int) -> void:
	if instance != null:
		instance.rejected_results += 1
	print("PLAYGROUND_RESULT_REJECTED rpc=%s sender=%d" % [rpc_name, sender])


# ---------------------------------------------------------------- the table
# Readable on every peer, writable only on the server.

# 0 means nobody holds it.
func holder_of(target: Node) -> int:
	if target == null:
		return 0
	var entry: Dictionary = _view.get(target.get_path(), {})
	return int(entry.get("holder", 0))


func held_by(peer: int) -> Node3D:
	if peer == 0:
		return null
	for path: NodePath in _view:
		var entry: Dictionary = _view[path]
		if int(entry.get("holder", 0)) == peer:
			return get_node_or_null(path) as Node3D
	return null


func escape_presses(target: Node) -> int:
	if target == null:
		return 0
	var entry: Dictionary = _view.get(target.get_path(), {})
	return int(entry.get("presses", 0))


func hold_count() -> int:
	return _view.size()


func _take_hold(holder_peer: int, target: Node3D) -> void:
	var holder := actor_for(holder_peer)
	_holds[holder_peer] = {
		"target": target.get_path(),
		"grace": HOLD_GRACE,
		# The grace is for waiting on the holder's state to arrive, and nothing
		# else. It is spent the moment the holder has been seen holding once,
		# and it never applies to a holder on this machine, whose state has no
		# round trip to make. While it was a flat 0.6 s for everyone, a holder
		# could hop and keep the rock: the body landed again, and was grounded
		# once more, before the window closed.
		"confirmed": holder != null and holder.is_local(),
		"presses": 0,
		"window": 0.0,
	}
	_view_dirty = true
	# Applied at once, not only when the view is rebuilt later in the step: the
	# throw that follows a release has to find the body already free.
	if target.has_method("set_hold_display"):
		target.set_hold_display(holder_peer)
	print("PLAYGROUND_HOLD_TAKEN holder=%d target=%s" % [holder_peer, target.name])


# The only way a hold ends. Returns what was being held.
func _end_hold(holder_peer: int, reason: String) -> Node3D:
	if not _holds.has(holder_peer):
		return null
	var record: Dictionary = _holds[holder_peer]
	var target := get_node_or_null(record["target"] as NodePath) as Node3D
	_holds.erase(holder_peer)
	_view_dirty = true
	if target != null and target.has_method("set_hold_display"):
		target.set_hold_display(0)
	release_reasons[reason] = int(release_reasons.get(reason, 0)) + 1
	print("PLAYGROUND_HOLD_ENDED holder=%d target=%s reason=%s" % [
		holder_peer, target.name if target != null else "gone", reason])
	return target


func _rebuild_view() -> void:
	_view.clear()
	for holder_peer: int in _holds:
		var record: Dictionary = _holds[holder_peer]
		_view[record["target"]] = {"holder": holder_peer, "presses": int(record["presses"])}
	_apply_view()


# Writes the read-only copy onto every body that can be held. This is the only
# place a holder_peer is written, on the server and on a client alike.
func _apply_view() -> void:
	for node in get_tree().get_nodes_in_group(HOLDABLE_GROUP):
		if not node.has_method("set_hold_display"):
			continue
		var entry: Dictionary = _view.get(node.get_path(), {})
		node.set_hold_display(int(entry.get("holder", 0)))


func _push_view() -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	var entries: Array[Dictionary] = []
	for path: NodePath in _view:
		var entry: Dictionary = _view[path]
		entries.append({
			"target": path,
			"holder": int(entry.get("holder", 0)),
			"presses": int(entry.get("presses", 0)),
		})
	push_holds.rpc(entries)


# Server -> every peer. Reliable: a dropped row would leave a client carrying
# something the server has already let go of.
@rpc("any_peer", "call_remote", "reliable")
func push_holds(entries: Array) -> void:
	if not result_is_server_sent("push_holds", multiplayer.get_remote_sender_id()):
		return
	_view.clear()
	for entry: Dictionary in entries:
		var path: Variant = entry.get("target")
		if path is NodePath:
			_view[path as NodePath] = {
				"holder": int(entry.get("holder", 0)),
				"presses": int(entry.get("presses", 0)),
			}
	_apply_view()


# ---------------------------------------------------------------- the door

static func submit_intent(actor: Player, kind: int, payload: Dictionary) -> Variant:
	if instance == null:
		push_warning("ServerAuthority is not in the tree: intent %d dropped" % kind)
		return null
	return instance.submit(actor, kind, payload)


# Called on the acting peer, host and client alike. Returns the ruling when
# this peer is also the judge; a client gets null and the result arrives as a
# force event or as a new row in the table.
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
	var sender := multiplayer.get_remote_sender_id()
	# A ruling moves bodies, so it belongs in a physics step like every other
	# state change, never in the RPC callback.
	Net.queue_physics(func() -> void: _intake(sender, kind, payload))


func _intake(sender: int, kind: int, payload: Dictionary) -> Variant:
	if not is_judge():
		return null
	var actor := actor_for(sender)
	if actor == null or not _shape_is_valid(kind, payload):
		return _refuse(sender, kind, "shape")
	var result: Variant = null
	match kind:
		Intent.SHOVE:
			result = _rule_shove(actor, _direction_of(payload))
		Intent.GRAB:
			result = _rule_grab(actor, _target_for(payload))
		Intent.THROW:
			result = _rule_throw(actor, _direction_of(payload))
		Intent.DROP:
			result = _rule_drop(actor)
		Intent.ESCAPE:
			result = _rule_escape(actor)
		Intent.FALL:
			result = _rule_fall(actor, payload)
		Intent.RESPAWN:
			result = _rule_respawn(actor)
	if result == null:
		return _refuse(sender, kind, "refused")
	granted_intents += 1
	print("PLAYGROUND_INTENT sender=%d kind=%d" % [sender, kind])
	return result


func _refuse(sender: int, kind: int, why: String) -> Variant:
	rejected_intents += 1
	print("PLAYGROUND_INTENT_REJECTED sender=%d kind=%d why=%s" % [sender, kind, why])
	return null


# Only the shape of the message, not whether it is allowed. The rulings below
# each answer that for themselves, because each one answers it differently.
func _shape_is_valid(kind: int, payload: Dictionary) -> bool:
	match kind:
		Intent.SHOVE, Intent.THROW:
			return _direction_of(payload) != Vector3.ZERO
		Intent.GRAB:
			return _target_for(payload) != null
		Intent.DROP, Intent.ESCAPE, Intent.RESPAWN:
			return true
		Intent.FALL:
			return payload.has("peak") and payload.has("land") \
				and is_finite(float(payload.get("peak", INF))) \
				and is_finite(float(payload.get("land", INF)))
	return false


# ------------------------------------------------------------- the rulings

# The hit test, the ally call and the cooldown, all on the server. The query
# runs against the server's own world, so what it sees of a remote body is the
# replicated position -- which is the whole point of putting the ruling here.
func _rule_shove(actor: Player, direction: Vector3) -> Variant:
	var peer := actor.get_multiplayer_authority()
	if actor.state == Player.State.DEAD or not actor.is_grounded_state():
		return null
	if float(_shove_cooldown.get(peer, 0.0)) > 0.0:
		return null
	_shove_cooldown[peer] = Tuning.values.shove_cooldown

	var shape := SphereShape3D.new()
	shape.radius = Tuning.values.shove_range + Tuning.values.shove_ally_bonus
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = Transform3D(Basis.IDENTITY, actor.global_position)
	params.collision_mask = Player.PLAYER_LAYER | Dummy.LAYER
	params.collide_with_areas = false
	params.exclude = [actor.get_rid()]
	var half_angle := deg_to_rad(Tuning.values.shove_half_angle_deg)
	var hits := 0
	for collision in actor.get_world_3d().direct_space_state.intersect_shape(params, 8):
		var body := collision.get("collider") as Node3D
		if body == null or body == actor:
			continue
		var offset := body.global_position - actor.global_position
		offset.y = 0.0
		if offset.length_squared() < 0.0001:
			continue
		# 4-chapter: a team mate is any other player while the playground is all
		# field. Party membership arrives in stage D.
		var is_ally := body is Player
		var reach: float = Tuning.values.shove_range
		if is_ally:
			reach += Tuning.values.shove_ally_bonus
		if offset.length() > reach:
			continue
		if absf(direction.signed_angle_to(offset.normalized(), Vector3.UP)) > half_angle:
			continue
		var push := offset.normalized() + Vector3.UP * Tuning.values.shove_up_bias
		send_force(body, ForceSystem.make_event(
			ForceSystem.Kind.SHOVE,
			push,
			Tuning.values.shove_power,
			actor.stats.strength,
			peer,
			is_ally,
			Tuning.values.shove_damage,
			Tuning.values.shove_stun_time))
		hits += 1
	# The body still turns to face where it pushed, and that part belongs to
	# whoever owns the body.
	if actor.is_local():
		actor.snap_facing(direction)
	else:
		face_shove.rpc_id(peer, direction)
	print("PLAYGROUND_SHOVE by=%s hits=%d" % [actor.name, hits])
	return hits


@rpc("any_peer", "call_remote", "reliable")
func face_shove(direction: Vector3) -> void:
	if not result_is_server_sent("face_shove", multiplayer.get_remote_sender_id()):
		return
	var actor := actor_for(multiplayer.get_unique_id())
	if actor != null and actor.is_local() and direction.is_finite():
		Net.queue_physics(func() -> void: actor.snap_facing(direction))


# Whether a hold may start: the table first, then reach, then the lift limit,
# then state. E-5's "two people reach at once" and "both grab each other" are
# both answered by the table rather than by a case of their own.
func can_grab(actor: Player, target: Node3D) -> bool:
	if actor == null or not is_instance_valid(target) or target == actor:
		return false
	var peer := actor.get_multiplayer_authority()
	if _holds.has(peer):
		return false                      # already carrying something
	if holder_of(actor) != 0:
		return false                      # being carried, so not grabbing
	if holder_of(target) != 0:
		return false                      # someone reached it first
	if actor.state == Player.State.DEAD or not actor.is_grounded_state():
		return false
	if target is Player:
		var person := target as Player
		if person.state == Player.State.DEAD or person.state == Player.State.GRABBED:
			return false
	if actor.global_position.distance_to(target.global_position) > (
			Tuning.values.grab_range + Player.BODY_RADIUS + INTENT_RANGE_SLACK):
		return false
	var limit: float = actor.stats.strength * Tuning.values.lift_per_strength
	if not is_finite(limit) or weight_of(target) > limit:
		return false
	return true


func _rule_grab(actor: Player, target: Node3D) -> Variant:
	if not can_grab(actor, target):
		return null
	_take_hold(actor.get_multiplayer_authority(), target)
	return true


# 4-chapter weights, in one place because the lift limit is judged in one place.
func weight_of(target: Node3D) -> float:
	if target is Rock:
		return (target as Rock).weight
	if target is Player:
		return (target as Player).stats.total_weight()
	if target is Dummy:
		return DUMMY_WEIGHT
	return INF


func _rule_throw(actor: Player, direction: Vector3) -> Variant:
	var peer := actor.get_multiplayer_authority()
	if not _holds.has(peer):
		return null
	var target := _end_hold(peer, "thrown")
	if target == null:
		return null
	if target is Rock:
		(target as Rock).server_throw(direction, actor.stats.strength, peer)
	else:
		# A thrown team mate arrives in the air with no damage, which is what
		# lets a third player push them again on the way.
		send_force(target, ForceSystem.make_event(
			ForceSystem.Kind.THROW,
			direction,
			Tuning.values.throw_power,
			actor.stats.strength,
			peer,
			true,
			0.0,
			0.0))
	print("PLAYGROUND_THROW by=%s target=%s dir=(%.2f, %.2f, %.2f)" % [
		actor.name, target.name, direction.x, direction.y, direction.z])
	return true


func _rule_drop(actor: Player) -> Variant:
	var peer := actor.get_multiplayer_authority()
	if not _holds.has(peer):
		return null
	var target := _end_hold(peer, "dropped")
	print("PLAYGROUND_DROP by=%s target=%s" % [
		actor.name, target.name if target != null else "gone"])
	return true


# The escape count lives in the table row, so the presses are counted where the
# hold is and every peer can show the progress without being told separately.
func _rule_escape(actor: Player) -> Variant:
	var holder_peer := holder_of(actor)
	if holder_peer == 0 or not _holds.has(holder_peer):
		return null
	var record: Dictionary = _holds[holder_peer]
	if float(record["window"]) <= 0.0:
		record["presses"] = 0
		record["window"] = Tuning.values.grabbed_escape_window
	record["presses"] = int(record["presses"]) + 1
	_view_dirty = true
	if int(record["presses"]) < int(Tuning.values.grabbed_escape_presses):
		return true
	var holder := actor_for(holder_peer)
	var away := Vector3.ZERO
	if holder != null:
		away = actor.global_position - holder.global_position
	away.y = 0.0
	if away.length_squared() < 0.0001:
		away = -actor.global_transform.basis.z
		away.y = 0.0
	print("PLAYGROUND_ESCAPE peer=%s presses=%d" % [actor.name, int(record["presses"])])
	# Freed first, then pushed: the row has to be gone before the force lands,
	# or the owner is still following the hand and zeroes the velocity it was
	# just given. Both go out this tick, reliable and in this order.
	_end_hold(holder_peer, "escaped")
	_rebuild_view()
	_push_view()
	_view_dirty = false
	send_force(actor, ForceSystem.make_event(
		ForceSystem.Kind.KNOCKBACK,
		away.normalized(),
		Tuning.values.escape_recoil_power,
		0.0,
		1,
		false,
		0.0,
		0.0))
	return true


# Every force the server rules on leaves through here. A body that is holding
# or being held lets go first: 7-6's rule, with the table as the place it
# happens rather than each machine deciding for itself.
func send_force(target: Node, event: Dictionary) -> void:
	if target == null or not is_instance_valid(target):
		return
	var holder_peer := holder_of(target)
	if holder_peer != 0:
		_end_hold(holder_peer, "target_pushed")
	if target is Player:
		var person_peer := (target as Player).get_multiplayer_authority()
		if _holds.has(person_peer):
			_end_hold(person_peer, "holder_pushed")
		# B-d: the damage and the stun are decided here and the HP is written
		# here. What goes out to the owner is the push, and a stun to apply.
		_rule_hurt(target as Player, event)
	ForceSystem.send(target, event)


# 4-chapter damage table. A team mate is any other player while the playground
# is all field; party membership arrives in stage D.
func _rule_hurt(target: Player, event: Dictionary) -> void:
	event["stun_apply"] = 0.0
	if target.sync_dead:
		return
	var ally := bool(event.get("is_ally_source", false))
	var damage := float(event.get("damage", 0.0))
	if target.state == Player.State.AIRBORNE:
		# Already flying: a team mate's push is free, anyone else's hurts, and
		# nothing stuns in the air.
		if not ally:
			server_damage(target, damage, "force")
		return
	if not ally or Tuning.values.ally_ground_damage:
		server_damage(target, damage, "force")
	if target.sync_dead:
		return
	var stun := float(event.get("stun_time", 0.0))
	if stun > 0.0 and (not ally or Tuning.values.ally_ground_stun):
		event["stun_apply"] = stun


# ------------------------------------------------------------------ vitals
# B-d: HP and the alive flag are the server's to write, and the Vitals
# synchronizer replicates them outward. The owner still writes its own pose,
# so a death is "the server says you are dead" plus "your machine puts the
# body in the DEAD state".

func server_set_hp(player: Player, value: float) -> void:
	if player == null or not is_judge():
		return
	player.hp = clampf(value, 0.0, player.stats.max_hp)


func server_damage(player: Player, amount: float, cause: String) -> void:
	if player == null or not is_judge() or amount <= 0.0 or player.sync_dead:
		return
	server_set_hp(player, player.hp - amount)
	if player.hp <= 0.0:
		server_kill(player, cause)


# The one place a body dies, and it only happens once: B-a's rule that nothing
# overwrites DEAD now has a single writer to go with it.
func server_kill(player: Player, cause: String) -> void:
	if player == null or not is_judge() or player.sync_dead:
		return
	var peer := player.get_multiplayer_authority()
	server_set_hp(player, 0.0)
	player.sync_dead = true
	_respawn_left[peer] = Tuning.values.respawn_delay
	if _holds.has(peer):
		_end_hold(peer, "holder_died")
	var holder_peer := holder_of(player)
	if holder_peer != 0:
		_end_hold(holder_peer, "target_dead")
	print("PLAYGROUND_DIED peer=%s cause=%s at=(%.1f, %.1f, %.1f)" % [
		player.name, cause, player.global_position.x, player.global_position.y,
		player.global_position.z])
	if player.is_local():
		player.enter_dead_now()
	else:
		enter_dead.rpc_id(peer)


# tell_owner is false only when the owner has already put the body on a mark
# itself: a mark is pose, and pose is the owner's. Telling it again would move
# the body a second time, a round trip later, over whatever it was doing by
# then -- which is exactly what it did before this argument existed.
func server_respawn(player: Player, tell_owner := true) -> void:
	if player == null or not is_judge():
		return
	var peer := player.get_multiplayer_authority()
	server_set_hp(player, player.stats.max_hp)
	player.sync_dead = false
	_respawn_left.erase(peer)
	_fall_watch.erase(peer)
	if _holds.has(peer):
		_end_hold(peer, "holder_respawned")
	if not tell_owner:
		return
	if player.is_local():
		player.apply_respawn()
	else:
		apply_respawn.rpc_id(peer)


# Server -> owner. The body's own machine puts it in the state and stops it,
# because the pose is still the owner's.
@rpc("any_peer", "call_remote", "reliable")
func enter_dead() -> void:
	if not result_is_server_sent("enter_dead", multiplayer.get_remote_sender_id()):
		return
	var actor := actor_for(multiplayer.get_unique_id())
	if actor != null and actor.is_local():
		Net.queue_physics(actor.enter_dead_now)


@rpc("any_peer", "call_remote", "reliable")
func apply_respawn() -> void:
	if not result_is_server_sent("apply_respawn", multiplayer.get_remote_sender_id()):
		return
	var actor := actor_for(multiplayer.get_unique_id())
	if actor != null and actor.is_local():
		Net.queue_physics(actor.apply_respawn)


# R, and the way back from a fall. The owner asked for this one: an alive body
# has already moved itself, so only the vitals need clearing, while a dead one
# is waiting to be told -- leaving DEAD is this ruling and nothing else.
func _rule_respawn(actor: Player) -> Variant:
	server_respawn(actor, actor.sync_dead)
	return true


# The owner reports where it fell from and where it landed. The server checks
# that against the height it watched the body reach, and the damage is its own.
func _rule_fall(actor: Player, payload: Dictionary) -> Variant:
	if actor.sync_dead:
		return null
	var peer := actor.get_multiplayer_authority()
	var claimed := maxf(0.0, float(payload["peak"]) - float(payload["land"]))
	var watch: Dictionary = _fall_watch.get(peer, {})
	var watched_peak := float(watch.get("peak", actor.global_position.y))
	var observed := maxf(0.0, watched_peak - actor.global_position.y)
	var height := claimed
	if absf(claimed - observed) > FALL_REPORT_TOLERANCE:
		# The report does not match the body the server watched. The history
		# wins and the disagreement is a line in the log.
		height = observed
		fall_mismatches += 1
		print("PLAYGROUND_FALL_MISMATCH peer=%s claimed=%.2f observed=%.2f used=%.2f" % [
			actor.name, claimed, observed, height])
	actor.last_fall_height = height
	if not Tuning.values.fall_damage_enabled or height <= Tuning.values.fall_damage_min_height:
		return true
	var damage: float = (height - Tuning.values.fall_damage_min_height) * Tuning.values.fall_damage_per_meter
	server_damage(actor, damage, "fall")
	print("PLAYGROUND_FALL_DAMAGE peer=%s height=%.2f damage=%.1f hp=%.0f" % [
		actor.name, height, damage, actor.hp])
	return true


# Watched once per physics step, for every body: the height it reached, whether
# it has fallen out of the world, and when a dead one comes back.
func _watch_vitals(delta: float) -> void:
	if not is_instance_valid(Net.spawn_root):
		return
	for node in Net.spawn_root.get_children():
		var player := node as Player
		if player == null:
			continue
		var peer := player.get_multiplayer_authority()
		var y := player.global_position.y
		var watch: Dictionary = _fall_watch.get(peer, {"peak": y, "tracking": false, "hold": 0.0})
		if player.state == Player.State.AIRBORNE:
			watch["peak"] = maxf(float(watch["peak"]), y) if bool(watch["tracking"]) else y
			watch["tracking"] = true
			watch["hold"] = FALL_PEAK_HOLD
		else:
			watch["tracking"] = false
			watch["hold"] = maxf(0.0, float(watch["hold"]) - delta)
			if float(watch["hold"]) <= 0.0:
				watch["peak"] = y
		_fall_watch[peer] = watch

		if player.sync_dead:
			_respawn_left[peer] = maxf(0.0, float(_respawn_left.get(peer, 0.0)) - delta)
			if float(_respawn_left[peer]) <= 0.0:
				server_respawn(player)
			continue
		# Out of the world. Checked here rather than on the owner so that one
		# place decides a death, from the position the server has.
		if y < Tuning.values.kill_plane_y:
			server_kill(player, "kill_plane")


# ------------------------------------------------------------ the exceptions
# E-5, all five of them, answered from the table once per physics step rather
# than by a case inside each action.

func _physics_process(delta: float) -> void:
	if not is_judge():
		return
	for peer: int in _shove_cooldown.keys():
		_shove_cooldown[peer] = maxf(0.0, float(_shove_cooldown[peer]) - delta)
	_enforce_holds(delta)
	_watch_vitals(delta)
	if _view_dirty:
		_rebuild_view()
		_push_view()
		_view_dirty = false
		_heartbeat_left = VIEW_HEARTBEAT
		return
	_heartbeat_left -= delta
	if _heartbeat_left <= 0.0:
		_heartbeat_left = VIEW_HEARTBEAT
		_push_view()


func _enforce_holds(delta: float) -> void:
	for holder_peer: int in _holds.keys():
		var record: Dictionary = _holds[holder_peer]
		record["grace"] = maxf(0.0, float(record["grace"]) - delta)
		if float(record["window"]) > 0.0:
			record["window"] = maxf(0.0, float(record["window"]) - delta)
			if float(record["window"]) == 0.0 and int(record["presses"]) > 0:
				# The window closed without enough presses: start again.
				record["presses"] = 0
				_view_dirty = true

		# E-5: the holder disconnected.
		var holder := actor_for(holder_peer)
		if holder == null or not _peer_present(holder_peer):
			_end_hold(holder_peer, "holder_gone")
			continue
		var target := get_node_or_null(record["target"] as NodePath) as Node3D
		if target == null or not is_instance_valid(target):
			_end_hold(holder_peer, "target_gone")
			continue
		# E-5: the holder was stunned, thrown, killed or walked off an edge.
		if holder.state == Player.State.GRABBING:
			record["confirmed"] = true
		if (bool(record["confirmed"]) or float(record["grace"]) == 0.0) \
				and not _can_keep_holding(holder):
			_end_hold(holder_peer, "holder_state")
			continue
		# A body that died in someone's hands is not still in them.
		if target is Player and (target as Player).state == Player.State.DEAD:
			_end_hold(holder_peer, "target_dead")


func _can_keep_holding(holder: Player) -> bool:
	# GRABBING is what the owner sets once it sees the row; IDLE and MOVE are
	# what it may still be showing for a tick either side of that.
	return holder.state == Player.State.GRABBING or holder.is_grounded_state()


func _peer_present(peer: int) -> bool:
	if not multiplayer.has_multiplayer_peer():
		return true
	return peer == 1 or multiplayer.get_peers().has(peer)


# ------------------------------------------------------------------ helpers

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
	if node != null and node.is_in_group(HOLDABLE_GROUP):
		return node as Node3D
	return null


func actor_for(peer_id: int) -> Player:
	if not is_instance_valid(Net.spawn_root):
		return null
	return Net.spawn_root.get_node_or_null(str(peer_id)) as Player
