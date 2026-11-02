class_name QuarterCamera
extends Node3D

# Fixed quarter view: no rotation, follows only the local player. Its flat
# forward is published because the climb code classifies wall faces against it.

const PITCH_DEGREES := 55.0
const DISTANCE := 18.0

@export var follow_smoothing: float = 14.0

var target: Node3D
var camera: Camera3D

var _offset := Vector3.ZERO
# C-0: the shake. The follow is kept apart from the jitter so the lerp never
# chases its own shake: _smoothed is where the camera would be without it.
var _smoothed := Vector3.INF
var _shake_left := 0.0
var _shake_time := 0.0
var _shake_amp := 0.0
var shakes_started := 0


func _ready() -> void:
	camera = Camera3D.new()
	camera.name = "Camera3D"
	camera.fov = 40.0
	camera.near = 0.1
	camera.far = 300.0
	add_child(camera)
	camera.current = true
	# Set once and never touched again. The work order calls for a view with no
	# rotation: re-aiming at the character every frame would swing the angle
	# with the follow lag, so the view would tilt whenever you started moving
	# and settle back when you stopped.
	set_pitch(PITCH_DEGREES)


# The tilt, in degrees from the ground: smaller lies the view further down.
# Set once by _ready() with the game's value; a test scene may pick its own.
func set_pitch(degrees: float) -> void:
	var pitch := deg_to_rad(degrees)
	_offset = Vector3(0.0, sin(pitch), cos(pitch)) * DISTANCE
	rotation = Vector3(-pitch, 0.0, 0.0)
	if is_instance_valid(target):
		global_position = target.global_position + _offset


func set_target(value: Node3D) -> void:
	target = value
	if is_instance_valid(target):
		global_position = target.global_position + _offset


func _process(delta: float) -> void:
	# Valid is not enough: during a teardown the body is out of the tree for a
	# frame before it is freed, and a global transform read in that frame is an
	# error rather than a stale value.
	if not is_instance_valid(target) or not target.is_inside_tree() or not is_inside_tree():
		return
	# Position only. The character drifts a little off centre while moving and
	# recentres when it stops, which is the follow lag showing itself honestly
	# rather than as a change of angle.
	var wanted := target.global_position + _offset
	if _smoothed == Vector3.INF:
		_smoothed = global_position
	_smoothed = _smoothed.lerp(wanted, 1.0 - exp(-follow_smoothing * delta))
	global_position = _smoothed + _shake_offset(delta)


# Horizontal, normalised. Used by wall face classification.
func get_camera_flat_forward() -> Vector3:
	var forward := -global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		return Vector3.FORWARD
	return forward.normalized()


# C-0: a decaying random jitter on top of the follow, for a big hit. Local
# only, drawn only; the view's angle never changes, which is the rule the
# quarter view keeps.
func shake(amplitude: float, seconds: float) -> void:
	if amplitude <= 0.0 or seconds <= 0.0:
		return
	_shake_amp = amplitude
	_shake_time = seconds
	_shake_left = seconds
	shakes_started += 1


func is_shaking() -> bool:
	return _shake_left > 0.0


func _shake_offset(delta: float) -> Vector3:
	if _shake_left <= 0.0:
		return Vector3.ZERO
	_shake_left = maxf(0.0, _shake_left - delta)
	var strength := _shake_amp * (_shake_left / maxf(_shake_time, 0.001))
	return Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * strength
