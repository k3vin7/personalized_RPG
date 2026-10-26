class_name PlayerMovement
extends Node

# Click to move. Only the local player ever runs this.
#
# Waypoints are consumed in XZ, not in 3D: the body origin sits a capsule half
# height above the navigation surface, so a 3D distance test never reaches a
# waypoint and the character stalls on top of it.

const DRAG_RETARGET_INTERVAL := 0.1
# DOC: the click ray checks layers 1, 2, 3 and 5 only - ground, walls, climb
# walls and rocks. Players and dummies are deliberately not in it: you aim at
# the ground behind them.
const CLICK_MASK := Layers.TERRAIN | Layers.THROWABLE
const ARRIVE_TOLERANCE := 0.3
const PATH_LOOKAHEAD := 0.75
const PATH_QUERY_RETRIES := 4
# A click whose path ends further than this from where it was aimed did not
# reach: the target is across something.
const UNREACHABLE_DISTANCE := 0.5
# Pressing a touch early or a touch late still jumps.
const JUMP_BUFFER := 0.1
const COYOTE_TIME := 0.1
# How far out a wall still counts as within reach when the catch is attempted.
# Longer than the jump buffer on purpose: a catch is aimed at a wall you are
# still travelling towards, so the press lands well before the contact does.
const CATCH_BUFFER := 0.3
const CATCH_REACH := 0.3
const CATCH_PROBES := 8
# DOC: the stand in for a shield bash until there is a shield. Ground only.
# The shove's reach, angle, ally bonus and cooldown moved to PhysicsTuning in
# B-c, with the ruling: they are numbers the server judges with now.
const CARRY_SPEED_SCALE := 0.7

enum Armed {
	NONE,
	JUMP,
	DASH,
}

var player: Player

var _agent: NavigationAgent3D
var _has_target := false
var _target := Vector3.ZERO
var _path := PackedVector3Array()
var _path_index := 0
var _pending_frames := 0
var _path_dirty := false
var _retries := 0
var _drag_left := 0.0
var _jump_buffer_left := 0.0
var _coyote_left := 0.0
var _catch_buffer_left := 0.0
var _aim_override := Vector3.INF
var _intent_direction := Vector3.ZERO
var _intent_left := 0.0
var _pending_air_target: Variant = null
var _dash_left := 0.0
var _dash_total := 0.0
var _dash_direction := Vector3.ZERO
var _dash_cooldown_left := 0.0
# Set when a launch came out of a dash, which spends the leap budget on
# distance rather than height.
var _launch_from_dash := false
# 5-chapter smart key. With it off, a key arms the action and shows where it
# would go; the left button casts. Jump and dash share this, and a basic attack
# is meant to join them without a second mechanism.
var _armed := Armed.NONE
var _indicator: AimIndicator
var _climb_wall: CollisionObject3D
var _climb_point := Vector3.ZERO
var _climb_normal := Vector3.ZERO


func setup(owner_player: Player) -> void:
	player = owner_player
	_agent = NavigationAgent3D.new()
	_agent.name = "NavigationAgent3D"
	# Lifts returned points to the body origin so our own XZ consumption lines
	# up with where the body actually is.
	_agent.path_height_offset = Player.BODY_HALF_HEIGHT
	_agent.radius = Player.BODY_RADIUS
	_agent.avoidance_enabled = false
	player.add_child(_agent)

	# The owner's own view of where a key would send it. Local only.
	_indicator = AimIndicator.new()
	_indicator.name = "AimIndicator"
	player.get_tree().current_scene.add_child(_indicator)
	player.add_owned_view(_indicator)
	set_physics_process(true)


func cancel_target() -> void:
	_has_target = false
	_path.clear()
	_path_index = 0
	_retries = 0
	_path_dirty = false


# Same path the key takes: the buffer is the only way in, so a test and a key
# press go through identical code.
# Space. With the smart key on this jumps now; with it off it arms the jump and
# shows where it would land, and the left button casts it.
func press_jump() -> void:
	if not player.is_grounded_state():
		# Off the ground Space is not a jump to aim. It is the wall catch, and
		# the coyote jump for a body that walked off something a moment ago,
		# and the jump out of a dash -- all three decided in the physics step
		# from these two buffers. So the press goes straight to them and arms
		# nothing: there is no cursor to pick, and nothing to left-click.
		#
		# C-2 sent every press through the smart key and broke all three: with
		# the key off (the default) a press in the air only armed a jump that
		# could never be cast, so a body could no longer take hold of a wall.
		_disarm()
		_jump_buffer_left = JUMP_BUFFER
		_catch_buffer_left = CATCH_BUFFER
		return
	if Tuning.values.smart_key_enabled:
		cast_jump()
		return
	_arm(Armed.JUMP)


