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
	# H-1: the debug sliders. The abilities became the server's, so a slider is
	# a request like every other -- the panel states a number and the server
	# decides whether to hold the body off its race at that value.
	STATS,
	# H-2: the per-race multipliers (tolerance, move). A judging number on
	# every peer, so the slider is a request and the server's table is the one
	# that counts -- and the one the server's own move check reads.
	RACE_MULT,
	# N-1: the server's tuning table. Every number a ruling, a trajectory or a
	# cost is built from lives in it, so a slider is a request: the server
	# clamps, writes its own copy, and the copy is pushed to every replica.
	SERVER_TUNING,
	# N-2: a notice, not a request. The dash is the owner's to start (v4: a
	# client decides its own move, jump and dash) and it starts at once; this
	# tells the server so a dash inside the cooldown counts against the body
	# like a speed over the cap does.
	DASH,
	# M-1: a slot's cast. Which skill, and a heading; the SkillDef's own rule
	# function decides the rest. The shove and the grab keep their own doors.
	SKILL,
	# M-3: the race stand and the weapon rack. A choice is a request: the
	# server rules on the hands and the ground, writes the race (the Vitals
	# synchronizer carries it) or tells the owner which weapon it may hold.
	RACE,
	WEAPON,
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

# A holder's state and its "did I jump" flag are two replicated values, and
# the server does not get them in step: measured, a client's own jump is seen
# as AIRBORNE with the flag set, and then as AIRBORNE with the flag already
# back to false, because the landing clears the flag a sample before the state
# catches up. _can_keep_holding() reads that one combination as the ground
# being taken away, so acting on the first frame of it took the rock off every
# client that jumped while carrying one. The verdict has to last this long.
const HOLD_LOST_GRACE := 0.25

# Given only to a holder that was standing on what it just picked up: the floor
# is now in its hands, so it is airborne through no fault of its own and would
# otherwise drop the rock on the frame it lifted it -- meaning the rock you
# stand on could never be picked up at all.
#
# Decided from the geometry rather than handed to every hold, because time
# cannot tell the two cases apart: falling off a lifted rock takes about 0.3 s
# and being teleported two metres up while carrying takes 0.43 s, and that one
# has to keep dropping it.
const HOLD_SETTLE := 0.6

# The table is small and it matters: pushed on every change, plus a heartbeat
# so a lost packet cannot leave a client holding a row the server has dropped.
const VIEW_HEARTBEAT := 0.5

# A sanity bound on distance, not the ruling: what the server sees of a remote
# body is a round trip old.
const INTENT_RANGE_SLACK := 1.5

# A scarecrow has no stats resource of its own.
# Read off the scarecrow rather than written again here: the push and the lift
# limit have to be weighing the same body.

# How far a reported fall may differ from the one the server watched before the
# server stops believing it. A client's own peak is the better number -- it is
# the one that owns the body and samples every frame -- so it is used unless it
# disagrees with the replicated history by more than this.
const FALL_REPORT_TOLERANCE := 1.5

# A landing seen by the server keeps its peak around this long, because the
# owner's report can arrive either side of the server seeing the landing.
const FALL_PEAK_HOLD := 0.6

# Stage D follow-up: a team mate's airborne state reaches the server a round
# trip late, so a launch aimed at a jumping body was landing on a body the
# server still thought was standing -- at 200 ms the co-op crossing failed for
# that reason alone. A body seen in the air this recently still counts as in
# the air for the launch.
const AIRBORNE_MEMORY := 0.3

# B-e move check. Sampled over a window rather than per step: a single physics
# step of a replicated body is mostly packet timing, and dividing a lerp by
# 1/120 s says nothing about how fast anyone is really going.
const MOVE_SAMPLE := 0.1
# How long a force the server sent is remembered as an explanation for speed.
const FORCE_MEMORY := 1.5
# One sample is forgiven after a teleport the server knows about (a respawn, or
# a harness placing a body). Two, because a sample straddles the jump.
const MOVE_FORGIVE_SAMPLES := 2
# N-2: this many samples over the cap in a row, and the owner is put back on the
# last position the check accepted. Two, like the forgiveness: one sample over
# is what an honest landing or a packet's worth of lag looks like.
const MOVE_CORRECT_SAMPLES := 2
# How many samples to let pass after correcting a remote body: the snap back is
# seen a round trip later, and until then the body is where it was.
const MOVE_CORRECT_FORGIVE_REMOTE := 6
# A dash notice this much inside the cooldown is still an honest one: two
# notices a cooldown apart arrive with the wire's jitter between them.
const DASH_COOLDOWN_SLACK := 0.15
# How long after a dash notice the dash's speed stays in the allowance, past
# the dash's own duration: two samples for the windows it straddles, and some
# for the notice and the samples arriving out of step.
const DASH_WINDOW_SLACK := 0.3

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
# Stage G: peer -> what put it in the air last (who, and whether a party
# member). Read by the fall ruling and the kill plane, cleared by both.
var _flight_source := {}
# peer -> seconds until the body comes back
var _respawn_left := {}
# N-5: how long after a respawn the kill plane leaves a body alone. The
# server's copy of a remote body is still where it died until the owner has
# applied the mark and that has come back -- a round trip -- and the kill plane
# read that stale depth as a second death (traced: RESPAWN_AT, then DIED
# cause=kill_plane at the old spot, in the same step).
const RESPAWN_KILL_GRACE := 1.0
var _kill_grace := {}
var fall_mismatches := 0
# peer -> {at: Vector3, left: float, forgive: int, h: float, v: float, hold: float}
# h/v are the biggest force speeds the server has handed this body lately.
var _move_watch := {}
var move_warnings := 0
# N-2: how many times a body was put back, and where the last one went. Read
# by the checks; the log line carries the rest.
var move_corrections := 0
var last_correction := {}
# M-1: per peer, when the current recovery ends (msec) and when each skill's
# cooldown ends. A cast inside either is refused; the server keeps the clock.
var _skill_lock := {}
var _skill_cooldown := {}
var skills_ruled := 0
# M-2: the last strike's ruling, for the checks: {skill, hits, downed}.
var last_strike := {}
# M-7: strikes that have been cast and not yet landed, by the body casting
# them (a player or a scarecrow): {def, direction, at (msec), since (msec)}.
# The intent arrives at the start of the windup; the ruling runs here at the
# impact time -- which is what a catch (and later a parry) has to see.
var _pending_strikes := {}
var strikes_cancelled := 0
var catches := 0
var last_catch := {}
var last_refusal := ""
# C-0: how many hit notices have gone out to attackers.
var hits_notified := 0
# How far a body's centre may be from the strike's height and still be hit: a
# body's own half height, and the reach of a leg or an arm beyond it. A body
# that has jumped clear is out of it; one just off the ground is not.
const STRIKE_REACH_BEYOND := 0.9


# M-4: a strike's height band, off the body it is judged against: its own half
# height and the reach of a limb beyond it. Non-player bodies take the human's.
func strike_band(body: Node3D) -> float:
	if body is Player:
		return (body as Player).half_height() + STRIKE_REACH_BEYOND
	if body is Dummy:
		return Dummy.HALF_HEIGHT + STRIKE_REACH_BEYOND
	return Player.BODY_HALF_HEIGHT + STRIKE_REACH_BEYOND


# M-4: the radius of whatever a rectangle is being applied to.
func body_radius(body: Node3D) -> float:
	if body is Player:
		return (body as Player).radius()
	if body is Dummy:
		return Dummy.RADIUS
	return Player.BODY_RADIUS
# N-3: when the held people's positions were last pushed. They ride the hand on
# the rock's interval, from here, like a rock.
var _held_push_left := 0.0
# When each peer last said it dashed, for the cooldown.
var _dash_seen := {}
# Stage D: the last forces the server handed out, newest last. Each carries the
# event's id and the time it was made, which is what "힘 이력" asks for: a push
# can be pointed at rather than described, and the move check's allowance is
# built from the same rows.
const FORCE_HISTORY_MAX := 64
var force_history: Array[Dictionary] = []
# H-2: the last knockback verdict per peer, for the harness to read. Server
# only, like the ruling itself.
var last_knock := {}
# H-2: v4's per-race seats, indexed by Races.Kind. Written only here, by
# _rule_race_mult, and carried to every peer by push_race_mults -- so the speed
# a client walks at and the cap this node checks it against are one table. All
# 1.0 on purpose: the numbers that belong in them are feel-check questions 8
# and 9.
var race_tolerance_mults := PackedFloat32Array([1.0, 1.0, 1.0, 1.0])
var race_move_mults := PackedFloat32Array([1.0, 1.0, 1.0, 1.0])
const DEBUG_RACE_MULT_RANGE := Vector2(0.0, 3.0)
const RACE_MULT_FIELDS := ["tolerance", "move"]
# N-1: what the server last pushed of its tuning table. Compared every step
# against the live table, so a value written on the server by any path -- the
# slider's intent, a harness, a stage check -- reaches every replica within a
# frame, and the heartbeat repairs a drop.
var _server_tuning_pushed := {}
# H-3: a maximum built from these falls with them, so a change takes the
# current HP down to fit. Nothing else in the table touches HP directly.
const VITALS_FIELDS := ["hp_per_endurance", "stamina_base", "stamina_per_endurance"]


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


# Every row, as "holder->target", for a log line that can be read.
func describe_holds() -> String:
	var parts: Array[String] = []
	for path: NodePath in _view:
		var entry: Dictionary = _view[path]
		var target := get_node_or_null(path)
		parts.append("%d->%s" % [
			int(entry.get("holder", 0)), target.name if target != null else String(path)])
	return "[" + ", ".join(parts) + "]"


func _take_hold(holder_peer: int, target: Node3D) -> void:
	var holder := actor_for(holder_peer)
	_holds[holder_peer] = {
		"target": target.get_path(),
		"grace": HOLD_GRACE,
		"settle": HOLD_SETTLE if _was_standing_on(holder, target) else 0.0,
		# The grace is for waiting on the holder's state to arrive, and nothing
		# else. It is spent the moment the holder has been seen holding once,
		# and it never applies to a holder on this machine, whose state has no
		# round trip to make. While it was a flat 0.6 s for everyone, a holder
		# could hop and keep the rock: the body landed again, and was grounded
		# once more, before the window closed.
		"confirmed": holder != null and holder.is_local(),
		"presses": 0,
		"window": 0.0,
		# How long the holder has looked unable to keep this, in a row.
		"lost": 0.0,
	}
	_view_dirty = true
	# Applied at once, not only when the view is rebuilt later in the step: the
	# throw that follows a release has to find the body already free.
	if target.has_method("set_hold_display"):
		target.set_hold_display(holder_peer)
	print("PLAYGROUND_HOLD_TAKEN holder=%d target=%s" % [holder_peer, target.name])


