class_name StatusBars
extends CanvasLayer

# HP and stamina, always on screen for your own character. The debug panel has
# the same two numbers, but it is behind F1 and full of sliders: stamina is
# spent by holding a climb, which is a thing you do while watching the wall,
# not while reading a panel.
#
# Local only. The bars follow the body this layer was set up with and nothing
# about them travels: every peer draws its own.

const BAR_SIZE := Vector2(260.0, 20.0)
const HP_COLOR := Color("d8604f")
const HP_LOW_COLOR := Color("ff3b2f")
const STAMINA_COLOR := Color("e8c35a")
const STAMINA_LOW_COLOR := Color("e87a3a")
const DRAIN_COLOR := Color("ffffff")
# How fast the pale "just lost" tail behind the bar catches up with it.
const TRAIL_SPEED := 2.2
const LOW_FRACTION := 0.3

var player: Player

var _hp_fill: ProgressBar
var _hp_trail: ProgressBar
var _hp_text: Label
var _stamina_fill: ProgressBar
var _stamina_trail: ProgressBar
var _stamina_text: Label
# M-1: the eight slots along the bottom. Key over name; grey when empty or
# shut, bright while armed or being cast, dim while cooling down.
var _slot_labels: Array[Label] = []
var _slot_panels: Array[PanelContainer] = []
const SLOT_SIZE := Vector2(72.0, 46.0)
const SLOT_OPEN := Color(0.16, 0.18, 0.22, 0.9)
const SLOT_SHUT := Color(0.10, 0.10, 0.11, 0.7)
const SLOT_ARMED := Color(0.55, 0.45, 0.15, 0.95)
const SLOT_CASTING := Color(0.75, 0.62, 0.20, 0.95)


func setup(owner_player: Player) -> void:
	player = owner_player
	# Under the debug panel's layer, so F1 covers this rather than the reverse.
	layer = 9
	_build()
	set_process(true)


func _build() -> void:
	var root := MarginContainer.new()
	root.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	root.offset_left = 18.0
	root.offset_top = -92.0
	root.offset_right = 18.0 + BAR_SIZE.x + 24.0
	root.offset_bottom = -18.0
	add_child(root)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	root.add_child(column)

	var hp := _bar_row("HP", HP_COLOR)
	_hp_trail = hp["trail"]
	_hp_fill = hp["fill"]
	_hp_text = hp["text"]
	column.add_child(hp["row"])

	var stamina := _bar_row("지구력", STAMINA_COLOR)
	_stamina_trail = stamina["trail"]
	_stamina_fill = stamina["fill"]
	_stamina_text = stamina["text"]
	column.add_child(stamina["row"])
	_build_slots()


# M-1: the slot bar, bottom centre.
func _build_slots() -> void:
	var bar := HBoxContainer.new()
	bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	bar.offset_left = -(SLOT_SIZE.x + 4.0) * PlayerSkills.SLOT_COUNT * 0.5
	bar.offset_right = (SLOT_SIZE.x + 4.0) * PlayerSkills.SLOT_COUNT * 0.5
	bar.offset_top = -18.0 - SLOT_SIZE.y
	bar.offset_bottom = -18.0
	bar.add_theme_constant_override("separation", 4)
	add_child(bar)
	for index in PlayerSkills.SLOT_COUNT:
		var panel := PanelContainer.new()
		panel.custom_minimum_size = SLOT_SIZE
		var style := StyleBoxFlat.new()
		style.bg_color = SLOT_SHUT
		style.set_corner_radius_all(4)
		style.set_border_width_all(1)
		style.border_color = Color(0.0, 0.0, 0.0, 0.7)
		panel.add_theme_stylebox_override("panel", style)
		var label := Label.new()
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 12)
		label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
		label.add_theme_constant_override("outline_size", 4)
		panel.add_child(label)
		bar.add_child(panel)
		_slot_panels.append(panel)
		_slot_labels.append(label)