# What the jump actually is, once something has decided to cast it.
func cast_jump() -> void:
	_disarm()
	_jump_buffer_left = JUMP_BUFFER
	_catch_buffer_left = CATCH_BUFFER


func request_jump() -> void:
	cast_jump()


func press_dash() -> void:
	if Tuning.values.smart_key_enabled:
		request_dash()
		return
	_arm(Armed.DASH)


func armed_action() -> int:
	return _armed


func aim_indicator() -> AimIndicator:
	return _indicator


# Esc, the right button, and whatever else means "never mind".
func cancel_armed() -> void:
	_disarm()


func _arm(action: int) -> void:
	_armed = action
	_refresh_indicator()


func _disarm() -> void:
	if _armed == Armed.NONE:
		return
	_armed = Armed.NONE
	_refresh_indicator()


# The left button, and the one place an armed action turns into a cast.
func cast_armed() -> bool:
	match _armed:
		Armed.JUMP:
			cast_jump()
			return true
		Armed.DASH:
			_disarm()
			request_dash()
			return true
	return false


func _refresh_indicator() -> void:
	if _indicator == null:
		return
	if _armed == Armed.NONE:
		_indicator.hide_all()
		return
	if _armed == Armed.DASH:
		# A dash is a line, so it is drawn as one: an arrow from here to there.
		var dash := dash_plan()
		_indicator.show_arrow(player.global_position, dash["landing"] as Vector3,
			bool(dash["clamped"]))
		return
	var plan := jump_plan(cursor_jump_target())
	_indicator.show_aim(player.global_position, player.leap_max_range(),
		plan["landing"] as Vector3, bool(plan["clamped"]))


func has_target() -> bool:
	return _has_target


func intent_direction() -> Vector3:
	return _intent_direction


func intent_seconds_left() -> float:
	return _intent_left


func _clear_intent() -> void:
	_intent_direction = Vector3.ZERO
	_intent_left = 0.0


func set_target(world_point: Vector3) -> void:
	if player.state == Player.State.AIRBORNE:
		# In the air the click books a destination and nothing else: the arc is
		# already decided and must not bend.
		_pending_air_target = world_point
		return
	# An order to where we already stand is not an order. Without this, holding
	# the button with the cursor over your own feet arrives, cancels and
	# re-orders every tenth of a second, which reads as a flickering state.
	if _flat_distance(player.global_position, world_point) <= ARRIVE_TOLERANCE:
		return
	# A fresh click replaces any intent the last blocked one left behind.
	_clear_intent()
	_target = world_point
	_has_target = true
	_agent.target_position = world_point
	_retries = 0
	# The agent reports its previous path as finished until the server has taken
	# the new target, so the result is only read after a few frames. The path we
	# already have stays in use until then: a held right button re-issues the
	# order ten times a second, and dropping the path on each one would stop the
	# body dead between queries and flicker the state.
	_pending_frames = 3
	_path_dirty = true


func _unhandled_input(event: InputEvent) -> void:
	if not player.is_local():
		return
	if event.is_action_pressed("restart"):
		Net.queue_physics(player.respawn)
		get_viewport().set_input_as_handled()
		return
	if player.grab != null and player.grab.is_held():
		# Held in someone's hands: Space is the only input that still does
		# anything, and it means "let me go".
		if event.is_action_pressed("jump"):
			Net.queue_physics(player.grab.escape_press)
		get_viewport().set_input_as_handled()
		return
	if player.climb != null and player.climb.is_climbing():
		# On a wall the same two buttons mean different things: aim on the wall
		# face, or let go of it.
		if event.is_action_pressed("move_click"):
			var mouse := player.get_viewport().get_mouse_position()
			var camera := player.camera.camera
			player.climb.aim_at(camera.project_ray_origin(mouse), camera.project_ray_normal(mouse))
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("jump"):
			Net.queue_physics(player.climb.detach)
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("cancel"):
		# Esc drops an armed action first, and the move order only if there was
		# nothing armed.
		if _armed != Armed.NONE:
			_disarm()
		else:
			cancel_target()
			_clear_intent()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("cast_click"):
		# The left button casts what is armed, and means nothing otherwise.
		if _armed != Armed.NONE:
			var action := _armed
			Net.queue_physics(func() -> void:
				if action == Armed.JUMP:
					cast_jump()
				else:
					request_dash())
			_disarm()
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("move_click"):
		# The right button still moves while something is armed; arming is not
		# a mode that swallows input, so the move counts as the cancel.
		_disarm()
		_click_to_target()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("debug_shove"):
		Net.queue_physics(shove)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("grab_throw"):
		Net.queue_physics(interact)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("dash"):
		Net.queue_physics(press_dash)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("jump"):
		# Always buffered, never acted on here: input runs outside the physics
		# step, where is_on_floor() and the contact list both still describe
		# the previous one. What the press means is decided in the step.
		Net.queue_physics(press_jump)
		get_viewport().set_input_as_handled()