# In the air, or seen there within one round trip. The launch asks this rather
# than the replicated state on its own.
func recently_airborne(player: Player) -> bool:
	if player == null:
		return false
	if player.state == Player.State.AIRBORNE:
		return true
	var watch: Dictionary = _fall_watch.get(player.get_multiplayer_authority(), {})
	var seen := float(watch.get("air_at", -100.0))
	return float(Time.get_ticks_msec()) / 1000.0 - seen <= AIRBORNE_MEMORY


# Was this body standing on the thing it just picked up? Directly above it,
# within a step of it horizontally.
func _was_standing_on(holder: Player, target: Node3D) -> bool:
	if holder == null or target == null:
		return false
	var below := holder.global_position.y - target.global_position.y
	if below < holder.half_height() * 0.5:
		return false
	var flat := Vector2(
		holder.global_position.x - target.global_position.x,
		holder.global_position.z - target.global_position.z).length()
	return flat <= holder.radius() + 0.5


# The only way a hold ends. Returns what was being held.
func _end_hold(holder_peer: int, reason: String, away_hint := Vector3.ZERO) -> Node3D:
	if not _holds.has(holder_peer):
		return null
	var record: Dictionary = _holds[holder_peer]
	var target := get_node_or_null(record["target"] as NodePath) as Node3D
	_holds.erase(holder_peer)
	_view_dirty = true
	if target != null and target.has_method("set_hold_display"):
		target.set_hold_display(0)
	# N-3: a person is put down by the server, beside whoever was holding
	# them, before the row's disappearance or the force that follows reaches
	# their machine. Both are reliable and ordered behind this.
	if target is Player:
		_release_person(actor_for(holder_peer), target as Player, away_hint)
	elif target is Dummy:
		_release_dummy(actor_for(holder_peer), target as Dummy, away_hint, reason == "thrown")
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
	# The race table rides the same heartbeat: it changes rarely, a late joiner
	# gets it within one beat, and a dropped change is repaired by the next.
	_push_race_mults()
	_push_server_tuning()


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


# ------------------------------------------------------- the race multipliers
# Readable on every peer, writable only on the server, like the hold table.

func race_tolerance_mult(kind: int) -> float:
	return _race_mult(race_tolerance_mults, kind)


func race_move_mult(kind: int) -> float:
	return _race_mult(race_move_mults, kind)


# A race id out of range (a client naming a race this build does not have)
# reads as 1.0 instead of crashing the force door.
func _race_mult(table: PackedFloat32Array, kind: int) -> float:
	if kind < 0 or kind >= table.size():
		return 1.0
	return maxf(table[kind], 0.0)


func _push_race_mults() -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	push_race_mults.rpc(race_tolerance_mults, race_move_mults)


# Server -> every peer. A client that sends this is refused like any other
# forged result, and a table of the wrong shape is ignored.
@rpc("any_peer", "call_remote", "reliable")
func push_race_mults(tolerance: PackedFloat32Array, move: PackedFloat32Array) -> void:
	if not result_is_server_sent("push_race_mults", multiplayer.get_remote_sender_id()):
		return
	var count := Races.all_kinds().size()
	if tolerance.size() != count or move.size() != count:
		return
	race_tolerance_mults = tolerance
	race_move_mults = move


# ------------------------------------------------------- the server tuning
# N-1. Tuning.server is the table; this is how it travels. Readable on every
# peer, written on the server, and a replica takes only what this sends.

func _push_server_tuning() -> void:
	if not multiplayer.has_multiplayer_peer():
		return
	_server_tuning_pushed = Tuning.export_server()
	push_server_tuning.rpc(_server_tuning_pushed)


# Server -> every peer. A client that sends this is refused like any other
# forged result; the import drops unknown fields and wrong types itself.
@rpc("any_peer", "call_remote", "reliable")
func push_server_tuning(values: Dictionary) -> void:
	if not result_is_server_sent("push_server_tuning", multiplayer.get_remote_sender_id()):
		return
	Tuning.import_server(values)


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
			result = _rule_throw(actor, payload)
		Intent.DROP:
			result = _rule_drop(actor)
		Intent.ESCAPE:
			result = _rule_escape(actor)
		Intent.FALL:
			result = _rule_fall(actor, payload)
		Intent.RESPAWN:
			result = _rule_respawn(actor)
		Intent.STATS:
			result = _rule_stats(actor, payload)
		Intent.RACE_MULT:
			result = _rule_race_mult(payload)
		Intent.SERVER_TUNING:
			result = _rule_server_tuning(payload)
		Intent.DASH:
			result = _rule_dash(actor)
		Intent.SKILL:
			result = _rule_skill(actor, payload)
		Intent.RACE:
			result = _rule_race(actor, int(payload.get("race", -1)))
		Intent.WEAPON:
			result = _rule_weapon(actor, int(payload.get("weapon", -1)))
	if result == null:
		return _refuse(sender, kind, "refused")
	granted_intents += 1
	print("PLAYGROUND_INTENT sender=%d kind=%d" % [sender, kind])
	return result


func _refuse(sender: int, kind: int, why: String) -> Variant:
	rejected_intents += 1
	print("PLAYGROUND_INTENT_REJECTED sender=%d kind=%d why=%s" % [sender, kind, why])
	# Stage C: the asker is showing the press on its own screen while this
	# travels. Telling it no is what takes the picture back, instead of leaving
	# it to time out.
	var actor := actor_for(sender)
	if actor != null and actor.is_local():
		actor.clear_predicted()
	elif sender > 1:
		intent_refused.rpc_id(sender, kind)
	return null


# Server -> the peer that asked. Carries no authority of its own: all it does
# is end a local picture early.
@rpc("any_peer", "call_remote", "reliable")
func intent_refused(kind: int) -> void:
	if not result_is_server_sent("intent_refused", multiplayer.get_remote_sender_id()):
		return
	var actor := actor_for(multiplayer.get_unique_id())
	if actor != null and actor.is_local() and actor.predicted_action == kind:
		actor.clear_predicted()


# Only the shape of the message, not whether it is allowed. The rulings below
# each answer that for themselves, because each one answers it differently.
func _shape_is_valid(kind: int, payload: Dictionary) -> bool:
	match kind:
		Intent.SHOVE, Intent.THROW:
			return _direction_of(payload) != Vector3.ZERO
		Intent.GRAB:
			return _target_for(payload) != null
		Intent.DROP, Intent.ESCAPE, Intent.RESPAWN, Intent.DASH:
			return true
		Intent.SKILL:
			return Skills.is_known(String(payload.get("skill", ""))) \
				and _direction_of(payload) != Vector3.ZERO
		Intent.RACE:
			var race: Variant = payload.get("race")
			return race is int and Races.is_known(race)
		Intent.WEAPON:
			var weapon: Variant = payload.get("weapon")
			return weapon is int and WeaponKinds.LABELS.has(weapon)
		Intent.STATS:
			# Either field may be absent (leave it alone) or null (follow the
			# race again). A number has to be a number.
			for field in ["strength", "weight", "gear"]:
				if not payload.has(field):
					continue
				var value: Variant = payload[field]
				if value == null:
					continue
				if not (value is float or value is int) or not is_finite(float(value)):
					return false
			return payload.has("strength") or payload.has("weight") 				or payload.has("gear")
		Intent.RACE_MULT:
			var value: Variant = payload.get("value")
			var field_ok := String(payload.get("field", "")) in RACE_MULT_FIELDS
			var race_ok := Races.is_known(int(payload.get("race", -1)))
			var value_ok := (value is float or value is int) and is_finite(float(value))
			return field_ok and race_ok and value_ok
		Intent.SERVER_TUNING:
			# A field the table has, and a value of its type. A local field or
			# an unknown one is refused here, not clamped into something.
			var field := String(payload.get("field", ""))
			if not Tuning.is_server_field(field):
				return false
			var asked: Variant = payload.get("value")
			if typeof(Tuning.server.get(field)) == TYPE_BOOL:
				return asked is bool
			return (asked is float or asked is int) and is_finite(float(asked))
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
	if actor.sync_dead:
		return null
	# Stage D: a shove goes out in the air as well. A body up there cannot hold
	# its ground, which is the target's problem, not the pusher's.
	if float(_shove_cooldown.get(peer, 0.0)) > 0.0:
		return null
	_shove_cooldown[peer] = Tuning.server.shove_cooldown

	# A rectangle in front of the heading, shove_range deep and shove_width
	# across, rather than the fan it was until stage D. The query is a sphere
	# big enough to hold that rectangle and the rectangle is applied to what it
	# returns: orienting a box costs the same and gets the corners wrong when
	# the heading is not flat.
	var reach: float = Tuning.server.shove_range
	var half_width: float = Tuning.server.shove_width * 0.5
	var forward := Vector3(direction.x, 0.0, direction.z)
	if forward.length_squared() < 0.0001:
		return null
	forward = forward.normalized()
	var side := Vector3(-forward.z, 0.0, forward.x)

	var shape := SphereShape3D.new()
	shape.radius = sqrt(reach * reach + half_width * half_width)
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = Transform3D(Basis.IDENTITY, actor.global_position)
	params.collision_mask = Player.PLAYER_LAYER | Dummy.LAYER
	params.collide_with_areas = false
	params.exclude = [actor.get_rid()]
	var hits := 0
	for collision in actor.get_world_3d().direct_space_state.intersect_shape(params, 8):
		var body := collision.get("collider") as Node3D
		if body == null or body == actor:
			continue
		var offset := body.global_position - actor.global_position
		offset.y = 0.0
		var along := offset.dot(forward)
		var across := absf(offset.dot(side))
		# Behind, past the end, or off to the side: not in the rectangle. The
		# body's own radius counts, or a shove would pass either side of
		# someone standing right in front of it.
		# M-4: the rectangle is the pusher's; what it has to reach is the target's
		# own radius, and its height is the pusher's -- a dwarf's shove is lower.
		var target_radius := body_radius(body)
		if along <= -target_radius or along > reach + target_radius:
			continue
		if across > half_width + target_radius:
			continue
		# A team mate in the air is reached for -- that is the co-op launch, a
		# body at the top of its jump pushed on across a gap -- so the band is
		# for what stands on the ground.
		if not (body is Player and recently_airborne(body as Player)) 				and absf(body.global_position.y - actor.global_position.y) > shove_band(actor):
			continue
		# 4-chapter: a team mate is another player while the debug toggle says
		# they are in the same party. The playground is all field, so there is
		# no party list to read.
		var is_ally := body is Player and Tuning.server.same_party
		var push := forward
		var launched := false
		if is_ally and recently_airborne(body as Player):
			# A team mate already in the air is launched, not shoved: this is
			# what makes one player a step for another.
			var angle := deg_to_rad(Tuning.server.shove_ally_launch_angle_deg)
			push = forward * cos(angle) + Vector3.UP * sin(angle)
			launched = true
		else:
			push = (forward + Vector3.UP * Tuning.server.shove_up_bias).normalized()
		var event := ForceSystem.make_event(
			ForceSystem.Kind.SHOVE,
			push,
			Tuning.server.shove_power,
			actor.stats.strength,
			peer,
			is_ally,
			Tuning.server.shove_damage,
			Tuning.server.shove_stun_time)
		if launched:
			# The body being launched gives itself a jump's worth of lift and
			# adds the push to it, so where in its arc the push lands stops
			# mattering.
			event["spring"] = true
		event["skill"] = "shove"
		event["hit_y"] = actor.global_position.y + Skills.get_def("shove").strike_height * actor.body_scale()
		send_force(body, event)
		hits += 1
		if launched:
			print("PLAYGROUND_SHOVE_LAUNCH by=%s target=%s angle=%.0f" % [
				actor.name, body.name, Tuning.server.shove_ally_launch_angle_deg])
	# What the push costs the pusher. Sent through the same door as everything
	# else, so it is one force event with an id like any other.
	if hits > 0 and Tuning.server.shove_recoil > 0.0:
		# The same up bias every other push gets. Without it the recoil is pure
		# horizontal, and the ground step writes the horizontal velocity back
		# to the move order on the very next frame: the pusher was given a
		# step back it never took.
		send_force(actor, ForceSystem.make_event(
			ForceSystem.Kind.RECOIL,
			(-forward + Vector3.UP * Tuning.server.shove_up_bias).normalized(),
			Tuning.server.shove_power * Tuning.server.shove_recoil,
			actor.stats.strength,
			peer,
			true,
			0.0,
			0.0))
	# The body still turns to face where it pushed, and that part belongs to
	# whoever owns the body.
	if actor.is_local():
		actor.snap_facing(direction)
		if actor.predicted_action == Intent.SHOVE:
			actor.clear_predicted()
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
		Net.queue_physics(func() -> void:
			actor.snap_facing(direction)
			# The shove was allowed: the press has its answer.
			if actor.predicted_action == Intent.SHOVE:
				actor.clear_predicted())


