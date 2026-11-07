class_name VillageMap
extends CanvasLayer

# V-1 (2026-11-07, user's ask): the village map the Lost Ark way. A small
# map in the top-right corner, north up, centred on this screen's body; Tab
# opens the whole village as an overlay in the middle of the screen. Both
# are drawn from VillageLayout -- the zones, the plaza, the roads and their
# stairs, the gates, the building footprints -- plus a dot and a heading
# tick for every body in the session. Drawn only: nothing here is read by
# a ruling, and nothing is replicated.

const MINIMAP_SIZE := 220.0
const MINIMAP_MARGIN := 16.0
# Metres across the minimap.
const MINIMAP_SPAN := 72.0
const FULL_SIZE := Vector2(760.0, 720.0)
const FULL_MARGIN := 18.0
const ACTION := "map_toggle"
const COLOUR_VOID := Color(0.08, 0.09, 0.12, 0.96)
const COLOUR_GROUND := Color(0.56, 0.52, 0.42)
const COLOUR_UPPER := Color(0.60, 0.57, 0.46)
const COLOUR_TRAINING := Color(0.57, 0.60, 0.44)
const COLOUR_FOREST := Color(0.30, 0.44, 0.28)
const COLOUR_PLAZA := Color(0.68, 0.66, 0.60)
const COLOUR_FOUNTAIN := Color(0.45, 0.58, 0.78)
const COLOUR_ROAD := Color(0.47, 0.37, 0.26)
const COLOUR_STAIR := Color(0.86, 0.84, 0.78)
const COLOUR_FOOTPRINT := Color(0.95, 0.78, 0.40, 0.55)
const COLOUR_GATE := Color(1.0, 0.72, 0.35)
const COLOUR_ME := Color(1.0, 0.92, 0.3)
const COLOUR_OTHER := Color(0.45, 0.85, 1.0)
const COLOUR_TEXT := Color(0.96, 0.95, 0.9)
const COLOUR_FRAME := Color(0.85, 0.8, 0.65, 0.9)

var layout: VillageLayout
var minimap: MapCanvas
var full_map: MapCanvas
var _full_frame: PanelContainer
var toggles := 0


func setup(village_layout: VillageLayout) -> void:
	layout = village_layout
	layer = 20
	if not InputMap.has_action(ACTION):
		InputMap.add_action(ACTION)
		var key := InputEventKey.new()
		key.physical_keycode = KEY_TAB
		InputMap.action_add_event(ACTION, key)

	minimap = MapCanvas.new()
	minimap.name = "Minimap"
	minimap.map = self
	minimap.full = false
	minimap.size = Vector2(MINIMAP_SIZE, MINIMAP_SIZE)
	minimap.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	minimap.position = Vector2(-MINIMAP_SIZE - MINIMAP_MARGIN, MINIMAP_MARGIN)
	minimap.clip_contents = true
	minimap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(minimap)

	_full_frame = PanelContainer.new()
	_full_frame.name = "FullMapFrame"
	_full_frame.set_anchors_preset(Control.PRESET_CENTER)
	_full_frame.position = -FULL_SIZE * 0.5
	_full_frame.custom_minimum_size = FULL_SIZE
	_full_frame.visible = false
	_full_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_full_frame)
	full_map = MapCanvas.new()
	full_map.name = "FullMap"
	full_map.map = self
	full_map.full = true
	full_map.custom_minimum_size = FULL_SIZE
	full_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_full_frame.add_child(full_map)


func is_full_open() -> bool:
	return _full_frame != null and _full_frame.visible


func toggle_full() -> void:
	if _full_frame == null:
		return
	_full_frame.visible = not _full_frame.visible
	toggles += 1


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(ACTION) and not event.is_echo():
		toggle_full()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if minimap != null:
		minimap.refresh()
		minimap.queue_redraw()
	if full_map != null:
		full_map.refresh()
		if is_full_open():
			full_map.queue_redraw()


# This screen's body, and every body in the session.
func local_body() -> Node3D:
	if Net.spawn_root == null or not multiplayer.has_multiplayer_peer():
		return null
	return Net.spawn_root.get_node_or_null(str(multiplayer.get_unique_id())) as Node3D


func bodies() -> Array[Node3D]:
	var out: Array[Node3D] = []
	if Net.spawn_root == null:
		return out
	for child in Net.spawn_root.get_children():
		if child is Node3D:
			out.append(child as Node3D)
	return out