func _physics_process(delta: float) -> void:
	if not player.is_local():
		return
	if player.state == Player.State.DEAD:
		# Nothing moves while dead; the body waits where it fell.
		return
	if player.state == Player.State.GRABBED:
		# Someone else's hands decide where this body is.
		return
	if player.climb != null and player.climb.is_climbing():
		# The wall owns the body until it lets go.
		return
	_jump_buffer_left = maxf(0.0, _jump_buffer_left - delta)
	_catch_buffer_left = maxf(0.0, _catch_buffer_left - delta)
	_dash_cooldown_left = maxf(0.0, _dash_cooldown_left - delta)
	_intent_left = maxf(0.0, _intent_left - delta)
	if _intent_left == 0.0:
		_intent_direction = Vector3.ZERO
	if player.is_on_floor():
		_coyote_left = COYOTE_TIME
	else:
		_coyote_left = maxf(0.0, _coyote_left - delta)

	if _armed != Armed.NONE:
		if not player.is_grounded_state():
			# Shoved, fell, or dashed off while aiming: there is nothing left to
			# cast, so the rings go rather than follow a body in flight.
			_disarm()
		else:
			# The rings follow the cursor for as long as the key is armed.
			_refresh_indicator()

	if player.state == Player.State.STUNNED:
		# Physics keeps running while stunned; only the input stops.
		_stunned_step(delta)
		return
	if player.state == Player.State.DASH:
		_dash_step(delta)
	elif player.state == Player.State.AIRBORNE:
		_air_step(delta)
	else:
		_ground_step(delta)


func _ground_step(delta: float) -> void:
	# Held right button keeps re-issuing the order, the way a MOBA does.
	if Input.is_action_pressed("move_click"):
		_drag_left -= delta
		if _drag_left <= 0.0:
			_drag_left = DRAG_RETARGET_INTERVAL
			_click_to_target()
	else:
		_drag_left = 0.0

	if _pending_air_target is Vector3:
		# Applied on any grounded frame, not only on the landing transition: a
		# body that never reports a clean landing would swallow the click.
		var queued: Vector3 = _pending_air_target
		_pending_air_target = null
		set_target(queued)

	if _jump_buffer_left > 0.0 and player.state != Player.State.GRABBING \
			and (player.is_grounded_state() or _coyote_left > 0.0):
		_launch_jump()
		return

	var desired := _desired_velocity()
	if desired.length_squared() > 0.0001:
		player.velocity.x = desired.x
		player.velocity.z = desired.z
		player.face_direction(desired, delta)
	else:
		player.velocity.x = 0.0
		player.velocity.z = 0.0
	# Taken from whether an order stands, not from this frame's velocity: a
	# re-query gap is still MOVE, because the order has not gone anywhere.
	if _has_target and player.state == Player.State.IDLE:
		player.change_state(Player.State.MOVE)
	elif not _has_target and player.state == Player.State.MOVE:
		player.change_state(Player.State.IDLE)
	if player.is_on_floor():
		player.velocity.y = -0.5
	else:
		player.velocity.y -= Tuning.values.gravity * delta
	player.move_and_slide()
	if not player.is_on_floor():
		# Walked off something. Coyote time is already running, so a jump
		# pressed a frame late still goes.
		player.change_state(Player.State.AIRBORNE)
		return
	_try_attach_climb()


