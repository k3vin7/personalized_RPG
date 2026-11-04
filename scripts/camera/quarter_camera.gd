class_name QuarterCamera
extends Node3D

# Fixed quarter view: no rotation, follows only the local player. Its flat
# forward is published because the climb code classifies wall faces against it.
#
# C-1g-e: the scroll zoom. One number, Tuning.values.camera_zoom (1 far, 0
# near), moves the distance and the tilt together: at 1 the view is what it
# always was (camera_distance 18 m at camera_pitch_deg 55), at 0 it is
# camera_near_mult x 18 m lying down at camera_near_pitch_deg 35. The wheel
# steps it by camera_zoom_step and the shown value eases after it. There was
# no "camera shrink for buildings" code to extend; this is the first zoom.
# Still no rotation (11-02): rotation.y stays 0 at every zoom.

@export var follow_smoothing: float = 14.0

var target: Node3D
var camera: Camera3D

var _offset := Vector3.ZERO
# The zoom the view is showing, easing toward Tuning.values.camera_zoom.
var _zoom_shown := -1.0
# C-0: the shake. The follow is kept apart from the jitter so the lerp never
# chases its own shake: _smoothed is where the camera would be without it.
var _smoothed := Vector3.INF
var _shake_left := 0.0
var _shake_time := 0.0
var _shake_amp := 0.0
var shakes_started := 0
# For the checks: wheel notches taken.
var wheel_steps := 0


func _ready() -> void:
	camera = Camera3D.new()
	camera.name = "Camera3D"
	camera.fov = 40.0
	camera.near = 0.1
	camera.far = 300.0
	add_child(camera)
	camera.current = true
	# The view is set from the zoom and never re-aimed at the character: the
	# work order calls for a view with no rotation, and re-aiming every frame
	# would swing the angle with the follow lag.
	_zoom_shown = clampf(Tuning.values.camera_zoom, 0.0, 1.0)
	_apply_view(_zoom_shown)


# The far view's tilt, degrees from the ground. Kept for a test scene that
# picks its own; the game's value is Tuning.values.camera_pitch_deg.
func set_pitch(degrees: float) -> void:
	Tuning.values.camera_pitch_deg = degrees
	_apply_view(_zoom_shown)


# ------------------------------------------------------------ C-1g-e: zoom

# Distance and tilt for a zoom level, both from the same number.
static func distance_for(zoom: float) -> float:
	var t := clampf(zoom, 0.0, 1.0)
	return Tuning.values.camera_distance * lerpf(Tuning.values.camera_near_mult, 1.0, t)


static func pitch_deg_for(zoom: float) -> float:
	var t := clampf(zoom, 0.0, 1.0)
	return lerpf(Tuning.values.camera_near_pitch_deg, Tuning.values.camera_pitch_deg, t)


func zoom_shown() -> float:
	return _zoom_shown


func view_distance() -> float:
	return _offset.length()


func view_pitch_deg() -> float:
	return rad_to_deg(-rotation.x)


# Where the camera sits relative to the body, without the follow lag.
func view_offset() -> Vector3:
	return _offset


# Jumps the shown zoom to the asked value (a check, or a scene start).
func set_zoom_now(zoom: float) -> void:
	Tuning.values.camera_zoom = clampf(zoom, 0.0, 1.0)
	_zoom_shown = Tuning.values.camera_zoom
	_apply_view(_zoom_shown)
	if is_instance_valid(target) and target.is_inside_tree():
		_smoothed = target.global_position + _offset
		global_position = _smoothed


func _apply_view(zoom: float) -> void:
	var pitch := deg_to_rad(pitch_deg_for(zoom))
	_offset = Vector3(0.0, sin(pitch), cos(pitch)) * distance_for(zoom)
	rotation = Vector3(-pitch, 0.0, 0.0)


# The wheel. Up is closer. Anything the UI took (the panel's own scroll) does
# not reach here.
func _unhandled_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button == null or not button.pressed:
		return
	var step: float = Tuning.values.camera_zoom_step
	if button.button_index == MOUSE_BUTTON_WHEEL_UP:
		Tuning.values.camera_zoom = clampf(Tuning.values.camera_zoom - step, 0.0, 1.0)
	elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		Tuning.values.camera_zoom = clampf(Tuning.values.camera_zoom + step, 0.0, 1.0)
	else:
		return
	wheel_steps += 1
	Tuning.notify_changed()


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
	# The zoom eases toward the asked level; the view is rebuilt from it every
	# frame so a slider on any of its numbers shows at once.
	var wanted_zoom := clampf(Tuning.values.camera_zoom, 0.0, 1.0)
	_zoom_shown = lerpf(_zoom_shown, wanted_zoom, 1.0 - exp(-Tuning.values.camera_zoom_smoothing * delta))
	if absf(_zoom_shown - wanted_zoom) < 0.0005:
		_zoom_shown = wanted_zoom
	_apply_view(_zoom_shown)
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