# The debug sliders' own bounds, which is all they are: not a rule about how
# strong anyone may be, just the range the panel can ask for. Kept here because
# the server is what enforces them, and a bound only the panel knew would be a
# bound a forged intent could walk past.
const DEBUG_STRENGTH_RANGE := Vector2(1.0, 150.0)
const DEBUG_WEIGHT_RANGE := Vector2(20.0, 200.0)
# Gear is not a system yet, so this slider is the only way to put weight on a
# body that is not its own and not what it is carrying -- which is what the
# bare-versus-equipped comparison needs.
const DEBUG_GEAR_RANGE := Vector2(0.0, 80.0)


# H-1: a slider asks, the server answers. null means "follow the race again",
# which is also what choosing a race does.
func _rule_stats(actor: Player, payload: Dictionary) -> Variant:
	if actor == null or actor.stats == null:
		return null
	if payload.has("strength"):
		var asked: Variant = payload["strength"]
		actor.stats.strength_override = NAN if asked == null else clampf(
			float(asked), DEBUG_STRENGTH_RANGE.x, DEBUG_STRENGTH_RANGE.y)
	if payload.has("weight"):
		var asked_weight: Variant = payload["weight"]
		actor.stats.weight_override = NAN if asked_weight == null else clampf(
			float(asked_weight), DEBUG_WEIGHT_RANGE.x, DEBUG_WEIGHT_RANGE.y)
	if payload.has("gear"):
		var asked_gear: Variant = payload["gear"]
		# Gear has no "follow the race" state: bare is zero.
		actor.stats.gear_weight = 0.0 if asked_gear == null else clampf(
			float(asked_gear), DEBUG_GEAR_RANGE.x, DEBUG_GEAR_RANGE.y)
	# The body may now be stronger or heavier than it was a frame ago, and the
	# move check compares what it sees against what its strength explains.
	forgive_move(actor.get_multiplayer_authority(), "stats_changed")
	print("PLAYGROUND_STATS peer=%d race=%s strength=%.1f weight=%.1f gear=%.1f overridden=%s" % [
		actor.get_multiplayer_authority(), Races.label_for(actor.stats.race),
		actor.stats.strength, actor.stats.race_weight, actor.stats.gear_weight,
		actor.stats.is_overridden()])
	return true


# The race slider. One entry of one table, clamped, then pushed to everyone.
# A move multiplier changes what every body of that race may be seen doing, so
# the move check forgives a beat for all of them rather than warning about a
# speed it just approved.
func _rule_race_mult(payload: Dictionary) -> Variant:
	var field := String(payload.get("field", ""))
	var kind := int(payload.get("race", -1))
	var value := clampf(float(payload.get("value", 1.0)),
		DEBUG_RACE_MULT_RANGE.x, DEBUG_RACE_MULT_RANGE.y)
	if field == "tolerance":
		race_tolerance_mults[kind] = value
	elif field == "move":
		race_move_mults[kind] = value
		for peer: int in _move_watch.keys():
			forgive_move(peer, "race_mult")
	else:
		return null
	_push_race_mults()
	print("PLAYGROUND_RACE_MULT field=%s race=%s value=%.2f" % [
		field, Races.label_for(kind), value])
	return true


# N-1: the tuning slider. One field, clamped to the range its shipped default
# allows, written into the server's table and pushed. A multiplier the move
# check reads changes what every body may be seen doing, so the check forgives
# a beat for all of them; a vitals coefficient takes the current HP down to
# fit the maximum it just lowered.
func _rule_server_tuning(payload: Dictionary) -> Variant:
	var field := String(payload.get("field", ""))
	var current: Variant = Tuning.server.get(field)
	var asked: Variant = payload.get("value")
	if typeof(current) == TYPE_BOOL:
		Tuning.server.set(field, bool(asked))
	else:
		var limits := Tuning.limits_for(field)
		var value := clampf(float(asked), limits.x, limits.y)
		Tuning.server.set(field, roundi(value) if typeof(current) == TYPE_INT else value)
	Tuning.notify_changed()
	_push_server_tuning()
	for peer: int in _move_watch.keys():
		forgive_move(peer, "server_tuning")
	if field in VITALS_FIELDS:
		_clamp_all_hp()
	print("PLAYGROUND_SERVER_TUNING field=%s value=%s" % [field, str(Tuning.server.get(field))])
	return true


# The maximum is derived, so when what it derives from moves, the current HP is
# brought back inside it. Only ever down: a bigger maximum is not a heal.
func _clamp_all_hp() -> void:
	for node in Net.spawn_root.get_children():
		var player := node as Player
		if player != null and not player.sync_dead:
			server_set_hp(player, player.hp)


# For the automated checks only, and deliberately not an RPC: the abilities are
# the server's, so the one door open from outside is Intent.STATS above. A
# check runs on the host and sets a number here, on the server, for whichever
# body it likes -- the Vitals synchronizer carries it to that body's own
# machine. Gated on the run being an automated one, so in a session a person
# started it does nothing at all and says so.
#
# Pass NAN to put a body back on its race's own number.
func harness_set_stats(player: Player, strength: float, weight := INF,
		gear := INF) -> bool:
	if not is_judge():
		return false
	if not Net.auto_smoke:
		push_warning("harness_set_stats is for --auto runs; ignored")
		print("PLAYGROUND_HARNESS_STATS_REFUSED peer=%s" % (
			player.name if player != null else "?"))
		return false
	if player == null or player.stats == null:
		return false
	player.stats.strength_override = strength
	if not is_inf(weight):
		player.stats.weight_override = weight
	if not is_inf(gear):
		player.stats.gear_weight = 0.0 if is_nan(gear) else gear
	# H-3: max_hp is derived, so the current HP is kept inside the new one.
	if not player.sync_dead:
		server_set_hp(player, player.hp)
	forgive_move(player.get_multiplayer_authority(), "harness_stats")
	return true


# The other half: put a body back on its race, which is what a check doing a
# sweep wants when it is done.
func harness_clear_stats(player: Player) -> bool:
	return harness_set_stats(player, NAN, NAN, NAN)


# H-4 gives a race its own intent and a pedestal to ask from. Until then this
# is how a check gets a body onto one, and it is the server that writes it, the
# same as every other ability. Choosing a race drops the debug overrides, which
# is v4's "choosing a race again goes back to the race's values".
func harness_set_race(player: Player, kind: int) -> bool:
	if not is_judge():
		return false
	if not Net.auto_smoke:
		push_warning("harness_set_race is for --auto runs; ignored")
		print("PLAYGROUND_HARNESS_RACE_REFUSED peer=%s" % (
			player.name if player != null else "?"))
		return false
	if player == null or player.stats == null or not Races.is_known(kind):
		return false
	player.stats.race = kind
	player.stats.clear_overrides()
	player.stats.gear_weight = 0.0
	# H-3: a dwarf's 150 does not fit a human's 105. Clamped, not refilled --
	# the playground refill on a race change is H-4's pedestal, not this door.
	if not player.sync_dead:
		server_set_hp(player, player.hp)
	forgive_move(player.get_multiplayer_authority(), "harness_race")
	return true


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
			Tuning.server.grab_range + actor.radius() + INTENT_RANGE_SLACK):
		return false
	if weight_of(target) > lift_limit(actor):
		return false
	# Stage E leaves a seat for the attack grab: when a hold is contested by a
	# blow rather than by another hold, this is where the blow's force is
	# weighed against it. Nothing calls it yet, and it says yes.
	if not _hold_beats_attack(actor, target):
		return false
	return true


# 4-chapter: strength x lift_per_strength, halved while one hand is busy.
func lift_limit(actor: Player) -> float:
	var limit: float = actor.stats.strength * Tuning.server.lift_per_strength
	if Tuning.server.one_hand_weapon:
		limit /= maxf(Tuning.server.grab_one_hand_strength_mult, 0.01)
	return limit if is_finite(limit) else 0.0


# M-4: how high a shove reaches, off the pusher's body: its half height and a
# limb beyond. The check "a dwarf's rectangle is lower" reads this.
func shove_band(actor: Player) -> float:
	return actor.half_height() + STRIKE_REACH_BEYOND


# The seat for the attack grab. The real version compares the attack's force
# with the hold's; until there are attacks there is nothing to compare.
func _hold_beats_attack(_actor: Player, _target: Node3D) -> bool:
	return true


func _rule_grab(actor: Player, target: Node3D) -> Variant:
	# M-7: an attack in its window is caught before the ordinary rules apply.
	if _try_catch(actor, target):
		return true
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
		return (target as Dummy).weight()
	return INF