# The village's extent on the ground, for the full map's fit: the footprints,
# the roads, the gates and the plaza, with a margin.
func extent() -> Rect2:
	var rect := Rect2(Vector2(-layout.plaza_radius, -layout.plaza_radius), Vector2.ONE * layout.plaza_radius * 2.0)
	for road in layout.roads:
		for p3: Vector3 in road["points"]:
			rect = rect.expand(Vector2(p3.x, p3.z))
	for footprint in layout.footprints:
		var at: Vector2 = footprint["at"]
		var size: Vector2 = footprint["size"]
		rect = rect.expand(at - size * 0.6)
		rect = rect.expand(at + size * 0.6)
	rect = rect.expand(layout.gate_north)
	rect = rect.expand(layout.gate_southeast)
	# The roads run off to the terrain's edge; the map stops near the gates.
	rect = rect.intersection(Rect2(Vector2(-75.0, -95.0), Vector2(180.0, 195.0)))
	return rect.grow(6.0)


# ================================================================== the canvas

# One drawing of the layout, as the minimap (a window around the body) or
# the full map (the village fitted). Metres go to pixels through `scale`
# and `origin`; north is up (world -z is screen -y).
class MapCanvas:
	extends Control

	var map: VillageMap
	var full := false
	var scale_px := 3.0
	var centre_world := Vector2.ZERO
	var centre_px := Vector2.ZERO

	func to_px(world: Vector2) -> Vector2:
		return centre_px + (world - centre_world) * scale_px

	func px_of(at: Vector3) -> Vector2:
		return to_px(Vector2(at.x, at.z))

	# The metres-to-pixels mapping, kept current whether or not anything is
	# drawn (headless has no drawing; the checks still read px_of).
	func refresh() -> void:
		if map == null or map.layout == null:
			return
		if full:
			var ext := map.extent()
			scale_px = minf((size.x - 2.0 * FULL_MARGIN) / ext.size.x, (size.y - 2.0 * FULL_MARGIN) / ext.size.y)
			centre_world = ext.get_center()
		else:
			var body := map.local_body()
			scale_px = size.x / MINIMAP_SPAN
			centre_world = Vector2(body.global_position.x, body.global_position.z) if body != null else Vector2.ZERO
		centre_px = size * 0.5

	func _draw() -> void:
		var layout := map.layout
		if layout == null:
			return
		refresh()
		var body := map.local_body()
		draw_rect(Rect2(Vector2.ZERO, size), COLOUR_VOID)
		_draw_ground(layout)
		_draw_zones(layout)
		_draw_plaza(layout)
		_draw_roads(layout)
		_draw_footprints(layout)
		_draw_gates(layout)
		_draw_bodies(body)
		_draw_frame()

	# The ground on the village side of the cliff, over the whole canvas.
	func _draw_ground(layout: VillageLayout) -> void:
		var line := layout.cliff_line
		if line.size() < 2:
			draw_rect(Rect2(Vector2.ZERO, size), COLOUR_GROUND)
			return
		# The cliff line, then round the east side far away: a polygon of
		# everything east of the line.
		var polygon := PackedVector2Array()
		for p in line:
			polygon.append(to_px(p))
		var far := 400.0
		polygon.append(to_px(Vector2(line[line.size() - 1].x + far, line[line.size() - 1].y)))
		polygon.append(to_px(Vector2(line[0].x + far, line[0].y)))
		draw_colored_polygon(polygon, COLOUR_GROUND)

	func _polygon_px(points: PackedVector2Array) -> PackedVector2Array:
		var out := PackedVector2Array()
		for p in points:
			out.append(to_px(p))
		return out

	func _draw_zones(layout: VillageLayout) -> void:
		if layout.upper_polygon.size() >= 3:
			draw_colored_polygon(_polygon_px(layout.upper_polygon), COLOUR_UPPER)
		if layout.training_polygon.size() >= 3:
			draw_colored_polygon(_polygon_px(layout.training_polygon), COLOUR_TRAINING)
		if layout.forest_polygon.size() >= 3:
			# The hill's foot is forest_edge outside the top: drawn as the
			# top plus a lighter skirt.
			var skirt := Geometry2D.offset_polygon(layout.forest_polygon, layout.forest_edge)
			for part in skirt:
				draw_colored_polygon(_polygon_px(part), COLOUR_FOREST.lerp(COLOUR_GROUND, 0.5))
			draw_colored_polygon(_polygon_px(layout.forest_polygon), COLOUR_FOREST)

	func _draw_plaza(layout: VillageLayout) -> void:
		draw_circle(to_px(Vector2.ZERO), layout.plaza_radius * scale_px, COLOUR_PLAZA)
		draw_circle(to_px(Vector2.ZERO), layout.fountain_radius * scale_px, COLOUR_FOUNTAIN)

	func _draw_roads(layout: VillageLayout) -> void:
		for road in layout.roads:
			var points: PackedVector3Array = road["points"]
			var width := float(road["width"]) * scale_px
			var line := PackedVector2Array()
			for p3 in points:
				line.append(px_of(p3))
			if line.size() >= 2:
				draw_polyline(line, COLOUR_ROAD, width, false)
				for p in line:
					draw_circle(p, width * 0.5, COLOUR_ROAD)
		for stair in layout.stairs():
			var a := px_of(stair["from"])
			var b := px_of(stair["to"])
			var width := float(stair["width"]) * scale_px
			var along := (b - a).normalized()
			var across := Vector2(-along.y, along.x) * width * 0.5
			var steps := 4
			for index in steps + 1:
				var p := a.lerp(b, float(index) / float(steps))
				draw_line(p - across, p + across, COLOUR_STAIR, maxf(1.0, scale_px * 0.25))

	func _draw_footprints(layout: VillageLayout) -> void:
		var font := ThemeDB.fallback_font
		for footprint in layout.footprints:
			var at: Vector2 = footprint["at"]
			var half: Vector2 = Vector2(footprint["size"]) * 0.5
			var yaw := deg_to_rad(float(footprint.get("yaw", 0.0)))
			var corners := PackedVector2Array()
			for corner in [Vector2(-half.x, -half.y), Vector2(half.x, -half.y), Vector2(half.x, half.y), Vector2(-half.x, half.y)]:
				# yaw about +y turns +x toward -z: on the map (x right, z
				# down) that is a clockwise turn by -yaw.
				corners.append(to_px(at + corner.rotated(-yaw)))
			draw_colored_polygon(corners, COLOUR_FOOTPRINT)
			draw_polyline(corners + PackedVector2Array([corners[0]]), COLOUR_FOOTPRINT.lightened(0.3), 1.0)
			# Small footprints (the guard posts) keep their name off the map:
			# it sat on top of the house beside it; the gate marks them.
			if full and minf(half.x, half.y) >= 2.0:
				var text := String(footprint["name"])
				var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1.0, 13)
				draw_string(font, to_px(at) + Vector2(-text_size.x * 0.5, 5.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, COLOUR_TEXT)

	func _draw_gates(layout: VillageLayout) -> void:
		var font := ThemeDB.fallback_font
		for entry in [["북 길목", layout.gate_north], ["남동 길목", layout.gate_southeast]]:
			var p := to_px(entry[1])
			draw_circle(p, maxf(4.0, scale_px * 1.2), COLOUR_GATE)
			if full:
				draw_string(font, p + Vector2(8.0, 5.0), entry[0], HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, COLOUR_GATE)

	func _draw_bodies(local: Node3D) -> void:
		for body in map.bodies():
			var p := px_of(body.global_position)
			var mine := body == local
			var heading := -body.global_transform.basis.z
			var tick := Vector2(heading.x, heading.z).normalized() * (10.0 if full else 12.0)
			draw_line(p, p + tick, COLOUR_ME if mine else COLOUR_OTHER, 2.0)
			draw_circle(p, 5.0 if mine else 4.0, COLOUR_ME if mine else COLOUR_OTHER)
			draw_circle(p, 5.0 if mine else 4.0, Color.BLACK, false, 1.0)

	func _draw_frame() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), COLOUR_FRAME, false, 2.0)
		var font := ThemeDB.fallback_font
		draw_string(font, Vector2(8.0, 16.0), "N", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, COLOUR_TEXT)
		if full:
			draw_string(font, Vector2(size.x - 170.0, size.y - 10.0), "Tab: 닫기 · 피니메스 시작마을",
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, COLOUR_TEXT)
