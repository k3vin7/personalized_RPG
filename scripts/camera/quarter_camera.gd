class_name QuarterCamera
extends Node3D

# Fixed quarter view: no rotation, follows only the local player. Its flat
# forward is published because the climb code classifies wall faces against it.

const PITCH_DEGREES := 55.0
const DISTANCE := 18.0
const LOOK_HEIGHT := 0.9

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
	# Straight along -Z and down by the pitch, so the view never rotates.
	var pitch := deg_to_rad(PITCH_DEGREES)
	_offset = Vector3(0.0, sin(pitch), cos(pitch)) * DISTANCE


func set_target(value: Node3D) -> void:
	target = value
	if is_instance_valid(target):
		global_position = target.global_position + _offset
		_aim()


func _process(delta: float) -> void:
	if not is_instance_valid(target):
		return
	var wanted := target.global_position + _offset
	global_position = global_position.lerp(wanted, 1.0 - exp(-follow_smoothing * delta))
	_aim()


func _aim() -> void:
	look_at(target.global_position + Vector3.UP * LOOK_HEIGHT, Vector3.UP)


# Horizontal, normalised. Used by wall face classification.
func get_camera_flat_forward() -> Vector3:
	var forward := -global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		return Vector3.FORWARD
	return forward.normalized()
