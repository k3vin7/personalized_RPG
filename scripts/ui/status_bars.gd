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
	if not is_instance_valid(player):
		return
	var max_hp: float = maxf(player.stats.max_hp, 0.01)
	var max_stamina: float = maxf(Tuning.values.stamina_max, 0.01)
	_set_bar(_hp_fill, _hp_trail, _hp_text, player.hp, max_hp, "HP", HP_COLOR, HP_LOW_COLOR, delta)
	_set_bar(
		_stamina_fill, _stamina_trail, _stamina_text, player.stamina, max_stamina,
		"지구력", STAMINA_COLOR, STAMINA_LOW_COLOR, delta)


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