func _refresh_slots() -> void:
	var skills := player.skills
	if skills == null:
		return
	for index in _slot_panels.size():
		var def := skills.slot_def(index)
		var label := _slot_labels[index]
		label.text = "%s\n%s" % [skills.key_label(index), def.label if def != null else "—"]
		var style := _slot_panels[index].get_theme_stylebox("panel") as StyleBoxFlat
		if style == null:
			continue
		var colour := SLOT_OPEN
		if def == null or skills.slot_locked(index):
			colour = SLOT_SHUT
		elif skills.slot_on_cooldown(index):
			colour = SLOT_SHUT.lerp(SLOT_OPEN, 0.5)
		if skills.armed_slot() == index:
			colour = SLOT_ARMED
		if skills.current_def() != null and skills.current_def() == def and player.is_casting():
			colour = SLOT_CASTING
		style.bg_color = colour
		label.modulate = Color(0.6, 0.6, 0.6) if (def == null or skills.slot_locked(index)) else Color.WHITE


# One bar is three things stacked: the dark bed, a pale trail that lags the
# value down so a hit or a drain is visible as movement, and the fill itself.
func _bar_row(caption: String, colour: Color) -> Dictionary:
	var row := Control.new()
	row.custom_minimum_size = BAR_SIZE

	var trail := _progress(Color(DRAIN_COLOR, 0.55), true)
	row.add_child(trail)
	var fill := _progress(colour, false)
	row.add_child(fill)

	var text := Label.new()
	text.text = caption
	text.set_anchors_preset(Control.PRESET_FULL_RECT)
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	text.add_theme_font_size_override("font_size", 13)
	text.add_theme_color_override("font_color", Color.WHITE)
	text.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	text.add_theme_constant_override("outline_size", 5)
	row.add_child(text)

	return {"row": row, "trail": trail, "fill": fill, "text": text}


func _progress(colour: Color, with_bed: bool) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.set_anchors_preset(Control.PRESET_FULL_RECT)
	bar.show_percentage = false
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.step = 0.0
	bar.value = 1.0
	if with_bed:
		var bed := StyleBoxFlat.new()
		bed.bg_color = Color(0.07, 0.08, 0.10, 0.85)
		bed.set_corner_radius_all(4)
		bed.set_border_width_all(1)
		bed.border_color = Color(0.0, 0.0, 0.0, 0.6)
		bar.add_theme_stylebox_override("background", bed)
	else:
		var empty := StyleBoxEmpty.new()
		bar.add_theme_stylebox_override("background", empty)
	var filled := StyleBoxFlat.new()
	filled.bg_color = colour
	filled.set_corner_radius_all(4)
	bar.add_theme_stylebox_override("fill", filled)
	return bar


func _process(delta: float) -> void:
	if not is_instance_valid(player) or not player.is_inside_tree():
		return
	var max_hp: float = maxf(player.stats.max_hp, 0.01)
	var max_stamina: float = maxf(player.stats.max_stamina, 0.01)
	_set_bar(_hp_fill, _hp_trail, _hp_text, player.hp, max_hp, "HP", HP_COLOR, HP_LOW_COLOR, delta)
	_set_bar(
		_stamina_fill, _stamina_trail, _stamina_text, player.stamina, max_stamina,
		"지구력", STAMINA_COLOR, STAMINA_LOW_COLOR, delta)
	_refresh_slots()


func _set_bar(
		fill: ProgressBar,
		trail: ProgressBar,
		text: Label,
		value: float,
		maximum: float,
		caption: String,
		colour: Color,
		low_colour: Color,
		delta: float) -> void:
	var fraction := clampf(value / maximum, 0.0, 1.0)
	fill.value = fraction
	# Up instantly, down slowly: refilling needs no emphasis, losing does.
	trail.value = fraction if trail.value < fraction else lerpf(
		trail.value, fraction, 1.0 - exp(-TRAIL_SPEED * delta))
	var style := fill.get_theme_stylebox("fill") as StyleBoxFlat
	if style != null:
		style.bg_color = low_colour if fraction <= LOW_FRACTION else colour
	text.text = "%s  %d / %d" % [caption, roundi(value), roundi(maximum)]
