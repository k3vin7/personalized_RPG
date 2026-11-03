# Harness only -- the automated checks' shared waits. Nothing in here rules
# anything or runs in a session a person started; the game never loads it.
class_name Harness
extends RefCounted

const STEP := 1.0 / 120.0

# A client's body teleports in the same tick its forgive RPC leaves, and the
# two travel as separate datagrams (the RPC on the reliable channel, the
# position on the synchronizer's). Under jitter the position can overtake
# the forgiveness, and the move check then reads the park as a 20 m/s sprint
# (measured: one warning per C1e run through the 80 ms + 20 ms proxy). The
# server forgives two samples (0.2 s) from the RPC's arrival, so the body
# waits this long before it moves: longer than the proxy's whole jitter
# spread (two packets, 20 ms either side = 40 ms), well inside the window.
# One physics tick (8 ms) is not enough -- reordering stays about one park
# in three.
const FORGIVE_LEAD := 0.05

# The scarecrow walks back to its mark RETURN_DELAY after the last hit and
# refills its HP only once it stands inside MARK_BAND of it (dummy.gd). A
# body left on the approach stops the walk short: the host standing 1.0 m
# from the mark after the walking thrust left it 0.49 m off for the whole
# wait, so the HP never refilled, and the refill then landed inside a later
# measurement (a 9 slam read as 4.2). Anything nearer than APPROACH is
# stepped ASIDE first.
const MARK_BAND := 0.2
const APPROACH := 1.5
const ASIDE := 3.0
const HOME_WAIT := 8.0
const REFILL_WAIT := 3.5


# Client side: call after placed() and before the position write.
static func forgive_lead(tree: SceneTree) -> void:
	var waited := 0.0
	while waited < FORGIVE_LEAD:
		await tree.physics_frame
		waited += STEP


# Host side: the scarecrow on its mark, on the floor, and refilled.
# `local` is this machine's body (stepped aside if it is in the way);
# `mate` is only looked at, since parking it is the check's own RPC.
static func dummy_home(dummy: Dummy, judge: ServerAuthority, local: Player, mate: Player,
		tree: SceneTree, note: Callable) -> void:
	if local != null and judge != null and _on_approach(local, dummy):
		var flat := local.global_position - dummy.home
		flat.y = 0.0
		var away := flat.normalized() if flat.length() > 0.01 else Vector3(0.0, 0.0, 1.0)
		var aside := dummy.home + away * ASIDE
		judge.forgive_move(local.get_multiplayer_authority(), "")
		Net.queue_physics(func() -> void:
			local.global_position = Vector3(aside.x, local.global_position.y, aside.z)
			local.velocity = Vector3.ZERO
			local.movement.cancel_target())
		for _frame in range(3):
			await tree.physics_frame
	if mate != null and _on_approach(mate, dummy):
		note.call("scarecrow %s: the mate stands %.2f m from its mark, on the walk home" % [
			dummy.name, _flat_distance(mate, dummy)])
	var waited := 0.0
	while waited < HOME_WAIT and (dummy.global_position.distance_to(dummy.home) > MARK_BAND or not dummy.is_on_floor()):
		await tree.physics_frame
		waited += STEP
	var refill := 0.0
	while refill < REFILL_WAIT and dummy.hp < dummy.max_hp() - 0.01:
		await tree.physics_frame
		refill += STEP
	if dummy.global_position.distance_to(dummy.home) > MARK_BAND or dummy.hp < dummy.max_hp() - 0.01:
		note.call("scarecrow %s is %.2f m off its mark, hp %.0f/%.0f, after %.1f + %.1f s" % [
			dummy.name, dummy.global_position.distance_to(dummy.home), dummy.hp, dummy.max_hp(), waited, refill])


static func _flat_distance(body: Node3D, dummy: Dummy) -> float:
	var flat := body.global_position - dummy.home
	flat.y = 0.0
	return flat.length()


static func _on_approach(body: Node3D, dummy: Dummy) -> bool:
	return _flat_distance(body, dummy) < APPROACH