# DOC (stage C-2): the jump goes where the cursor is, and the height comes out
# of the distance -- near is low, far is high.
#
#     t     = horizontal distance / leap_max_range          (0..1)
#     apex  = lerp(jump_min_hop_height, apex at full range, t)
#
# and the launch is worked back out of that apex and that landing point. The
# apex at full range is the 45 degree one, which is a quarter of the range, so
# the formula ends exactly on the cap when the cursor is as far as it can be.
#
# Landing higher than we stand needs the apex above the step, or the body would
# arrive inside it: the clearance is jump_min_hop_height again rather than a
# number of its own.
#
# Inside jump_inplace_radius the cursor means "straight up", at the standing
# height. The edge is abrupt -- just outside it is the lowest hop there is --
# and the work order says so on purpose.
#
# Returns the launch velocity, where that lands, and whether the cursor was out
# of reach (which is what the ring is for).
# The two speeds that reach (distance, rise) over the given apex: how fast
# along the heading, and how fast up. Up comes out of the apex, forward out of
# how long the whole arc lasts. Returned without a heading because the plan
# below is the thing that knows which way it is facing.
func _launch_for(apex: float, distance: float, rise: float) -> Vector2:
	var gravity: float = maxf(Tuning.values.gravity, 0.01)
	var up_speed := sqrt(2.0 * gravity * maxf(apex, 0.0))
	var fall := maxf(apex - rise, 0.0)
	var flight := up_speed / gravity + sqrt(2.0 * fall / gravity)
	return Vector2(distance / maxf(flight, 0.01), up_speed)


func jump_plan(aim: Vector3) -> Dictionary:
	var gravity: float = maxf(Tuning.values.gravity, 0.01)
	var from := player.global_position
	var to := aim
	var flat := Vector3(to.x - from.x, 0.0, to.z - from.z)
	var distance := flat.length()
	var cap := player.leap_speed_cap()

	if distance <= Tuning.values.jump_inplace_radius:
		# Straight up, and the whole budget goes into it: "all of it up is a
		# standing jump" from the same chapter. That makes a standing jump the
		# highest thing a body can do, which it was not while this used
		# base_jump_height on its own -- a jump aimed at a ledge three metres
		# off asked for a 2.40 m apex while pointing at your own feet gave
		# 1.64 m, so the cursor rewarded aiming away from where you wanted to
		# go. base_jump_height now sets the vertical half of the budget rather
		# than this height directly.
		var up := player.leap_speed_cap()
		return {
			"launch": Vector3(0.0, up, 0.0),
			"landing": from,
			"clamped": false,
			"apex": up * up / (2.0 * gravity),
		}

	var reach := player.leap_max_range()
	var rise := to.y - from.y

	# Whether a target can be hit at all has an exact answer, and it is not
	# "is it inside the flat range": a launch at speed v can reach (d, rise)
	# only if
	#
	#     v^2  >=  g * (rise + sqrt(d^2 + rise^2))
	#
	# which for rise = 0 is exactly the flat range, and for a step is stricter.
	# The cheapest arc that hits it has its apex half way up that same figure.
	var clamped := false
	var span := sqrt(distance * distance + rise * rise)
	if gravity * (rise + span) > cap * cap:
		# Out of reach. The far end along this heading is where the cheapest arc
		# runs out of budget, and that is where the ring belongs -- the cursor
		# is not somewhere this body can land.
		clamped = true
		var budget := cap * cap / gravity
		var level := budget - rise
		if level <= absf(rise):
			# Higher than anything this body can reach, however it is thrown.
			# Straight up, as high as the budget goes.
			return {
				"launch": Vector3(0.0, cap, 0.0),
				"landing": from,
				"clamped": true,
				"apex": cap * cap / (2.0 * gravity),
			}
		distance = sqrt(maxf(level * level - rise * rise, 0.0))
		to = from + flat.normalized() * distance + Vector3.UP * rise
		span = sqrt(distance * distance + rise * rise)

	var t: float = clampf(distance / maxf(reach, 0.01), 0.0, 1.0)
	var apex_at_reach := reach * 0.25
	var apex: float = lerpf(Tuning.values.jump_min_hop_height, apex_at_reach, t)
	# Over the lip rather than into it.
	apex = maxf(apex, rise + Tuning.values.jump_min_hop_height)
	# The height the distance asks for is a preference, not a requirement. When
	# it costs more than the budget -- which a step always eventually does,
	# because clearing it needs the apex above it -- the cheapest launch that
	# hits the same spot is taken instead. The landing does not move, so the
	# ring stays honest and stays green: this is a reachable jump, just a
	# flatter one than the distance rule would have picked.
	#
	# That launch is the minimum-speed one: 45 degrees, tilted by half the
	# slope to the target. Its apex is the vertical half of it, not the whole
	# of v^2/2g -- reading it as the whole sent the arc up twice as high as it
	# should have gone, which then did not fit either and was scaled down,
	# landing a metre short of the ring.
	var pair := _launch_for(apex, distance, rise)
	if pair.length() > cap:
		var optimum := PI * 0.25 + 0.5 * atan2(rise, maxf(distance, 0.001))
		var cheapest := sqrt(gravity * (rise + span))
		pair = Vector2(cheapest * cos(optimum), cheapest * sin(optimum))
		apex = pair.y * pair.y / (2.0 * gravity)
	var launch := flat.normalized() * pair.x
	launch.y = pair.y
	# Arithmetic, not a ruling: the cheapest arc is inside the budget by
	# construction, so anything left over here is rounding.
	var speed := launch.length()
	if speed > cap:
		launch *= cap / speed
	return {
		"launch": launch,
		"landing": to,
		"clamped": clamped,
		"apex": apex,
	}


