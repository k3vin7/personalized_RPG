class_name DebugPanel
extends CanvasLayer

# F1. Stats and every tuning field as live sliders, a readout of what the
# formulas currently produce, and a preview of the arc the next jump would take.
#
# Stat changes are replicated, because other peers compute shoves against this
# body's weight. Tuning changes stay local so two people can experiment side by
# side; the button pulls the host's numbers when they want to compare.

# H-1: the 100-point scale. An orc is 100 strength and 140 kg, so the old
# 1-40 / 3-30 sliders could not reach any of the four races. The bounds the
# server enforces are its own (DEBUG_STRENGTH_RANGE / DEBUG_WEIGHT_RANGE);
# these are the panel's, and they sit inside them.
const STAT_RANGES := {
	"strength": Vector2(1.0, 150.0),
	"race_weight": Vector2(20.0, 200.0),
	# Gear is not a system yet, and this is the only way to put weight on a
	# body that is neither its own nor what it is carrying -- which is what
	# comparing bare against equipped needs.
	"gear_weight": Vector2(0.0, 80.0),
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

	# H-1: the abilities are the server's, so a slider states a number and the
	# server decides. Moving one holds this body off its race at that value;
	# the button puts it back on the race, which is also what choosing a race
	# at a pedestal does.
	column.add_child(_heading("능력치 (서버 승인)"))
	for field in STAT_RANGES.keys():
		var range_values: Vector2 = STAT_RANGES[field]
		var intent_key := "strength"
		if field == "race_weight":
			intent_key = "weight"
		elif field == "gear_weight":
			intent_key = "gear"
		column.add_child(_slider(
			field,
			float(player.stats.get(field)),
			range_values.x,
			range_values.y,
			func(value: float) -> void: _ask_stats({intent_key: value})))
	var follow := Button.new()
	follow.text = "종족 값으로 되돌리기"
	follow.pressed.connect(func() -> void: _ask_stats({
		"strength": null, "weight": null, "gear": null}))
	column.add_child(follow)

	# H-2: the per-race seats. The server's table, not a local tuning value:
	# the move multiplier is in the cap the server checks every body against,
	# so a slider here is a request and the answer comes back replicated.
	column.add_child(_heading("종족 배수 (서버 승인)"))
	var judge := ServerAuthority.instance
	for field in ServerAuthority.RACE_MULT_FIELDS:
		for kind in Races.all_kinds():
			var current := 1.0
			if judge != null and field == "tolerance":
				current = judge.race_tolerance_mult(kind)
			elif judge != null:
				current = judge.race_move_mult(kind)
			column.add_child(_slider(
				"race_%s_mult[%s]" % [field, Races.label_for(kind)],
				current,
				ServerAuthority.DEBUG_RACE_MULT_RANGE.x,
				ServerAuthority.DEBUG_RACE_MULT_RANGE.y,
				func(value: float) -> void: _ask_race_mult(field, kind, value)))

	# H-3: the three numbers HP and stamina are made of. They live in
	# PhysicsTuning like the rest, but they are in the server's HP ruling, so
	# the slider asks and the answer comes back replicated -- the generic loop
	# below skips them.
	column.add_child(_heading("HP·스태미나 계수 (서버 승인)"))
	for field: String in ServerAuthority.VITALS_TUNING_FIELDS:
		var limits: Vector2 = ServerAuthority.DEBUG_VITALS_RANGES[field]
		column.add_child(_slider(
			field,
			ServerAuthority.vitals_coeff(field),
			limits.x,
			limits.y,
			func(value: float) -> void: _ask_vitals_tuning(field, value)))

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
		if name_text in ServerAuthority.VITALS_TUNING_FIELDS:
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


# One entry of one table, asked for. The race id is the index, which is what
# keeps the four numbers from drifting apart.
func _ask_race_mult(field: String, kind: int, value: float) -> void:
	if not is_instance_valid(player):
		return
	ServerAuthority.submit_intent(player, ServerAuthority.Intent.RACE_MULT, {
		"field": field, "race": kind, "value": value})


# One door for both sliders and the reset button.
func _ask_stats(payload: Dictionary) -> void:
	if not is_instance_valid(player):
		return
	ServerAuthority.submit_intent(player, ServerAuthority.Intent.STATS, payload)


func _refresh_readout() -> void:
	var movement := player.movement
	_readout.text = "\n".join(PackedStringArray([
		"상태: %s   지상: %s" % [Player.State.keys()[player.state], player.is_on_floor()],
		"속도: (%.2f, %.2f, %.2f)" % [player.velocity.x, player.velocity.y, player.velocity.z],
		"종족: %s%s   근력 %.0f  무게 %.0fkg (장비 %.0f, 든 것 %.0f)  키 %.0fcm" % [
			Races.label_for(player.stats.race),
			" (슬라이더)" if player.stats.is_overridden() else "",
			player.stats.strength, player.stats.total_weight(),
			player.stats.gear_weight, player.stats.held_weight,
			player.stats.height_cm],
		"지구력 %.0f  민첩 %.0f  지능 %.0f" % [
			player.stats.endurance, player.stats.agility, player.stats.intellect],
		"ratio: %.3f (기준 %.2f)   점프 높이: %.2f m   초기 속도: %.2f" % [
			player.get_ratio(), Tuning.values.ratio_ref,
			player.get_jump_height(), player.get_jump_velocity()],
		"이동 속도: %.2f m/s" % player.get_move_speed(),
		"이동 의도: %.2f초 남음" % (movement.intent_seconds_left() if movement != null else 0.0),
		"HP: %.0f / %.0f   스태미나: %.0f / %.0f" % [
			player.hp, player.stats.max_hp, player.stamina, player.stats.max_stamina],
		"종족별 HP/스태미나 최대: " + _race_vitals_line(),
	]))


# H-3: the four races' derived maxima, from the server's coefficients -- the
# same numbers the server clamps HP to, so this line is a readout of a ruling.
func _race_vitals_line() -> String:
	var parts := PackedStringArray()
	for kind in Races.all_kinds():
		var endurance := Races.data_for(kind).endurance
		parts.append("%s %.0f/%.0f" % [
			Races.label_for(kind),
			endurance * ServerAuthority.vitals_coeff("hp_per_endurance"),
			ServerAuthority.vitals_coeff("stamina_base")
				+ endurance * ServerAuthority.vitals_coeff("stamina_per_endurance")])
	return "  ".join(parts)


# H-3: one coefficient, asked for. The server clamps and pushes the table back.
func _ask_vitals_tuning(field: String, value: float) -> void:
	if not is_instance_valid(player):
		return
	ServerAuthority.submit_intent(player, ServerAuthority.Intent.VITALS_TUNING, {
		"field": field, "value": value})


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
