class_name PitchingMachine
extends StaticBody3D

# 2026-11-22 (the user): a machine that throws its ball at the nearest person
# every pitch_period seconds, to try the guard against thrown things of
# every weight. Its ball is an ordinary rock (built on every peer by the
# playground, the machine is told which): what a hit does, a guard does to
# it and a reflect sends back are all the rock's and the judge's.
#
# On the server: the period runs; with someone in its lane (ahead within
# pitch_range, within pitch_lane_half_width of its line) the machine locks
# the point on its line level with them -- it never turns (2026-11-23, the
# user: one machine per lane) -- and shows the throw on the ground for
# pitch_windup (a lane from the machine to that spot, filling like a
# scarecrow's telegraph); just before the end the ball is put at the mouth
# (a placed rock waits six steps before it is thrown) and thrown at the spot
# at pitch_speed on the low arc, through the one force door. A ball someone
# is holding is not thrown.
#
# Built in code on every peer with the same name, so the host pushes its
# phase, lane and heading (CLAUDE.md note 1).

const SIZE := Vector3(1.0, 1.2, 1.0)
const LANE_WIDTH := 0.5
const RELOAD_LEAD := 0.1

var ball: Rock
var ball_weight := 5.0
# Host only, for the checks: a machine switched off does nothing.
var active := true
var shots := 0
var phase := ""
var lane_to := Vector3.ZERO

var _period_left := 0.0
var _phase_left := 0.0
var _reloaded := false
var _state_left := 0.0
var _phase_started := 0.0
var _outline: MeshInstance3D
var _fill: MeshInstance3D


func setup(machine_name: String, at_position: Vector3, yaw: float, of_ball: Rock) -> void:
	name = machine_name
	position = at_position
	rotation.y = yaw
	ball = of_ball
	ball_weight = of_ball.weight if of_ball != null else ball_weight


func _enter_tree() -> void:
	set_multiplayer_authority(1)


func _ready() -> void:
	collision_layer = Layers.WALL
	collision_mask = 0
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = SIZE
	collision.shape = shape
	collision.position = Vector3(0.0, SIZE.y * 0.5, 0.0)
	add_child(collision)
	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = SIZE
	body.mesh = box
	body.position = collision.position
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("5a6470")
	body.material_override = material
	add_child(body)
	var barrel := MeshInstance3D.new()
	var tube := CylinderMesh.new()
	tube.top_radius = 0.2
	tube.bottom_radius = 0.2
	tube.height = 0.7
	barrel.mesh = tube
	barrel.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	barrel.position = Vector3(0.0, SIZE.y - 0.1, -SIZE.z * 0.5 - 0.2)
	barrel.material_override = material
	add_child(barrel)
	var label := Label3D.new()
	label.text = "피칭머신 %.0fkg" % ball_weight
	label.position = Vector3(0.0, SIZE.y + 0.6, 0.0)
	label.font_size = 28
	label.outline_size = 6
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	add_child(label)
	_outline = RangeShapes.make_mesh(Dummy.TELEGRAPH_OUTLINE_COLOUR, Dummy.TELEGRAPH_LAYER)
	_outline.top_level = true
	_outline.visible = false
	add_child(_outline)
	_fill = RangeShapes.make_mesh(Dummy.TELEGRAPH_FILL_COLOUR, Dummy.TELEGRAPH_LAYER)
	_fill.top_level = true
	_fill.visible = false
	add_child(_fill)
	_period_left = float(Tuning.server.pitch_period)


func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return
	_run(delta)
	_state_left -= delta
	if _state_left <= 0.0 and multiplayer.has_multiplayer_peer():
		_state_left = SyncRules.STATE_INTERVAL
		push_state.rpc(phase, lane_to, rotation.y, Time.get_ticks_msec() / 1000.0 - _phase_started)


func _run(delta: float) -> void:
	if not Tuning.server.pitch_enabled or not active or ball == null or not is_instance_valid(ball):
		if phase != "":
			_set_phase("")
		return
	match phase:
		"":
			_period_left -= delta
			if _period_left > 0.0:
				return
			var ahead := _nearest_in_lane(float(Tuning.server.pitch_range), float(Tuning.server.pitch_lane_half_width))
			if ahead < 0.0 or ball.holder_peer != 0:
				# Nobody in the lane, or the ball is in someone's hands: look again soon.
				_period_left = 0.25
				return
			lane_to = global_position + _forward() * ahead
			_phase_left = float(Tuning.server.pitch_windup)
			_reloaded = false
			_set_phase("windup")
		"windup":
			_phase_left -= delta
			if not _reloaded and _phase_left <= RELOAD_LEAD:
				_reloaded = true
				_reload()
			if _phase_left <= 0.0:
				_fire()
				_period_left = float(Tuning.server.pitch_period)
				_set_phase("")