func _launch_jump() -> void:
	_jump_buffer_left = 0.0
	_catch_buffer_left = 0.0
	_coyote_left = 0.0
	var from_dash := player.state == Player.State.DASH
	_launch_from_dash = from_dash
	var launch := jump_launch_velocity()
	_launch_from_dash = false
	_clear_intent()
	cancel_target()
	_dash_left = 0.0
	player.velocity = launch
	player.floor_snap_length = 0.0
	player.change_state(Player.State.AIRBORNE)
	player.move_and_slide()


# The preview, the indicator and the real launch all come through here.
func jump_launch_velocity() -> Vector3:
	if _launch_from_dash and _dash_direction.length_squared() > 0.01:
		# Stage C's dash jump, kept: the budget split that flies furthest.
		var share := player.leap_speed_cap() / sqrt(2.0)
		var launch := _dash_direction.normalized() * share
		launch.y = share
		return launch
	var plan := jump_plan(cursor_jump_target())
	return plan["launch"] as Vector3


func _stunned_step(delta: float) -> void:
	if player.is_on_floor():
		player.velocity.x = move_toward(player.velocity.x, 0.0, 10.0 * delta)
		player.velocity.z = move_toward(player.velocity.z, 0.0, 10.0 * delta)
		player.velocity.y = -0.5
	else:
		player.velocity.y -= Tuning.values.gravity * delta
	player.move_and_slide()


# Judged here, on the pusher's own client, as the authority table says. What it
# sends is a request; the target's own machine works out what it does.
# A key press states a direction. Everything else about a shove -- who it
# reaches, whether they are a team mate, whether the cooldown has run -- is
# ruled by ServerAuthority against the server's own view of the world.
func shove() -> int:
	var forward := shove_direction()
	if forward == Vector3.ZERO:
		return 0
	# Stage C: shown now, ruled later.
	player.snap_facing(forward)
	player.begin_predicted(ServerAuthority.Intent.SHOVE)
	var hits: Variant = ServerAuthority.submit_intent(
		player, ServerAuthority.Intent.SHOVE, {"direction": forward})
	return int(hits) if hits is int else 0


func shove_direction() -> Vector3:
	var forward := cursor_direction()
	if forward.length_squared() < 0.01:
		forward = -player.global_transform.basis.z
		forward.y = 0.0
		if forward.length_squared() < 0.01:
			return Vector3.ZERO
		forward = forward.normalized()
	return forward


func _air_step(delta: float) -> void:
	if _jump_buffer_left > 0.0 and _coyote_left > 0.0:
		# Walked off something a moment ago: this is still the jump.
		_launch_jump()
		return
	if _catch_buffer_left > 0.0 and try_air_catch():
		_catch_buffer_left = 0.0
		_jump_buffer_left = 0.0
		return
	# No self input on the horizontal: the arc is decided at launch. Only the
	# body's facing still follows the cursor.
	_face_cursor(delta)
	player.velocity.y -= Tuning.values.gravity * delta
	player.move_and_slide()
	if player.is_on_floor():
		player.floor_snap_length = player.default_snap_length()
		player.change_state(Player.State.MOVE if _has_target else Player.State.IDLE)


