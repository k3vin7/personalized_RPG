class_name DebugPanel
extends CanvasLayer

# F1. Stats and every tuning field as live sliders, a readout of what the
# formulas currently produce, and a preview of the arc the next jump would take.
#
# Stat changes are replicated, because other peers compute shoves against this
# body's weight. Tuning changes stay local so two people can experiment side by
# side; the button pulls the host's numbers when they want to compare.

const STAT_RANGES := {
	"strength": Vector2(1.0, 40.0),
	"race_weight": Vector2(3.0, 30.0),
	"gear_weight": Vector2(0.0, 30.0),
}
const ARC_STEPS := 90

var player: Player

var _root: PanelContainer
var _readout: Label
var _arc: MeshInstance3D
var _arc_enabled := true


func setup(owner_player: Player) -> void:
	player = owner_player
	layer = 10
	_build_ui()
	_build_arc()
	visible = false
	set_process(true)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("debug_panel"):
		visible = not visible
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if not is_instance_valid(player) or not player.is_inside_tree():
		return
	if visible:
		_refresh_readout()
	_refresh_arc()


func _build_ui() -> void:
	_root = PanelContainer.new()
	_root.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_root.position = Vector2(12.0, 12.0)
	_root.custom_minimum_size = Vector2(430.0, 560.0)
	add_child(_root)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(410.0, 540.0)
	_root.add_child(scroll)
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(column)

	_readout = Label.new()
	_readout.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_readout)

	var arc_toggle := CheckButton.new()
	arc_toggle.text = "점프 궤적 미리보기"
	arc_toggle.button_pressed = _arc_enabled
	arc_toggle.toggled.connect(func(on: bool) -> void: _arc_enabled = on)
	column.add_child(arc_toggle)
	if OS.is_debug_build():
		var boundary_toggle := CheckButton.new()
		boundary_toggle.name = "DebugBoundaries"
		boundary_toggle.text = "빨간 경계 표시 (디버그)"
		boundary_toggle.button_pressed = Tuning.debug_boundaries_visible
		boundary_toggle.toggled.connect(func(on: bool) -> void: Tuning.debug_boundaries_visible = on)
		column.add_child(boundary_toggle)

	column.add_child(_heading("능력치 (동기화됨)"))
	for field in STAT_RANGES.keys():
		var range_values: Vector2 = STAT_RANGES[field]
		column.add_child(_slider(
			field,
			float(player.stats.get(field)),
			range_values.x,
			range_values.y,
			func(value: float) -> void: player.stats.set(field, value)))

	column.add_child(_heading("튜닝 (각자 로컬)"))
	var pull := Button.new()
	pull.text = "호스트 튜닝 받아오기"
	pull.pressed.connect(_request_host_tuning)
	column.add_child(pull)
	for property in Tuning.values.get_property_list():
		if not (int(property["usage"]) & PROPERTY_USAGE_EDITOR):
			continue
		var name_text := String(property["name"])
		if name_text.begins_with("resource_") or name_text == "script":
			continue
		var value: Variant = Tuning.values.get(name_text)
		if typeof(value) == TYPE_BOOL:
			column.add_child(_check(name_text, value))
		elif typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
			var integer := typeof(value) == TYPE_INT
			var limits := numeric_limits(name_text, float(value))
			column.add_child(_slider(
				name_text,
				value,
				limits.x,
				limits.y,
				func(new_value: float) -> void:
					Tuning.values.set(name_text, roundi(new_value) if integer else new_value)
					Tuning.notify_changed(),
				integer))


func numeric_limits(field: String, value: float) -> Vector2:
	if field == "kill_plane_y" or value < 0.0:
		return Vector2(minf(value * 4.0, -1.0), 0.0)
	return Vector2(1.0 if field == "grabbed_escape_presses" else 0.0, maxf(value * 4.0, 1.0))


func _heading(text: String) -> Label:
	var label := Label.new()
	label.text = "\n— %s —" % text
	return label


func _slider(field: String, value: float, minimum: float, maximum: float, on_change: Callable, integer := false) -> HBoxContainer:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = field
	label.custom_minimum_size.x = 190.0
	row.add_child(label)
	var slider := HSlider.new()
	slider.name = field
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = 1.0 if integer else maxf((maximum - minimum) / 200.0, 0.01)
	slider.set_value_no_signal(value)
	slider.custom_minimum_size.x = 150.0
	row.add_child(slider)
	var readout := Label.new()
	readout.text = "%.2f" % value
	readout.custom_minimum_size.x = 60.0
	row.add_child(readout)
	slider.value_changed.connect(func(new_value: float) -> void:
		readout.text = "%.2f" % new_value
		on_change.call(new_value))
	return row


func _check(field: String, value: bool) -> CheckBox:
	var box := CheckBox.new()
	box.text = field
	box.button_pressed = value
	box.toggled.connect(func(on: bool) -> void:
		Tuning.values.set(field, on)
		Tuning.notify_changed())
	return box


func _refresh_readout() -> void:
	var movement := player.movement
	_readout.text = "\n".join(PackedStringArray([
		"상태: %s   지상: %s" % [Player.State.keys()[player.state], player.is_on_floor()],
		"속도: (%.2f, %.2f, %.2f)" % [player.velocity.x, player.velocity.y, player.velocity.z],
		"ratio: %.3f   점프 높이: %.2f m   초기 속도: %.2f" % [
			player.get_ratio(), player.get_jump_height(), player.get_jump_velocity()],
		"이동 속도: %.2f m/s" % player.get_move_speed(),
		"이동 의도: %.2f초 남음" % (movement.intent_seconds_left() if movement != null else 0.0),
		"HP: %.0f / %.0f" % [player.hp, player.stats.max_hp],
		"지구력: %.0f / %.0f" % [player.stamina, Tuning.values.stamina_max],
	]))


func _build_arc() -> void:
	_arc = MeshInstance3D.new()
	_arc.name = "JumpArc"
	_arc.top_level = true
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("ffd166")
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = false
	_arc.material_override = material
	get_tree().current_scene.add_child.call_deferred(_arc)


func _refresh_arc() -> void:
	if not is_instance_valid(_arc) or not _arc.is_inside_tree():
		return
	if not _arc_enabled or not player.is_grounded_state():
		_arc.visible = false
		return
	# Stepped with the same integration the body uses, at the same tick rate,
	# so the line is where the body will actually go rather than an idealised
	# parabola that quietly disagrees with it.
	var step := 1.0 / float(Engine.physics_ticks_per_second)
	var gravity: float = Tuning.values.gravity
	var position := player.global_position
	var velocity := _preview_launch_velocity()
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	mesh.surface_add_vertex(position)
	for _index in range(ARC_STEPS):
		if _index > 0:
			velocity.y -= gravity * step
		position += velocity * step
		mesh.surface_add_vertex(position)
		if position.y < player.global_position.y - 6.0:
			break
	mesh.surface_end()
	_arc.mesh = mesh
	_arc.visible = true


func _preview_launch_velocity() -> Vector3:
	return player.movement.jump_launch_velocity() if player.movement != null else Vector3.ZERO


func _request_host_tuning() -> void:
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		Net.request_tuning.rpc_id(1)