# The ball at the mouth, still (six steps before it is thrown).
func _reload() -> void:
	if ball.holder_peer != 0:
		return
	ball.global_position = _mouth()
	ball.linear_velocity = Vector3.ZERO
	ball.angular_velocity = Vector3.ZERO


func _mouth() -> Vector3:
	return global_position + Vector3.UP * (SIZE.y + 0.1) + _forward() * (SIZE.z * 0.5 + 0.3 + Rock.radius_for(ball_weight))


func _forward() -> Vector3:
	var forward := -global_transform.basis.z
	forward.y = 0.0
	return forward.normalized()


func _fire() -> void:
	if ball.holder_peer != 0 or ServerAuthority.instance == null:
		return
	var from := ball.global_position
	var aim := lane_to + Vector3.UP * 0.9
	var flat := Vector3(aim.x - from.x, 0.0, aim.z - from.z)
	var speed := float(Tuning.server.pitch_speed)
	var gravity := maxf(float(Tuning.server.gravity), 0.01)
	var pair := Ballistics.launch_at_speed(flat.length(), aim.y - from.y, speed, gravity)
	if pair == Vector2.ZERO:
		pair = Ballistics.cheapest_launch(flat.length(), aim.y - from.y, gravity)
	var velocity := flat.normalized() * pair.x + Vector3.UP * pair.y
	var launch := velocity.length()
	if launch <= 0.01:
		return
	ServerAuthority.instance.send_force(ball, ForceSystem.make_event(
		ForceSystem.Kind.THROW, velocity / launch, launch, 0.0, 0, true, 0.0, 0.0))
	shots += 1
	print("PLAYGROUND_PITCH machine=%s ball=%s weight=%.0f speed=%.2f to=(%.2f, %.2f)" % [
		name, ball.name, ball_weight, launch, lane_to.x, lane_to.z])


func _set_phase(next: String) -> void:
	if next != phase:
		_phase_started = Time.get_ticks_msec() / 1000.0
	phase = next
	_draw()


# How far ahead along the machine's line the nearest living person in its
# lane stands, or -1 with nobody there.
func _nearest_in_lane(reach: float, half_width: float) -> float:
	if Net.spawn_root == null:
		return -1.0
	var forward := _forward()
	var side := forward.cross(Vector3.UP)
	var best := -1.0
	for node in Net.spawn_root.get_children():
		var person := node as Player
		if person == null or person.sync_dead:
			continue
		var offset := person.global_position - global_position
		offset.y = 0.0
		var ahead := offset.dot(forward)
		if ahead <= SIZE.z * 0.5 or ahead > reach or absf(offset.dot(side)) > half_width:
			continue
		if best < 0.0 or ahead < best:
			best = ahead
	return best


@rpc("authority", "call_remote", "unreliable_ordered")
func push_state(at_phase: String, at_lane: Vector3, at_yaw: float, phase_age: float) -> void:
	rotation.y = at_yaw
	lane_to = at_lane
	if at_phase != phase:
		phase = at_phase
		_phase_started = Time.get_ticks_msec() / 1000.0 - phase_age
	_draw()


func _process(_delta: float) -> void:
	_draw()


# The lane on the ground from the machine to the spot, outline and fill.
func _draw() -> void:
	if _outline == null:
		return
	if phase != "windup":
		_outline.visible = false
		_fill.visible = false
		return
	var windup := maxf(float(Tuning.server.pitch_windup), 0.001)
	var fill := clampf((Time.get_ticks_msec() / 1000.0 - _phase_started) / windup, 0.0, 1.0)
	var from := Vector3(global_position.x, global_position.y + 0.04, global_position.z)
	var to := Vector3(lane_to.x, from.y, lane_to.z)
	_strip(_outline, from, to, 1.0)
	_strip(_fill, from + Vector3.UP * 0.01, to + Vector3.UP * 0.01, fill)
	_outline.visible = true
	_fill.visible = fill > 0.0


func _strip(node: MeshInstance3D, from: Vector3, to: Vector3, share: float) -> void:
	node.global_transform = Transform3D.IDENTITY
	var mesh := node.mesh as ImmediateMesh
	mesh.clear_surfaces()
	var along := to - from
	if along.length_squared() < 0.0001 or share <= 0.0:
		return
	var end := from + along * share
	var side := along.normalized().cross(Vector3.UP) * LANE_WIDTH * 0.5
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for point in [from - side, from + side, end + side, from - side, end + side, end - side]:
		mesh.surface_add_vertex(point)
	mesh.surface_end()
