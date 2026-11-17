class_name MapTeleport
extends Node

# Debug only: with the full map open, F3 arms the teleport; while it is armed
# a click on the map asks the server to move this screen's body there, and
# F3 again or closing the map disarms it. The frame and the banner over the
# map say that it is armed.
#
# The map knows nothing of this. This node turns the map's clicks on, hears
# them, and draws its own banner in the place the map offers (overlay()).
# The move is the server's: a request (Intent.DEBUG_TELEPORT) that the server
# refuses unless it is itself a debug build, and answers down the respawn's
# own path. Nothing here moves a body.
#
# Whoever builds the map adds this only in a debug build (create_for).

const KEY := KEY_F3
const COLOUR_ARMED := Color(1.0, 0.25, 0.2)

var map: BlockoutMap
var armed := false
var asked := 0

var _frame: ReferenceRect
var _banner: Label


# The teleport for `map`, or null when this is not a debug build.
static func create_for(map_node: BlockoutMap) -> MapTeleport:
	if not OS.is_debug_build() or map_node == null:
		return null
	var teleport := MapTeleport.new()
	teleport.name = "MapTeleport"
	teleport.map = map_node
	return teleport


func _ready() -> void:
	if map == null:
		return
	map.clicked.connect(_on_map_clicked)
	map.full_toggled.connect(_on_full_toggled)
	var place := map.overlay()
	_frame = ReferenceRect.new()
	_frame.name = "TeleportFrame"
	_frame.border_color = COLOUR_ARMED
	_frame.border_width = 4.0
	_frame.editor_only = false
	_frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place.add_child(_frame)
	_banner = Label.new()
	_banner.name = "TeleportBanner"
	_banner.text = "순간이동 대기 (디버그) — 지도에서 갈 자리를 클릭 · F3: 해제"
	_banner.add_theme_font_size_override("font_size", 20)
	_banner.add_theme_color_override("font_color", COLOUR_ARMED)
	_banner.add_theme_color_override("font_outline_color", Color.BLACK)
	_banner.add_theme_constant_override("outline_size", 6)
	_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_banner.position.y = 28.0
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	place.add_child(_banner)
	_show()


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or key.physical_keycode != KEY:
		return
	if map == null or not map.is_full_open():
		return
	set_armed(not armed)
	get_viewport().set_input_as_handled()


func set_armed(on: bool) -> void:
	armed = on and map != null and map.is_full_open()
	if map != null:
		map.want_clicks(armed)
	_show()


func _show() -> void:
	if _frame != null:
		_frame.visible = armed
	if _banner != null:
		_banner.visible = armed


func _on_full_toggled(open: bool) -> void:
	if not open:
		set_armed(false)


func _on_map_clicked(world: Vector3) -> void:
	if not armed:
		return
	var body := map.local_body() as Player
	if body == null:
		return
	asked += 1
	ServerAuthority.submit_intent(body, ServerAuthority.Intent.DEBUG_TELEPORT, {"x": world.x, "z": world.z})