# DOC: ground only, cursor aimed, and never while already dashing or airborne.
# The jump goes where the cursor points, carrying the speed already being
# travelled, or a full run's worth from a standstill. The cursor resting on the
# body itself is how a jump straight up is asked for, which there would
# otherwise be no way to express.
func _cursor_jump_velocity(current: Vector3) -> Vector3:
	var point: Variant = _cursor_ground_point()
	if point == null:
		return current
	var offset := (point as Vector3) - player.global_position
	offset.y = 0.0
	if offset.length() <= Tuning.values.jump_aim_deadzone:
		return Vector3.ZERO
	var speed := current.length()
	if speed <= 0.1:
		speed = player.get_move_speed()
	return offset.normalized() * speed


# One key, in the order that cannot surprise anyone: throw what is in your
# hands, otherwise take what you are standing on, otherwise pick up what is in
# reach.
func interact() -> bool:
	if player.grab != null and player.grab.is_holding():
		return player.grab.throw()
	# The weapon rack is a local prop with no force behind it, so it does not
	# go through the force door. Weapon approval is its own stage.
	for node in player.get_tree().get_nodes_in_group(WeaponRack.INTERACT_GROUP):
		if node.has_method("interact") and node.interact(player):
			return true
	if player.grab != null:
		return player.grab.grab()
	return false


# The click path and anything else that wants a climb go through here, so a
# test exercises exactly what the button does.
func order_climb(body: CollisionObject3D, contact: Vector3, normal: Vector3) -> void:
	_climb_wall = body
	_climb_point = contact
	_climb_normal = normal
	# DOC: walk to a spot 0.4 m out along the face normal.
	set_target(contact + normal * 0.4)


# Gap between the body and the wall face, not between their centres. The
# navigation surface is eroded by agent_radius, so a centre to centre measure
# can never come under the documented attach distance however close the body
# actually gets.
func climb_request_distance() -> float:
	if _climb_wall == null:
		return -1.0
	var plane := Plane(_climb_normal, _climb_point)
	return absf(plane.distance_to(player.global_position)) - Player.BODY_RADIUS


# Probes outwards for a wall rather than reading the last step's contact list.
# Sliding down a face separates and re-touches from frame to frame, so the
# contact list is empty on most of them and a press would be thrown away.
func try_air_catch() -> bool:
	if player.state != Player.State.AIRBORNE or player.climb == null:
		return false
	var space := player.get_world_3d().direct_space_state
	var reach := Player.BODY_RADIUS + CATCH_REACH
	for index in range(CATCH_PROBES):
		var angle := TAU * float(index) / float(CATCH_PROBES)
		var direction := Vector3(sin(angle), 0.0, cos(angle))
		var from := player.global_position
		var query := PhysicsRayQueryParameters3D.create(from, from + direction * reach, Player.CLIMBABLE_LAYER)
		query.collide_with_areas = false
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			continue
		var body := hit.get("collider") as CollisionObject3D
		if body == null:
			continue
		if player.climb.attach(body, hit["position"] as Vector3, hit.get("normal", -direction) as Vector3):
			print("PLAYGROUND_AIR_CATCH y=%.2f" % player.global_position.y)
			return true
	return false


func _clear_climb_request() -> void:
	_climb_wall = null


# Close enough to the spot that was clicked on the wall, so take hold of it.
func _try_attach_climb() -> void:
	if _climb_wall == null or player.climb == null:
		return
	if climb_request_distance() > Tuning.values.climb_attach_distance:
		return
	var body := _climb_wall
	var point := _climb_point
	var normal := _climb_normal
	_clear_climb_request()
	cancel_target()
	player.climb.attach(body, point, normal)


# DOC (stage C-2): the dash is the same budget spent entirely sideways. Its
# speed is the cap times dash_speed_mult -- strength is already inside the cap,
# so it is not applied a second time -- and the furthest it goes is that speed
# held for dash_time_max. A nearer cursor is obeyed, down to dash_min_distance,
# and the time a dash takes falls out of distance over speed.
func dash_max_distance() -> float:
	return player.dash_speed() * Tuning.values.dash_time_max