# DOC (stage E): an arc that lands where the cursor is, or a straight line in
# the cursor's heading. The charge scales how far an arc may reach and how hard
# a line is thrown.
#
# The arc is solved rather than thrown at a fixed angle. A fixed 35 degrees is
# what used to send a rock clean over a body three metres away: the hand is
# 1.7 m above the thrower's own origin, so a flat-ish lob from it passes above
# a standing target until about nine metres out. Solving for the landing point
# puts it where the cursor is at any range.
#
# Either way it leaves as a force event with the target being thrown, which is
# what "돌 던지기도 힘 이벤트로" asks for: the rock is given a velocity by the
# one force door like everything else.
func _rule_throw(actor: Player, payload: Dictionary) -> Variant:
	var peer := actor.get_multiplayer_authority()
	if not _holds.has(peer):
		return null
	var direction := _direction_of(payload)
	if direction == Vector3.ZERO:
		return null
	var charge: float = clampf(float(payload.get("charge", 1.0)), 0.0, 1.0)
	var line := bool(payload.get("line", false))
	# N-5: a thrown person is set down on the side they are about to fly to.
	# Behind the thrower -- the put-down side -- they left straight into the
	# thrower's own capsule and lost the whole horizontal on the first step;
	# the client thrown at the cliff travelled 0.3 m (traced).
	var target := _end_hold(peer, "thrown", Vector3(direction.x, 0.0, direction.z))
	if target == null:
		return null

	var velocity := Vector3.ZERO
	if line:
		# Straight: the heading, at a speed the charge decides.
		velocity = direction.normalized() * (Tuning.server.throw_line_power_base
			* maxf(charge, 0.2)
			* Tuning.ratio_mult(actor.stats.strength / maxf(weight_of(target), 0.1),
				Tuning.server.ratio_k_jump, Tuning.server.throw_line_mult_max))
	else:
		var landing: Variant = payload.get("target")
		var aim: Vector3 = landing if landing is Vector3 else actor.global_position + direction * 3.0
		velocity = _arc_to(actor.hand_position(), aim, charge,
			actor.stats.strength / maxf(weight_of(target), 0.1))

	var speed := velocity.length()
	if speed <= 0.01:
		return null
	# source_strength 0 so the one force door takes the speed as given: the
	# strength is already in the solve above, and applying it twice would send
	# every throw past the cursor it was aimed at.
	send_force(target, ForceSystem.make_event(
		ForceSystem.Kind.THROW,
		velocity / speed,
		speed,
		0.0,
		peer,
		true,
		Tuning.server.shove_damage * charge if line else 0.0,
		0.0))
	if target is Rock:
		(target as Rock).note_thrown(peer)
	print("PLAYGROUND_THROW by=%s target=%s line=%s charge=%.2f speed=%.2f" % [
		actor.name, target.name, line, charge, speed])
	return true


# The launch that lands at `aim`, or as near to it as the charge allows. The
# cheapest arc that reaches it -- 45 degrees tilted by half the slope to the
# target -- so a throw is never higher than it has to be.
func _arc_to(from: Vector3, aim: Vector3, charge: float, ratio: float) -> Vector3:
	var gravity: float = maxf(Tuning.server.gravity, 0.01)
	var flat := Vector3(aim.x - from.x, 0.0, aim.z - from.z)
	var distance := flat.length()
	if distance < 0.01:
		return Vector3.UP * sqrt(2.0 * gravity * 0.5)
	var reach: float = Tuning.server.throw_arc_max_range_base * maxf(charge, 0.1) \
		* Tuning.ratio_mult(ratio, Tuning.server.ratio_k_jump)
	if distance > reach:
		flat = flat.normalized() * reach
		distance = reach
		aim = Vector3(from.x + flat.x, aim.y, from.z + flat.z)
	var rise := aim.y - from.y
	# N-5: the one copy of this arithmetic, shared with the jump plan.
	var pair := Ballistics.cheapest_launch(distance, rise, gravity)
	var heading := flat.normalized()
	return heading * pair.x + Vector3.UP * pair.y


func _rule_drop(actor: Player) -> Variant:
	var peer := actor.get_multiplayer_authority()
	if not _holds.has(peer):
		return null
	var target := _end_hold(peer, "dropped")
	if target is Rock:
		_put_down_rock(actor, target as Rock)
	print("PLAYGROUND_DROP by=%s target=%s" % [
		actor.name, target.name if target != null else "gone"])
	return true


# N-4: a put-down sets the rock on the ground beside the holder, the way a
# person is put down, instead of letting it fall from the hand. Dropped from
# 2.6 m it could land inside whatever stood beside the holder -- another rock,
# in B-a -- and a sphere pushed out of a sphere by the solver left at 220 m/s.
# Four spots around the holder are tried and the first free one taken; if none
# is free the rock falls from the hand as before.
func _put_down_rock(holder: Player, rock: Rock) -> void:
	var radius := Rock.radius_for(rock.weight)
	var reach := holder.radius() + radius + 0.1
	var ground_y := holder.global_position.y - holder.half_height() + radius
	var forward := -holder.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = Vector3.FORWARD
	forward = forward.normalized()
	var right := forward.cross(Vector3.UP)
	var space := holder.get_world_3d().direct_space_state
	var shape := SphereShape3D.new()
	shape.radius = radius + 0.05
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	# Bodies only: the spot sits on the floor by construction, and the floor
	# answering the query left every spot "taken".
	query.collision_mask = Layers.PLAYER | Layers.THROWABLE | Layers.DUMMY
	query.exclude = [rock.get_rid(), holder.get_rid()]
	for direction: Vector3 in [forward, right, -right, -forward]:
		var spot := Vector3(
			holder.global_position.x + direction.x * reach, ground_y,
			holder.global_position.z + direction.z * reach)
		query.transform = Transform3D(Basis.IDENTITY, spot)
		if space.intersect_shape(query, 1).is_empty():
			rock.global_position = spot
			rock.linear_velocity = Vector3.ZERO
			rock.angular_velocity = Vector3.ZERO
			print("PLAYGROUND_PUT_DOWN rock=%s at=(%.2f, %.2f, %.2f)" % [rock.name, spot.x, spot.y, spot.z])
			return
	print("PLAYGROUND_PUT_DOWN rock=%s no_free_spot" % rock.name)


# The escape count lives in the table row, so the presses are counted where the
# hold is and every peer can show the progress without being told separately.
func _rule_escape(actor: Player) -> Variant:
	var holder_peer := holder_of(actor)
	if holder_peer == 0 or not _holds.has(holder_peer):
		return null
	var record: Dictionary = _holds[holder_peer]
	if float(record["window"]) <= 0.0:
		record["presses"] = 0
		record["window"] = Tuning.server.grabbed_escape_window
	record["presses"] = int(record["presses"]) + 1
	_view_dirty = true
	if int(record["presses"]) < int(Tuning.server.grabbed_escape_presses):
		return true
	var holder := actor_for(holder_peer)
	var away := Vector3.ZERO
	if holder != null:
		away = actor.global_position - holder.global_position
	away.y = 0.0
	if away.length_squared() < 0.0001 and holder != null:
		# A held body is pinned to the holder's own x and z, so "away from the
		# holder" is nothing at all and the recoil had no direction. It used to
		# fall back on the escaping body's facing, which is whatever it happened
		# to be looking at when it was picked up -- so the same escape pushed
		# four metres a second in one run and nothing in the next. Out behind
		# the holder, which is somewhere, every time.
		away = -holder.global_transform.basis.z
		away.y = 0.0
	if away.length_squared() < 0.0001:
		away = Vector3.FORWARD
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
		Tuning.server.escape_recoil_power,
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
	force_history.append({
		"id": int(event.get("id", 0)),
		"at": float(event.get("at", 0.0)),
		"kind": int(event.get("kind", -1)),
		"target": target.name,
		"source_peer": int(event.get("source_peer", 0)),
		"base_power": float(event.get("base_power", 0.0)),
	})
	if force_history.size() > FORCE_HISTORY_MAX:
		force_history.remove_at(0)
	# v4: the knockback verdict, ruled here and carried in the event. It has to
	# be decided before the hold table is touched, because what happens to a
	# hold is the first thing the verdict decides.
	var launched := true
	if target is Player:
		launched = _rule_knockback(target as Player, event)
	elif target is Dummy:
		launched = _rule_dummy_knockback(target as Dummy, event)
	var holder_peer := holder_of(target)
	if holder_peer != 0 and launched:
		_end_hold(holder_peer, "target_pushed")
	if target is Player:
		var person_peer := (target as Player).get_multiplayer_authority()
		# 결정 2: only a body that is launched empties its hands. A body that
		# slid held its ground, so it keeps what it was carrying -- and it is
		# this table that decides, not the holder's own machine.
		if _holds.has(person_peer) and launched:
			_end_hold(person_peer, "holder_pushed")
		# B-d: the damage and the stun are decided here and the HP is written
		# here. What goes out to the owner is the push, and a stun to apply.
		_rule_hurt(target as Player, event)
		# B-e: and the push is remembered, because it is the reason this body
		# is about to be moving faster than its own legs explain.
		_remember_force(target as Player, event)
		# Stage G: and who sent it, so the fall that follows knows whether a
		# party member is the reason this body is in the air.
		_note_flight_source(target as Player, event)
	# C-0: where the blow landed, for the pictures on both screens. Stamped
	# before the event leaves so the target's own feedback and the attacker's
	# notice below point at the same spot.
	event["hit_point"] = _hit_point_for(target, event)
	ForceSystem.send(target, event)
	_notify_hit(target, event)


# C-0: the contact point of a blow: the target's surface on the side the push
# came from, at the strike's height (or the body's centre line).
func _hit_point_for(target: Node3D, event: Dictionary) -> Vector3:
	var direction: Vector3 = event.get("direction", Vector3.ZERO)
	var flat := Vector3(direction.x, 0.0, direction.z)
	var point := target.global_position
	if flat.length_squared() > 0.0001:
		point -= flat.normalized() * body_radius(target)
	if event.has("hit_y"):
		point.y = float(event["hit_y"])
	return point


# C-0: the attacker is told its blow landed. Drawn only -- hitstop, a flash
# on the target, a number -- and the message carries nothing the attacker's
# machine may rule with. The host attacker is told in place; a client over
# the wire. Recoil (a push the body asked for), throws (the rock leaving the
# hand) and the catch's empty stun carry no hit.
func _notify_hit(target: Node3D, event: Dictionary) -> void:
	var kind := int(event.get("kind", -1))
	if kind == ForceSystem.Kind.RECOIL or kind == ForceSystem.Kind.THROW or kind == ForceSystem.Kind.DEBUG:
		return
	var damage := float(event.get("damage", 0.0))
	if damage <= 0.0 and float(event.get("base_power", 0.0)) <= 0.0:
		return
	var source := int(event.get("source_peer", 0))
	if source <= 0:
		return
	var attacker := actor_for(source)
	if attacker == null or attacker == target:
		return
	var big := bool(event.get("knock_launched", false))
	var skill := String(event.get("skill", ""))
	if skill != "":
		var def := Skills.get_def(skill)
		big = big or (def != null and def.feedback_big)
	var point: Vector3 = event.get("hit_point", target.global_position)
	hits_notified += 1
	if attacker.is_local():
		if HitFeedback.instance != null:
			HitFeedback.instance.on_hit(target, point, damage, big, true, target is Player and (target as Player).is_local(), skill)
	else:
		hit_feedback.rpc_id(source, target.get_path(), point, damage, big, skill)


