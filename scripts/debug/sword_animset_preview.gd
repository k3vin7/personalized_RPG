extends Node3D
## Flip through every clip of the one-handed sword pack on its own mannequin.
## Open scenes/tests/sword_animset_preview.tscn and run it (F6).
##
##   Left / Right   previous / next clip      Up / Down   speed +- 0.1
##   Home / End     first / last clip          L           loop on / off
##   Space          pause                      R           from the start
##   Q / E          walk the camera round the mannequin
##
## The clips play on the pack's own bone names, no retarget. Root motion: the
## AnimationPlayer's root_motion_track (Skeleton3D:root) takes the root bone's
## travel out of the pose, so the mannequin plays every clip on the spot; the
## travel is only shown as numbers (the whole clip's, and so far), read off
## the root track. The sword hangs on Weapon_R.

@export var player_path: NodePath = ^"AnimationPlayer"
@export var label_path: NodePath = ^"HUD/Info"
@export var pivot_path: NodePath = ^"CameraPivot"
@export var speed_step := 0.1
@export var speed_min := 0.1
@export var speed_max := 3.0
@export var orbit_degrees_per_second := 90.0

# The pack's own bone names, no retarget: the clips play as shipped.
const ROOT_TRACK := ^"Skeleton3D:root"

var _player: AnimationPlayer
var _label: Label
var _pivot: Node3D
var _clips: PackedStringArray = []
var _index := 0
var _loop := true


func _ready() -> void:
	_player = get_node(player_path) as AnimationPlayer
	_label = get_node(label_path) as Label
	_pivot = get_node_or_null(pivot_path) as Node3D
	var names := _player.get_animation_list()
	names.sort()
	_clips = names
	_play(0)


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed:
		return
	match key.physical_keycode:
		KEY_RIGHT:
			_play(_index + 1)
		KEY_LEFT:
			_play(_index - 1)
		KEY_HOME:
			_play(0)
		KEY_END:
			_play(_clips.size() - 1)
		KEY_UP:
			_player.speed_scale = clampf(_player.speed_scale + speed_step, speed_min, speed_max)
		KEY_DOWN:
			_player.speed_scale = clampf(_player.speed_scale - speed_step, speed_min, speed_max)
		KEY_L:
			_loop = not _loop
			_play(_index)
		KEY_R:
			_play(_index)
		KEY_SPACE:
			if _player.is_playing():
				_player.pause()
			else:
				_player.play()


func _process(delta: float) -> void:
	if _pivot != null:
		var turn := 0.0
		if Input.is_physical_key_pressed(KEY_Q):
			turn -= 1.0
		if Input.is_physical_key_pressed(KEY_E):
			turn += 1.0
		_pivot.rotate_y(deg_to_rad(orbit_degrees_per_second) * turn * delta)
	if _clips.is_empty():
		_label.text = "라이브러리에 클립이 없습니다"
		return
	_label.text = _describe()


func _play(index: int) -> void:
	if _clips.is_empty():
		return
	_index = wrapi(index, 0, _clips.size())
	var clip := _clips[_index]
	_player.get_animation(clip).loop_mode = Animation.LOOP_LINEAR if _loop else Animation.LOOP_NONE
	_player.stop()
	_player.play(clip)


func _describe() -> String:
	var clip := _clips[_index]
	var animation := _player.get_animation(clip)
	var whole := _root_travel(animation, animation.length)
	var now := _root_travel(animation, _player.current_animation_position)
	var lines := PackedStringArray()
	lines.append("[%d/%d]  %s" % [_index + 1, _clips.size(), clip.replace(".", "/")])
	lines.append("%.2f / %.2f 초   속도 %.1fx   반복 %s%s" % [
		_player.current_animation_position, animation.length, _player.speed_scale,
		"켬" if _loop else "끔", "" if _player.is_playing() else "   (멈춤)"])
	if (whole[0] as Vector3).length() < 0.001 and absf(float(whole[1])) < 0.5:
		lines.append("루트 이동 없음 (제자리 클립)")
	else:
		var total: Vector3 = whole[0]
		var so_far: Vector3 = now[0]
		lines.append("클립 전체 루트 이동  x %.2f  y %.2f  z %.2f m  (수평 %.2f m)   회전 %.0f°" % [
			total.x, total.y, total.z, Vector2(total.x, total.z).length(), float(whole[1])])
		lines.append("지금까지              x %.2f  y %.2f  z %.2f m   회전 %.0f°" % [
			so_far.x, so_far.y, so_far.z, float(now[1])])
	lines.append("←/→ 클립  ↑/↓ 속도  L 반복  R 처음  Space 멈춤  Q/E 카메라")
	return "\n".join(lines)


# The root bone's travel and turn from the clip's start to `time`, read off
# the root track itself (in the skeleton's space, Y up).
func _root_travel(animation: Animation, time: float) -> Array:
	var travel := Vector3.ZERO
	var turn := 0.0
	var track := animation.find_track(ROOT_TRACK, Animation.TYPE_POSITION_3D)
	if track >= 0 and animation.track_get_key_count(track) > 1:
		travel = animation.position_track_interpolate(track, time) - animation.position_track_interpolate(track, 0.0)
	track = animation.find_track(ROOT_TRACK, Animation.TYPE_ROTATION_3D)
	if track >= 0 and animation.track_get_key_count(track) > 1:
		var first := animation.rotation_track_interpolate(track, 0.0)
		var last := animation.rotation_track_interpolate(track, time)
		turn = rad_to_deg((last * first.inverse()).get_euler().y)
	return [travel, turn]