func dash_plan() -> Dictionary:
	var point: Variant = _cursor_ground_point()
	var direction := cursor_direction()
	if point == null or direction == Vector3.ZERO:
		return {"distance": 0.0, "landing": player.global_position, "clamped": false}
	var wanted := _flat_distance(player.global_position, point as Vector3)
	var reach := dash_max_distance()
	var distance: float = clampf(wanted, Tuning.values.dash_min_distance, reach)
	return {
		"distance": distance,
		"landing": player.global_position + direction * distance,
		"clamped": wanted > reach,
	}


func request_dash() -> bool:
	_disarm()
	if not player.is_grounded_state() or _dash_cooldown_left > 0.0:
		return false
	var plan := dash_plan()
	if float(plan["distance"]) <= 0.0:
		return false
	if player.stamina < Tuning.values.stamina_dash_cost:
		print("PLAYGROUND_DASH_NO_STAMINA peer=%s stamina=%.1f" % [player.name, player.stamina])
		return false
	player.stamina -= Tuning.values.stamina_dash_cost
	_dash_direction = cursor_direction()
	_dash_total = float(plan["distance"])
	_dash_left = _dash_total
	_dash_cooldown_left = Tuning.values.dash_cooldown
	cancel_target()
	_clear_intent()
	player.velocity.y = 0.0
	player.change_state(Player.State.DASH)
	return true


func is_dashing() -> bool:
	return player.state == Player.State.DASH


func _dash_step(delta: float) -> void:
	# A jump out of a dash is allowed, inside the same leap budget as any other.
	if _jump_buffer_left > 0.0:
		_launch_jump()
		return
	# One speed, whatever the distance: a short dash is a brief one, not a slow
	# one, and the time it takes is the distance divided by this.
	var speed := player.dash_speed()
	# Tracked as remaining distance so the last step covers exactly what is
	# left rather than a frame's worth more or less.
	var step := minf(speed * delta, _dash_left)
	_dash_left -= step
	var frame_speed := step / maxf(delta, 0.0001)
	player.velocity.x = _dash_direction.x * frame_speed
	player.velocity.z = _dash_direction.z * frame_speed
	player.velocity.y -= Tuning.values.gravity * delta
	player.move_and_slide()
	# A wall ends it on the spot, and so does running out of ground.
	if player.is_on_wall() or _dash_left <= 0.0:
		_end_dash()
	elif not player.is_on_floor():
		_end_dash()


func _end_dash() -> void:
	_dash_left = 0.0
	_dash_total = 0.0
	player.velocity.x = 0.0
	player.velocity.z = 0.0
	player.change_state(Player.State.IDLE if player.is_on_floor() else Player.State.AIRBORNE)


func cursor_direction() -> Vector3:
	var point: Variant = _cursor_ground_point()
	if point == null:
		return Vector3.ZERO
	var direction := (point as Vector3) - player.global_position
	direction.y = 0.0
	if direction.length_squared() < 0.0004:
		return Vector3.ZERO
	return direction.normalized()


# DOC (stage C-2): where a jump should put this body. The cursor points at a
# surface, and a body stands a capsule half height above one, so the target is
# the surface the ray hits plus that. cursor_point() below is a different
# question -- "what is the cursor over, on my own plane" -- and a jump that
# used it could never aim at a step, because that plane has no height in it.
func cursor_jump_target() -> Vector3:
	if _aim_override != Vector3.INF:
		# A check aims at the body origin it wants, not at a surface.
		return _aim_override
	if player.camera == null or player.camera.camera == null:
		return player.global_position
	var mouse := player.get_viewport().get_mouse_position()
	var from := player.camera.camera.project_ray_origin(mouse)
	var direction := player.camera.camera.project_ray_normal(mouse)
	var query := PhysicsRayQueryParameters3D.create(from, from + direction * 200.0, CLICK_MASK)
	query.collide_with_areas = false
	var hit := player.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		var point: Variant = _cursor_ground_point()
		return point as Vector3 if point != null else player.global_position
	return (hit["position"] as Vector3) + Vector3.UP * Player.BODY_HALF_HEIGHT


# The spot on our own standing plane the cursor is over. Used to pick between
# several things within arm's reach.
func cursor_point() -> Vector3:
	var point: Variant = _cursor_ground_point()
	return point as Vector3 if point != null else player.global_position


func _face_cursor(delta: float) -> void:
	var point: Variant = _cursor_ground_point()
	if point == null:
		return
	player.face_direction((point as Vector3) - player.global_position, delta)