# Server -> the attacker. A picture and nothing else.
@rpc("any_peer", "call_remote", "reliable")
func hit_feedback(target_path: NodePath, point: Vector3, damage: float, big: bool, skill: String) -> void:
	if not result_is_server_sent("hit_feedback", multiplayer.get_remote_sender_id()):
		return
	var target := get_node_or_null(target_path) as Node3D
	if target == null or HitFeedback.instance == null or not point.is_finite():
		return
	var on_me := target is Player and (target as Player).is_local()
	HitFeedback.instance.on_hit(target, point, maxf(damage, 0.0), big, true, on_me, skill)


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
	if not ally or Tuning.server.ally_ground_damage:
		server_damage(target, damage, "force")
	if target.sync_dead:
		return
	# M-7: a caught attacker is held still through the stun path, whether or
	# not the (empty) push moved it.
	if event.has("catch_stun"):
		event["stun_apply"] = float(event["catch_stun"])
	# M-2: the knockdown. Asked for by the strike; granted to a body that is on
	# the ground (or already down, which puts it down for the full time again).
	# A body in the air returned above with its push alone. Ruled before the
	# slide verdict below: a kick is a knockdown whether or not it moved the
	# body -- a 5 m/s kick against a 7.2 m/s tolerance slides, and still fells.
	if bool(event.get("down_request", false)) and (not ally or Tuning.server.ally_ground_stun):
		if target.is_grounded_state() or target.state == Player.State.DOWNED \
				or target.state == Player.State.STUNNED:
			event["down_apply"] = Tuning.server.down_time
	# 결정 2: a slide is not a stun. The damage above is taken either way --
	# holding your ground does not mean the shove missed -- but the body that
	# stayed on its feet keeps acting.
	if not bool(event.get("knock_launched", true)):
		return
	var stun := float(event.get("stun_time", 0.0))
	if stun > 0.0 and (not ally or Tuning.server.ally_ground_stun):
		event["stun_apply"] = stun


# The same verdict for a scarecrow, through the same formula: its weight and
# strength are its race's (a plain one has none, so it is always launched, as
# it always was). Not in last_knock: that table is keyed by peer.
func _rule_dummy_knockback(target: Dummy, event: Dictionary) -> bool:
	var verdict := ForceSystem.judge_knockback(
		event,
		target.weight(),
		target.strength(),
		race_tolerance_mult(target.race_kind) if target.has_race() else 1.0,
		target.is_on_floor())
	event["knock_h_speed"] = float(verdict["h_speed"])
	event["knock_tolerance"] = float(verdict["tolerance"])
	event["knock_launched"] = bool(verdict["launched"])
	event["knock_judged"] = bool(verdict["judged"])
	return bool(verdict["launched"])


# v4's tolerance comparison. The one place it is decided, on the server, with
# the answer stamped into the event the owner is about to be handed. Returns
# whether the body is launched, which is also what the hold table reads.
#
# last_knock is the harness's read of it: the verdict as the server made it,
# per peer, so a check can assert on the ruling rather than on a log line.
func _rule_knockback(target: Player, event: Dictionary) -> bool:
	# M-7: a stunned or knocked-down body is standing on the ground for the
	# tolerance -- it is not flying, it is held still -- so a push on it is
	# judged like any other, not waved through as "already in the air".
	var verdict := ForceSystem.judge_knockback(
		event,
		target.stats.total_weight(),
		target.stats.strength,
		race_tolerance_mult(target.stats.race),
		target.is_grounded_state() or target.state == Player.State.STUNNED
			or target.state == Player.State.DOWNED)
	event["knock_h_speed"] = float(verdict["h_speed"])
	event["knock_tolerance"] = float(verdict["tolerance"])
	event["knock_launched"] = bool(verdict["launched"])
	event["knock_judged"] = bool(verdict["judged"])
	last_knock[target.get_multiplayer_authority()] = {
		"id": int(event.get("id", 0)),
		"kind": int(event.get("kind", -1)),
		"h_speed": float(verdict["h_speed"]),
		"tolerance": float(verdict["tolerance"]),
		"launched": bool(verdict["launched"]),
		"judged": bool(verdict["judged"]),
	}
	print("PLAYGROUND_KNOCK target=%s id=%d h_speed=%.2f tolerance=%.2f verdict=%s judged=%s grounded=%s" % [
		target.name, int(event.get("id", 0)),
		float(verdict["h_speed"]), float(verdict["tolerance"]),
		"launched" if bool(verdict["launched"]) else "slid",
		bool(verdict["judged"]), target.is_grounded_state()])
	return bool(verdict["launched"])


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
	_respawn_left[peer] = Tuning.server.respawn_delay
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


# N-4: the mark is chosen here, from the server's view of who is standing
# where, and carried to the owner in the message that clears it. The owner
# still does the moving -- pose is the owner's -- but where to is no longer its
# own to pick, so two screens cannot disagree about where a body came back.
func server_respawn(player: Player) -> void:
	if player == null or not is_judge():
		return
	var peer := player.get_multiplayer_authority()
	server_set_hp(player, player.stats.max_hp)
	player.sync_dead = false
	_respawn_left.erase(peer)
	_fall_watch.erase(peer)
	_kill_grace[peer] = RESPAWN_KILL_GRACE if not player.is_local() else 0.0
	var at := free_spawn_point(player)
	# The server asked for this teleport, so it does not warn about it. Long
	# enough to outlive a round trip: a client's body does not move until the
	# message telling it to has arrived, and by then two samples are long gone.
	forgive_move(peer, "", MOVE_FORGIVE_SAMPLES if player.is_local() else 30)
	if _holds.has(peer):
		_end_hold(peer, "holder_respawned")
	print("PLAYGROUND_RESPAWN_AT peer=%s at=(%.2f, %.2f, %.2f)" % [player.name, at.x, at.y, at.z])
	if player.is_local():
		player.apply_respawn(at)
	else:
		apply_respawn.rpc_id(peer, at)


# DOC: an empty spawn point, not necessarily the body's own: two bodies arriving
# on the same mark shove each other off it. Judged from the server's copy of
# the world, which is the one copy that sees everyone.
func free_spawn_point(player: Player) -> Vector3:
	var points := Net.spawn_points
	if points.is_empty():
		return player.spawn_point
	for point in points:
		var taken := false
		for node in Net.spawn_root.get_children():
			var body := node as Node3D
			if body == null or body == player:
				continue
			if Vector2(body.global_position.x - point.x, body.global_position.z - point.z).length() < 1.2:
				taken = true
				break
		if not taken:
			return point
	return points[0]


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
func apply_respawn(at: Vector3) -> void:
	if not result_is_server_sent("apply_respawn", multiplayer.get_remote_sender_id()):
		return
	var actor := actor_for(multiplayer.get_unique_id())
	if actor != null and actor.is_local():
		Net.queue_physics(func() -> void: actor.apply_respawn(at))


# R, and the way back from a fall. The owner asked for this one: an alive body
# has already moved itself, so only the vitals need clearing, while a dead one
# is waiting to be told -- leaving DEAD is this ruling and nothing else.
func _rule_respawn(actor: Player) -> Variant:
	# N-4: alive or dead, the mark is the server's to choose, so the owner is
	# always told where. It used to move itself first when alive.
	server_respawn(actor)
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
	if not Tuning.server.fall_damage_enabled or height <= Tuning.server.fall_damage_min_height:
		return true
	var damage: float = (height - Tuning.server.fall_damage_min_height) * Tuning.server.fall_damage_per_meter
	# Stage G: the damage is taken whoever started the flight. The flag only
	# decides whether a party member's launch is allowed to finish the job.
	var spared := false
	if not Tuning.server.ally_fall_death and ally_started_this_flight(peer) and damage >= actor.hp:
		damage = maxf(actor.hp - 1.0, 0.0)
		spared = true
	_clear_flight_source(peer)
	server_damage(actor, damage, "fall")
	print("PLAYGROUND_FALL_DAMAGE peer=%s height=%.2f damage=%.1f hp=%.0f ally_spared=%s" % [
		actor.name, height, damage, actor.hp, spared])
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
			watch["air_at"] = float(Time.get_ticks_msec()) / 1000.0
		else:
			watch["tracking"] = false
			watch["hold"] = maxf(0.0, float(watch["hold"]) - delta)
			if float(watch["hold"]) <= 0.0:
				watch["peak"] = y
				# Stage G: a push that never took this body off the ground is
				# not the reason for a fall it takes later. Age is what tells
				# the two apart: the record of a launch is new on the frame it
				# is made, and the body is airborne from the next step on, so
				# only a record that has sat here through the whole grace
				# without a flight is a stale one.
				_expire_flight_source(peer)
		_fall_watch[peer] = watch
		_check_move(player, delta)

		if player.sync_dead:
			_respawn_left[peer] = maxf(0.0, float(_respawn_left.get(peer, 0.0)) - delta)
			if float(_respawn_left[peer]) <= 0.0:
				server_respawn(player)
			continue
		# Out of the world. Checked here rather than on the owner so that one
		# place decides a death, from the position the server has.
		_kill_grace[peer] = maxf(0.0, float(_kill_grace.get(peer, 0.0)) - delta)
		if y < Tuning.server.kill_plane_y and float(_kill_grace[peer]) <= 0.0:
			# Stage G: out of the world is always the end, whoever put the body
			# there. ally_fall_death decides one thing only -- whether a party
			# member's launch may kill you with the landing damage -- and the
			# empty ground is not landing damage.
			_clear_flight_source(peer)
			server_kill(player, "kill_plane")


# -------------------------------------------------------- the move check
# B-1's last piece, and B-e's: the server compares how fast a body is actually
# travelling with how fast its strength and the forces it has been given could
# explain. This stage only says so in the log -- nothing is rolled back, and
# nothing is refused -- so the number it prints has to be trustworthy rather
# than merely alarming.

# Called whenever the server moves a body itself, or knows it was placed: the
# next sample would otherwise read a teleport as a sprint.
# samples: how many of the move check's windows to let pass. The default covers
# a teleport on this machine; forgiving one on a client's body needs enough to
# outlive the round trip, because the body does not move until the message
# telling it to has arrived.
func forgive_move(peer: int, reason: String, samples := MOVE_FORGIVE_SAMPLES) -> void:
	var watch: Dictionary = _move_watch.get(peer, {})
	watch["forgive"] = maxi(int(watch.get("forgive", 0)), samples)
	_move_watch[peer] = watch
	if reason != "":
		print("PLAYGROUND_MOVE_FORGIVEN peer=%d reason=%s" % [peer, reason])


