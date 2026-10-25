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
	var pitch := deg_to_rad(PITCH_DEGREES)
	_offset = Vector3(0.0, sin(pitch), cos(pitch)) * DISTANCE
	rotation = Vector3(-pitch, 0.0, 0.0)


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
	global_position = global_position.lerp(wanted, 1.0 - exp(-follow_smoothing * delta))


# Horizontal, normalised. Used by wall face classification.
func get_camera_flat_forward() -> Vector3:
	var forward := -global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		return Vector3.FORWARD
	return forward.normalized()