# Where the cursor meets the plane the body is standing on.
# Lets a check stand in for the mouse, which headless does not have.
func set_aim_override(point: Vector3) -> void:
	_aim_override = point


func _cursor_ground_point() -> Variant:
	if _aim_override != Vector3.INF:
		return _aim_override
	if player.camera == null or player.camera.camera == null:
		return null
	var mouse := player.get_viewport().get_mouse_position()
	var from := player.camera.camera.project_ray_origin(mouse)
	var direction := player.camera.camera.project_ray_normal(mouse)
	var plane := Plane(Vector3.UP, player.global_position.y)
	return plane.intersects_ray(from, direction)


func move_speed() -> float:
	var speed: float = Tuning.values.base_move_speed * Tuning.ratio_mult(
		player.stats.ratio(), Tuning.values.ratio_k_speed)
	if player.state == Player.State.GRABBING:
		# DOC: 70% while carrying something, and no jump or dash at all.
		speed *= CARRY_SPEED_SCALE
	return speed


func _click_to_target() -> void:
	if player.camera == null or player.camera.camera == null:
		return
	var mouse := player.get_viewport().get_mouse_position()
	var from := player.camera.camera.project_ray_origin(mouse)
	var to := from + player.camera.camera.project_ray_normal(mouse) * 500.0
	var query := PhysicsRayQueryParameters3D.create(from, to, CLICK_MASK)
	query.collide_with_areas = false
	# A wall that is currently faded out must not take the click: the player is
	# aiming at what they can see through it.
	query.exclude = OcclusionFader.faded_rids()
	var hit := player.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return
	var normal := hit.get("normal", Vector3.ZERO) as Vector3
	var collider := hit.get("collider") as CollisionObject3D
	if collider != null and (collider.collision_layer & Player.CLIMBABLE_LAYER) != 0:
		# Walk to the foot of the wall first; the attach happens on arrival.
		order_climb(collider, hit["position"] as Vector3, normal)
		return
	_clear_climb_request()
	if normal.dot(Vector3.UP) < 0.6:
		return
	set_target(hit["position"] as Vector3)


func _desired_velocity() -> Vector3:
	if not _has_target:
		return Vector3.ZERO
	if _pending_frames > 0:
		_pending_frames -= 1
	elif _path_dirty or _path.is_empty():
		_query_path()
	if _path.is_empty():
		return Vector3.ZERO

	var last_index := _path.size() - 1
	while _path_index < _path.size():
		var radius := ARRIVE_TOLERANCE if _path_index == last_index else PATH_LOOKAHEAD
		if _flat_distance(player.global_position, _path[_path_index]) > radius:
			break
		_path_index += 1
	if _path_index >= _path.size():
		# Walked out the old path while a new one is still being prepared: wait
		# for it rather than reporting an arrival that is not one.
		if not _path_dirty:
			_capture_intent_if_blocked()
			cancel_target()
		return Vector3.ZERO

	var step := _path[_path_index] - player.global_position
	step.y = 0.0
	if step.length() < 0.05:
		return Vector3.ZERO
	return step.normalized() * move_speed()


# Stopping at the near edge of a gap is not the same as arriving. When the path
# ends well short of where the click landed, the direction is kept for a while
# so a jump pressed here goes where the click was pointing.
func _capture_intent_if_blocked() -> void:
	var path_end := _path[_path.size() - 1] if not _path.is_empty() else player.global_position
	if _flat_distance(path_end, _target) <= UNREACHABLE_DISTANCE:
		return
	var direction := _target - player.global_position
	direction.y = 0.0
	if direction.length_squared() < 0.01:
		return
	_intent_direction = direction.normalized()
	_intent_left = Tuning.values.move_intent_timeout


func _query_path() -> void:
	# One call makes the agent run its pending query; the points are then ours
	# to walk in XZ.
	_agent.get_next_path_position()
	var result := _agent.get_current_navigation_path()
	if result.is_empty():
		_retries += 1
		if _retries > PATH_QUERY_RETRIES:
			# No path at all: the click was somewhere this body cannot walk to,
			# which is exactly the case the jump intent exists for.
			_capture_intent_if_blocked()
			cancel_target()
			return
		_pending_frames = 1
		return
	_path = result
	_path_index = 0
	_path_dirty = false
	_retries = 0


func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))