# For the automated checks only, which place bodies where a person never could.
# Gated on the run being an automated one: in a session a person started, this
# does nothing at all, so it is not a way around the move check.
@rpc("any_peer", "call_remote", "reliable")
func harness_forgive_move() -> void:
	if not is_judge():
		return
	var sender := multiplayer.get_remote_sender_id()
	if not Net.auto_smoke:
		print("PLAYGROUND_HARNESS_FORGIVE_REFUSED sender=%d" % sender)
		return
	forgive_move(sender, "")


# What this body's own strength could do, split by axis: a cap that mixed them
# together would either excuse a sideways sprint or accuse an honest fall.
func move_allowance(player: Player) -> Vector2:
	var tolerance: float = Tuning.server.server_speed_tolerance
	var peer := player.get_multiplayer_authority()
	# The walk, and the leap budget a running jump may spend sideways. N-2: the
	# dash used to sit in here all the time, which let anything up to twenty
	# metres a second through; now the owner says when it dashes, so the
	# dash's speed is allowed around that notice and nowhere else.
	var horizontal := maxf(player.get_move_speed(), player.leap_speed_cap())
	var now := float(Time.get_ticks_msec()) / 1000.0
	if now - float(_dash_seen.get(peer, -100.0)) <= _dash_window(player):
		horizontal = maxf(horizontal, player.dash_speed())
	# Vertical has two honest sources: our own jump, and gravity acting over
	# the height the server watched this body reach.
	var watch: Dictionary = _fall_watch.get(peer, {})
	var drop := maxf(0.0, float(watch.get("peak", player.global_position.y)) - player.global_position.y)
	# A standing jump now spends the whole budget upward, so the fastest a body
	# may legitimately be climbing is the cap itself, not its jump velocity.
	var vertical := maxf(player.leap_speed_cap(), sqrt(2.0 * Tuning.server.gravity * drop))
	# What the server knows of a remote body's apex is a packet old, so the drop
	# it computes can be short of the real one and an honest fall then reads as
	# too fast. One sample's worth of gravity covers that gap. (Measured: a team
	# mate thrown at 18 m/s produced one warning per stage 7 run without it.)
	vertical += Tuning.server.gravity * MOVE_SAMPLE * 2.0
	var given: Dictionary = _move_watch.get(peer, {})
	return Vector2(
		horizontal * tolerance + float(given.get("h", 0.0)),
		vertical * tolerance + float(given.get("v", 0.0)))


# How long a dash can be seen lasting: the longest dash at its one speed, plus
# the sample windows it straddles and the slack for the notice.
func _dash_window(player: Player) -> float:
	return player.leap_max_range() / maxf(player.dash_speed(), 0.01) \
		+ MOVE_SAMPLE * 2.0 + DASH_WINDOW_SLACK


# Remembered when the server hands out a push, because the push is the reason
# the body is about to be fast.
func _remember_force(player: Player, event: Dictionary) -> void:
	var peer := player.get_multiplayer_authority()
	var watch: Dictionary = _move_watch.get(peer, {})
	# The same arithmetic the target will do, so the allowance matches what the
	# body is actually about to be given -- including v4's slide, which throws
	# the vertical away and so needs no vertical allowance at all.
	var change := ForceSystem.change_for(event, player.stats.total_weight())
	if not bool(event.get("knock_launched", true)):
		change.y = 0.0
	watch["h"] = maxf(float(watch.get("h", 0.0)), Vector2(change.x, change.z).length())
	watch["v"] = maxf(float(watch.get("v", 0.0)), absf(change.y))
	watch["hold"] = FORCE_MEMORY
	_move_watch[peer] = watch


func _check_move(player: Player, delta: float) -> void:
	var peer := player.get_multiplayer_authority()
	var watch: Dictionary = _move_watch.get(peer, {
		"at": player.global_position, "left": MOVE_SAMPLE, "forgive": 0,
		"h": 0.0, "v": 0.0, "hold": 0.0,
		"accepted": player.global_position, "speed_over": 0})
	# N-5: the memory of a force outlives the flight it caused. It used to run
	# out after 1.5 s while a thrown body was still falling off the cliff, and
	# the replication jitter on a long fall then read as a sprint.
	if player.state != Player.State.AIRBORNE:
		watch["hold"] = maxf(0.0, float(watch.get("hold", 0.0)) - delta)
	if float(watch["hold"]) <= 0.0:
		watch["h"] = 0.0
		watch["v"] = 0.0
	watch["left"] = float(watch.get("left", MOVE_SAMPLE)) - delta
	if float(watch["left"]) > 0.0:
		_move_watch[peer] = watch
		return
	var elapsed: float = MOVE_SAMPLE - float(watch["left"])
	var from: Vector3 = watch.get("at", player.global_position)
	var moved := player.global_position - from
	watch["left"] = MOVE_SAMPLE
	watch["at"] = player.global_position
	var skip := int(watch.get("forgive", 0)) > 0
	if skip:
		watch["forgive"] = int(watch["forgive"]) - 1
	# N-2: the exceptions below are places the server put the body itself or
	# knows it is not moving under its own power, so where it is now is
	# accepted and the run of over-samples starts again from nothing.
	# A body that is dead, being carried or standing on a moving hand is not
	# moving under its own power, and the server is the one that put it there.
	# On a wall the wall owns the body, and taking hold of one is a documented
	# one-step placement: the body is put square on the face so that the first
	# frame of climbing already looks right. That snap is not a sprint, and
	# climbing itself is slower than walking, which the allowance already
	# covers. (Measured: an attach reads as 43 m/s for one sample.)
	var excepted := skip or elapsed <= 0.0 or player.sync_dead or holder_of(player) != 0 \
		or player.state == Player.State.CLIMB or player.state == Player.State.MANTLE
	if excepted:
		watch["accepted"] = player.global_position
		watch["speed_over"] = 0
		_move_watch[peer] = watch
		return
	var allowance := move_allowance(player)
	var horizontal := Vector2(moved.x, moved.z).length() / elapsed
	var vertical := absf(moved.y) / elapsed
	if horizontal <= allowance.x and vertical <= allowance.y:
		watch["accepted"] = player.global_position
		watch["speed_over"] = 0
		_move_watch[peer] = watch
		return
	move_warnings += 1
	print("PLAYGROUND_MOVE_WARN peer=%s h=%.2f/%.2f v=%.2f/%.2f over=%.2fs state=%s" % [
		player.name, horizontal, allowance.x, vertical, allowance.y,
		elapsed, Player.State.keys()[player.state]])
	# Inside the memory of a force the server itself handed out, the body is
	# fast because the server made it so: a warning says the allowance was
	# short, and that is a tuning matter, not a correction.
	if float(watch["hold"]) > 0.0:
		watch["accepted"] = player.global_position
		watch["speed_over"] = 0
		_move_watch[peer] = watch
		return
	_move_watch[peer] = watch
	_count_over(peer, "speed")


# M-3: the race stand. Empty hands only: not holding, not held, on the ground,
# not on a wall, not down, not mid-cast. The race is written here and travels
# on the Vitals synchronizer; the debug overrides come off with it, and the HP
# is clamped to the new maximum (H-3), not refilled.
func _rule_race(actor: Player, kind: int) -> Variant:
	if not Races.is_known(kind) or actor.sync_dead:
		return null
	var peer := actor.get_multiplayer_authority()
	var why := ""
	if _holds.has(peer):
		why = "holding"
	elif holder_of(actor) != 0:
		why = "held"
	elif actor.state == Player.State.CLIMB or actor.state == Player.State.MANTLE:
		why = "climbing"
	elif actor.state == Player.State.DOWNED or actor.state == Player.State.STUNNED:
		why = "down"
	elif not actor.is_grounded_state() or actor.is_casting():
		why = "not_standing"
	if why != "":
		last_refusal = why
		print("PLAYGROUND_RACE_REFUSED peer=%s race=%s why=%s" % [actor.name, Races.label_for(kind), why])
		return null
	actor.stats.race = kind
	actor.stats.clear_overrides()
	actor.stats.gear_weight = 0.0
	server_set_hp(actor, actor.hp)
	forgive_move(peer, "race_changed")
	print("PLAYGROUND_RACE peer=%s race=%s strength=%.0f weight=%.0f max_hp=%.0f max_stamina=%.0f" % [
		actor.name, Races.label_for(kind), actor.stats.strength, actor.stats.race_weight,
		actor.stats.max_hp, actor.stats.max_stamina])
	return true


# M-3: the weapon rack; M-5: ruled here and written here, onto the Vitals
# synchronizer the server owns. Every peer applies what it carries, so there
# is one weapon per body and a client writing its own copy loses it on the
# next packet. The owner's set_weapon() is the request that lands here.
func _rule_weapon(actor: Player, kind: int) -> Variant:
	if not WeaponKinds.LABELS.has(kind) or actor.sync_dead:
		return null
	var peer := actor.get_multiplayer_authority()
	if _holds.has(peer):
		last_refusal = "holding"
		print("PLAYGROUND_WEAPON_REFUSED peer=%s why=holding" % actor.name)
		return null
	actor.sync_weapon = kind
	print("PLAYGROUND_WEAPON peer=%s kind=%s" % [actor.name, WeaponKinds.LABELS.get(kind, "?")])
	return true


# What the server holds this peer to be carrying: its own copy's sync_weapon,
# which only _rule_weapon writes.
func weapon_of(peer: int) -> int:
	var actor := actor_for(peer)
	return actor.sync_weapon if actor != null else WeaponKinds.Kind.NONE


# M-1: a slot's cast. The SkillDef names the rule; this door keeps the clock.
# Inside the caster's own recovery, or inside the skill's cooldown, the cast is
# refused -- the owner's slot would not have sent it, so one that arrives is a
# forged or a stale one. Judged against the server's copy of the body, which
# has to be standing.
func _rule_skill(actor: Player, payload: Dictionary) -> Variant:
	var def := Skills.get_def(String(payload.get("skill", "")))
	if def == null or actor.sync_dead:
		return null
	var peer := actor.get_multiplayer_authority()
	var now := Time.get_ticks_msec()
	if now < int(_skill_lock.get(peer, 0)):
		print("PLAYGROUND_SKILL_REFUSED by=%s skill=%s why=recovery" % [actor.name, def.id])
		return null
	var cooldowns: Dictionary = _skill_cooldown.get(peer, {})
	if now < int(cooldowns.get(def.id, 0)):
		print("PLAYGROUND_SKILL_REFUSED by=%s skill=%s why=cooldown" % [actor.name, def.id])
		return null
	if not actor.is_grounded_state():
		print("PLAYGROUND_SKILL_REFUSED by=%s skill=%s why=state_%s" % [
			actor.name, def.id, Player.State.keys()[actor.state]])
		return null
	var direction := _direction_of(payload)
	# M-7: the intent arrives at the start of the windup, so the recovery lock
	# and the cooldown run from the impact, not from now.
	var impact_ms := int(def.impact_time() * 1000.0)
	_skill_lock[peer] = now + impact_ms + int(def.value("recovery") * 1000.0)
	cooldowns[def.id] = now + impact_ms + int(def.value("cooldown") * 1000.0)
	_skill_cooldown[peer] = cooldowns
	skills_ruled += 1
	match def.id:
		"shove":
			return _rule_shove(actor, direction)
		"grab":
			return _rule_grab(actor, _target_for(payload))
	schedule_strike(actor, def, direction)
	return true


# M-7: a strike is booked, not ruled, when its intent arrives: the ruling runs
# at the impact time, and until then it can be caught (or, in the combat stage,
# parried) or cancelled by what happens to its caster. One per body.
func schedule_strike(actor: Node3D, def: SkillDef, direction: Vector3) -> void:
	var now := Time.get_ticks_msec()
	_pending_strikes[actor] = {
		"def": def,
		"direction": direction,
		"at": now + int(def.impact_time() * 1000.0),
		"since": now,
	}
	print("PLAYGROUND_STRIKE_SCHEDULED by=%s skill=%s in=%.2fs" % [actor.name, def.id, def.impact_time()])


func pending_strike(actor: Node3D) -> Dictionary:
	return _pending_strikes.get(actor, {})


# Every step: strikes whose caster was stunned, knocked down, grabbed or killed
# in the windup are cancelled; the rest land when their time comes.
func _run_pending_strikes() -> void:
	var now := Time.get_ticks_msec()
	for actor: Variant in _pending_strikes.keys():
		if not is_instance_valid(actor):
			_pending_strikes.erase(actor)
			continue
		var record: Dictionary = _pending_strikes[actor]
		var def: SkillDef = record["def"]
		if actor is Player:
			var caster := actor as Player
			var interrupted := caster.sync_dead or caster.state == Player.State.STUNNED \
				or caster.state == Player.State.DOWNED or caster.state == Player.State.GRABBED \
				or caster.state == Player.State.DEAD
			if interrupted:
				_pending_strikes.erase(actor)
				strikes_cancelled += 1
				print("PLAYGROUND_STRIKE_CANCELLED by=%s skill=%s why=%s" % [
					caster.name, def.id, Player.State.keys()[caster.state]])
				continue
		elif actor is Dummy:
			# A scarecrow picked up or caught mid-windup does not swing.
			if holder_of(actor) != 0 or (actor as Dummy).attack_phase == "stunned":
				_pending_strikes.erase(actor)
				strikes_cancelled += 1
				print("PLAYGROUND_STRIKE_CANCELLED by=%s skill=%s why=%s" % [
					actor.name, def.id, "held" if holder_of(actor) != 0 else "caught"])
				continue
		if now >= int(record["at"]):
			_pending_strikes.erase(actor)
			_rule_strike(actor, def, record["direction"])


# M-7: the catch. A grab aimed at a body whose strike is booked and inside its
# window -- catch_window before the impact, up to the impact -- by a catcher
# strong enough (strength >= catch_force x catch_power_mult) and in reach:
# the strike is cancelled, the attacker is held still for catch_stun through
# the stun path, and if the catcher can lift them the hold follows. The catcher
# is otherwise free (no GRABBING state): a kick or the other hand's weapon can
# follow at once. Anything short of this falls through to the ordinary grab.
func _try_catch(actor: Player, target: Node3D) -> bool:
	if not _pending_strikes.has(target):
		return false
	var peer := actor.get_multiplayer_authority()
	if _holds.has(peer) or holder_of(actor) != 0 or not actor.is_grounded_state() or actor.sync_dead:
		return false
	var record: Dictionary = _pending_strikes[target]
	var def: SkillDef = record["def"]
	var now := Time.get_ticks_msec()
	var at := int(record["at"])
	var window_ms := int(def.catch_window_time() * 1000.0)
	if now < at - window_ms or now > at:
		print("PLAYGROUND_CATCH_MISSED by=%s target=%s skill=%s offset=%.3fs window=%.2fs" % [
			actor.name, target.name, def.id, float(at - now) / 1000.0, def.catch_window_time()])
		return false
	if actor.global_position.distance_to(target.global_position) > (
			Tuning.server.grab_range + actor.radius() + INTENT_RANGE_SLACK):
		return false
	var needed := def.catch_force_value() * Tuning.server.catch_power_mult
	if actor.stats.strength < needed:
		print("PLAYGROUND_CATCH_WEAK by=%s target=%s skill=%s strength=%.0f needed=%.0f" % [
			actor.name, target.name, def.id, actor.stats.strength, needed])
		return false
	_pending_strikes.erase(target)
	catches += 1
	last_catch = {"by": peer, "target": target.name, "skill": def.id,
		"before_impact": float(at - now) / 1000.0, "lifted": false}
	if target is Player:
		var toward := target.global_position - actor.global_position
		toward.y = 0.0
		if toward.length_squared() < 0.0001:
			toward = Vector3.FORWARD
		var event := ForceSystem.make_event(
			ForceSystem.Kind.KNOCKBACK, toward.normalized(), 0.0, 0.0, peer, false, 0.0, 0.0)
		event["catch_stun"] = Tuning.server.catch_stun
		send_force(target, event)
	elif target is Dummy:
		# The scarecrow has no states to stun; its pattern stands still instead.
		(target as Dummy).apply_catch_stun(Tuning.server.catch_stun)
	if weight_of(target) <= lift_limit(actor) and holder_of(target) == 0:
		_take_hold(peer, target)
		last_catch["lifted"] = true
	print("PLAYGROUND_CATCH by=%s target=%s skill=%s before_impact=%.3fs lifted=%s" % [
		actor.name, target.name, def.id, last_catch["before_impact"], last_catch["lifted"]])
	return true


# M-1: the generic strike -- a rectangle in front of the heading, like the
# shove's, with the SkillDef's reach, width, damage and push. M-2 fills in the
# heights and the knockdown.
func _rule_strike(actor: Node3D, def: SkillDef, direction: Vector3) -> Variant:
	# M-7: a scarecrow strikes too. It has no peer, no party and the human's
	# body size; behind its push is its race's strength, or none for a plain one.
	var caster := actor as Player
	var peer := caster.get_multiplayer_authority() if caster != null else 0
	var caster_strength := 0.0
	if caster != null:
		caster_strength = caster.stats.strength
	elif actor is Dummy:
		caster_strength = (actor as Dummy).strength()
	var caster_scale := caster.body_scale() if caster != null else 1.0
	var reach := def.value("reach")
	var half_width := def.value("width") * 0.5
	var forward := Vector3(direction.x, 0.0, direction.z)
	if forward.length_squared() < 0.0001:
		return null
	forward = forward.normalized()
	var side := Vector3(-forward.z, 0.0, forward.x)
	var shape := SphereShape3D.new()
	shape.radius = sqrt(reach * reach + half_width * half_width)
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = Transform3D(Basis.IDENTITY, actor.global_position)
	# M-2: a knockdown strike (the kick) reaches rocks too, and pushes them.
	params.collision_mask = Player.PLAYER_LAYER | Dummy.LAYER
	if def.outcome == SkillDef.Outcome.DOWN:
		params.collision_mask |= Layers.THROWABLE
	params.collide_with_areas = false
	params.exclude = [actor.get_rid()]
	# M-2: the strike has a height. The punch is at the chest, the kick at the
	# legs (the SkillDef's strike_height, off the body's centre); a target whose
	# body does not cross that height is not hit. A body on a knee-high step is
	# still punched; one a ledge up is not kicked.
	var strike_y := actor.global_position.y + def.strike_height * caster_scale
	var hits := 0
	var downed := 0
	for collision in actor.get_world_3d().direct_space_state.intersect_shape(params, 8):
		var body := collision.get("collider") as Node3D
		if body == null or body == actor:
			continue
		var offset := body.global_position - actor.global_position
		offset.y = 0.0
		var along := offset.dot(forward)
		var across := absf(offset.dot(side))
		var target_radius := body_radius(body)
		if along <= -target_radius or along > reach + target_radius:
			continue
		if across > half_width + target_radius:
			continue
		if absf(body.global_position.y - strike_y) > strike_band(body):
			continue
		if body is Rock and holder_of(body) != 0:
			continue
		var is_ally := body is Player and caster != null and Tuning.server.same_party
		var push := (forward + Vector3.UP * Tuning.server.shove_up_bias).normalized()
		var event := ForceSystem.make_event(
			ForceSystem.Kind.KNOCKBACK,
			push,
			def.value("knock_power"),
			caster_strength,
			peer,
			is_ally,
			def.value("damage"),
			0.0)
		event["skill"] = def.id
		event["hit_y"] = strike_y
		# M-2: the knockdown is asked for here and ruled in _rule_hurt, like
		# the stun: only a body on the ground goes down; in the air the push is
		# all it gets. A body already down is put down again, for the full time.
		if def.outcome == SkillDef.Outcome.DOWN:
			event["down_request"] = true
		send_force(body, event)
		hits += 1
		if float(event.get("down_apply", 0.0)) > 0.0:
			downed += 1
	last_strike = {"skill": def.id, "hits": hits, "downed": downed, "by": actor.name,
		"at_unix": Time.get_unix_time_from_system()}
	print("PLAYGROUND_SKILL by=%s skill=%s hits=%d downed=%d" % [actor.name, def.id, hits, downed])
	return hits


# N-2: the dash notice. Never refused -- the dash has already happened on the
# owner's machine -- but one inside the cooldown is a sample over the cap, and
# enough of those in a row put the body back like any other sprint.
func _rule_dash(actor: Player) -> Variant:
	var peer := actor.get_multiplayer_authority()
	var now := float(Time.get_ticks_msec()) / 1000.0
	var last := float(_dash_seen.get(peer, -100.0))
	_dash_seen[peer] = now
	if now - last < Tuning.server.dash_cooldown - DASH_COOLDOWN_SLACK:
		print("PLAYGROUND_DASH_COOLDOWN_OVER peer=%s gap=%.2f cooldown=%.2f" % [
			actor.name, now - last, Tuning.server.dash_cooldown])
		_count_over(peer, "dash_cooldown")
	else:
		var watch: Dictionary = _move_watch.get(peer, {})
		watch["dash_cooldown_over"] = 0
		_move_watch[peer] = watch
	return true


# One sample the check could not explain. Enough in a row and the body goes
# back to the last position the check accepted. Each reason keeps its own run:
# a dash inside the cooldown is not undone by the walking speed between dashes
# being fine, and a sprint is not undone by an honest dash.
func _count_over(peer: int, why: String) -> void:
	var watch: Dictionary = _move_watch.get(peer, {})
	var key := why + "_over"
	watch[key] = int(watch.get(key, 0)) + 1
	if int(watch[key]) >= MOVE_CORRECT_SAMPLES:
		watch[key] = 0
		_correct_move(peer, watch, why)
	_move_watch[peer] = watch


# The correction itself: the owner is told where the server last accepted it,
# and the next samples are let through while the snap back travels. Pose is
# still the owner's -- the owner does the snapping -- this only says where to.
func _correct_move(peer: int, watch: Dictionary, why: String) -> void:
	var player := actor_for(peer)
	if player == null:
		return
	var to: Vector3 = watch.get("accepted", player.global_position)
	var from := player.global_position
	move_corrections += 1
	last_correction = {"peer": peer, "to": to, "from": from, "why": why}
	print("PLAYGROUND_MOVE_CORRECTED peer=%s why=%s from=(%.2f, %.2f, %.2f) to=(%.2f, %.2f, %.2f) total=%d" % [
		player.name, why, from.x, from.y, from.z, to.x, to.y, to.z, move_corrections])
	forgive_move(peer, "", MOVE_FORGIVE_SAMPLES if player.is_local() else MOVE_CORRECT_FORGIVE_REMOTE)
	if player.is_local():
		player.apply_correction(to)
	else:
		correct_position.rpc_id(peer, to)


# Server -> owner. Carries the position the check last accepted; the owner
# snaps there, stops, and drops whatever order it was carrying out.
@rpc("any_peer", "call_remote", "reliable")
func correct_position(at: Vector3) -> void:
	if not result_is_server_sent("correct_position", multiplayer.get_remote_sender_id()):
		return
	var actor := actor_for(multiplayer.get_unique_id())
	if actor != null and actor.is_local():
		actor.apply_correction(at)


# ------------------------------------------------------------ the exceptions
# E-5, all five of them, answered from the table once per physics step rather
# than by a case inside each action.

func _physics_process(delta: float) -> void:
	if not is_judge():
		return
	for peer: int in _shove_cooldown.keys():
		_shove_cooldown[peer] = maxf(0.0, float(_shove_cooldown[peer]) - delta)
	_enforce_holds(delta)
	_place_held_people(delta)
	_run_pending_strikes()
	_watch_vitals(delta)
	# N-1: any write to the server's table reaches the replicas within a step,
	# whoever made it. The heartbeat below repairs a dropped push.
	if multiplayer.has_multiplayer_peer() and Tuning.export_server() != _server_tuning_pushed:
		_push_server_tuning()
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
		record["settle"] = maxf(0.0, float(record.get("settle", 0.0)) - delta)
		if float(record["settle"]) == 0.0 \
				and (bool(record["confirmed"]) or float(record["grace"]) == 0.0):
			# Stunned, dead or picked up says nothing about a jump, so it is
			# acted on at once; only the airborne verdict needs the window.
			if _hold_lost_at_once(holder):
				_end_hold(holder_peer, "holder_state")
				continue
			if _can_keep_holding(holder):
				record["lost"] = 0.0
			else:
				record["lost"] = float(record.get("lost", 0.0)) + delta
				if float(record["lost"]) >= HOLD_LOST_GRACE:
					_end_hold(holder_peer, "holder_state")
					continue
		# A body that died in someone's hands is not still in them.
		if target is Player and (target as Player).state == Player.State.DEAD:
			_end_hold(holder_peer, "target_dead")


# N-3: a held person rides the holder's hand on the server's say-so, the way a
# rock and a scarecrow already did. Placed on the server every step, pushed to
# every peer on the rock's interval; the owner applies what arrives and writes
# no position of its own while held. One source for where a carried body is,
# so at 200 ms the two screens agree instead of each following its own copy of
# the holder.
func _place_held_people(delta: float) -> void:
	_held_push_left -= delta
	var push := _held_push_left <= 0.0
	if push:
		_held_push_left = SyncRules.STATE_INTERVAL
	for holder_peer: int in _holds.keys():
		var record: Dictionary = _holds[holder_peer]
		var person := get_node_or_null(record["target"] as NodePath) as Player
		var holder := actor_for(holder_peer)
		if person == null or holder == null:
			continue
		var at := holder.hand_position()
		person.set_held_position(at)
		if push and multiplayer.has_multiplayer_peer():
			push_held_position.rpc(person.get_path(), at)


# Server -> every peer, unreliable like a rock's state: a dropped one is
# replaced by the next within 0.05 s.
@rpc("any_peer", "call_remote", "unreliable_ordered")
func push_held_position(path: NodePath, at: Vector3) -> void:
	if not result_is_server_sent("push_held_position", multiplayer.get_remote_sender_id()):
		return
	var person := get_node_or_null(path) as Player
	if person != null:
		person.set_held_position(at)


# Stage E's put-down, moved here from the held body's own machine: beside the
# holder, not dropped from hand height above their head. The owner is told
# where, and takes its pose back from there. The next move samples are
# forgiven: a metre in a step is the put-down, not a sprint.
func _release_person(holder: Player, person: Player, away_hint := Vector3.ZERO) -> void:
	var at := person.global_position
	if holder != null:
		# The side the caller names (a throw's heading), else away from the
		# holder, else behind them.
		var away := away_hint
		if away.length_squared() < 0.0001:
			away = person.global_position - holder.global_position
		away.y = 0.0
		if away.length_squared() < 0.0001:
			# Pinned to the holder's own x and z, so there is no "away" to use:
			# out behind them, the same side the escape recoil pushes.
			away = -holder.global_transform.basis.z
			away.y = 0.0
		if away.length_squared() < 0.0001:
			away = Vector3.FORWARD
		away = away.normalized()
		# M-4: clear of both bodies, whatever their sizes.
		var apart := (holder.radius() + person.radius()) * 1.1
		at = Vector3(
			holder.global_position.x + away.x * apart,
			holder.global_position.y - holder.half_height() + person.half_height(),
			holder.global_position.z + away.z * apart)
	var peer := person.get_multiplayer_authority()
	forgive_move(peer, "", MOVE_FORGIVE_SAMPLES if person.is_local() else MOVE_CORRECT_FORGIVE_REMOTE)
	print("PLAYGROUND_RELEASE_AT peer=%s at=(%.2f, %.2f, %.2f)" % [person.name, at.x, at.y, at.z])
	if person.is_local():
		person.apply_release(at)
	else:
		person.clear_held_position()
		release_at.rpc_id(peer, at)


# The scarecrow's release: the person's geometry (above) on a body the server
# owns outright. Found in play: thrown at a cursor within a metre -- or at
# nothing, which the arc solver answers with "straight up" -- it came down on
# the thrower's head and stood there until its return timer walked it off
# (measured: 0.00 m along, 1.80 m up, on_floor, for two seconds). A throw lets
# go beside the thrower at the hand's height, so the arc solved from the hand
# stays true and whatever comes straight down lands beside the body. A put-down
# sets it on the ground beside the holder, as a rock or a person is.
func _release_dummy(holder: Player, dummy: Dummy, away_hint: Vector3, thrown: bool) -> void:
	if holder == null:
		return
	var away := away_hint
	away.y = 0.0
	if away.length_squared() < 0.0001:
		away = -holder.global_transform.basis.z
		away.y = 0.0
	if away.length_squared() < 0.0001:
		away = Vector3.FORWARD
	away = away.normalized()
	var apart := (holder.radius() + Dummy.RADIUS) * 1.1
	var y := holder.hand_position().y if thrown \
		else holder.global_position.y - holder.half_height() + Dummy.HALF_HEIGHT
	var at := Vector3(holder.global_position.x + away.x * apart, y,
		holder.global_position.z + away.z * apart)
	dummy.release_to(at)
	print("PLAYGROUND_RELEASE_AT peer=%s at=(%.2f, %.2f, %.2f)" % [dummy.name, at.x, at.y, at.z])


# Server -> owner. Reliable, and sent before the row goes, so by the time the
# owner sees itself free it already knows where it was put.
@rpc("any_peer", "call_remote", "reliable")
func release_at(at: Vector3) -> void:
	if not result_is_server_sent("release_at", multiplayer.get_remote_sender_id()):
		return
	var actor := actor_for(multiplayer.get_unique_id())
	if actor != null and actor.is_local():
		actor.apply_release(at)


# The half of the verdict that carries no ambiguity: none of these three can
# be confused with a body partway through its own jump, so none of them waits
# for HOLD_LOST_GRACE.
func _hold_lost_at_once(holder: Player) -> bool:
	return holder.state == Player.State.STUNNED \
			or holder.state == Player.State.DEAD \
			or holder.state == Player.State.GRABBED \
			or holder.state == Player.State.DOWNED


# Stage E follow-up: 7-6 is narrowed to what it was written for. A holder keeps
# what it is carrying through its own jump -- the load is in the jump's weight,
# so the jump is already shorter for it -- and drops it when something takes the
# ground away: a push (which send_force handles before the force even goes out),
# a fall, a stun, or being picked up.
func _can_keep_holding(holder: Player) -> bool:
	if holder.state == Player.State.STUNNED or holder.state == Player.State.DEAD \
			or holder.state == Player.State.GRABBED or holder.state == Player.State.DOWNED:
		return false
	if holder.state == Player.State.AIRBORNE:
		# Its own jump keeps the hold; coming off an edge does not.
		return holder.sync_jumped
	return true


# Stage G: the force that put this body in the air, kept until the fall it
# leads to has been ruled on. Not a time window: a co-op launch can be in the
# air for well over a second and the landing still has to know what started it.
func _note_flight_source(target: Player, event: Dictionary) -> void:
	var peer := target.get_multiplayer_authority()
	var source := int(event.get("source_peer", 0))
	if source == 0 or source == peer:
		return
	_flight_source[peer] = {
		"by": source,
		"ally": bool(event.get("is_ally_source", false)),
		"id": int(event.get("id", 0)),
		"at": float(Time.get_ticks_msec()) / 1000.0,
	}


func ally_started_this_flight(peer: int) -> bool:
	var record: Dictionary = _flight_source.get(peer, {})
	return bool(record.get("ally", false))


func _clear_flight_source(peer: int) -> void:
	_flight_source.erase(peer)


func _expire_flight_source(peer: int) -> void:
	var record: Dictionary = _flight_source.get(peer, {})
	if record.is_empty():
		return
	var age := float(Time.get_ticks_msec()) / 1000.0 - float(record.get("at", 0.0))
	if age >= FALL_PEAK_HOLD:
		_flight_source.erase(peer)


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
