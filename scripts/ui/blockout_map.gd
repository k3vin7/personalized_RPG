class_name BlockoutMap
extends CanvasLayer

# The map for a CSG blockout, laid out like VillageMap: a small map in the
# top-right corner centred on this screen's body, and Tab opens the whole
# world as an overlay in the middle of the screen. There is no layout data
# for a blockout, so the drawing is read off the scene once: every CSG box
# and cylinder under the root becomes its footprint seen from above, coloured
# by what it is (see _kind_of). Up the map is `heading_deg`, the same heading
# the camera looks along, so the map and the view agree.
# Drawn only: nothing here is read by a ruling, and nothing is replicated.

const MINIMAP_SIZE := 220.0
const MINIMAP_MARGIN := 16.0
# Metres across the minimap.
const MINIMAP_SPAN := 120.0
const FULL_SIZE := Vector2(700.0, 680.0)
const FULL_MARGIN := 18.0
const ACTION := "map_toggle"
const CIRCLE_SIDES := 24

enum Kind { BEACH, GROUND, FIELD, ROAD, FOREST, CARVE, ROCK, BUILDING, MARKER }

const COLOURS := {
	Kind.BEACH: Color(0.80, 0.74, 0.55),
	Kind.GROUND: Color(0.56, 0.52, 0.42),
	Kind.FIELD: Color(0.50, 0.60, 0.38),
	Kind.ROAD: Color(0.47, 0.37, 0.26),
	Kind.FOREST: Color(0.24, 0.38, 0.24),
	Kind.CARVE: Color(0.50, 0.60, 0.38),
	Kind.ROCK: Color(0.42, 0.43, 0.45),
	Kind.BUILDING: Color(0.95, 0.78, 0.40),
	Kind.MARKER: Color(0.90, 0.30, 0.25, 0.45),
}
const COLOUR_VOID := Color(0.08, 0.09, 0.12, 0.96)
const COLOUR_ME := Color(1.0, 0.92, 0.3)
const COLOUR_OTHER := Color(0.45, 0.85, 1.0)
const COLOUR_TEXT := Color(0.96, 0.95, 0.9)
const COLOUR_FRAME := Color(0.85, 0.8, 0.65, 0.9)

var heading_deg := 0.0
var title := ""
# Footprints in map metres (x right, y down, heading up), in drawing order:
# {"polygon": PackedVector2Array, "colour": Color}.
var shapes: Array[Dictionary] = []
# Names of the root's direct children, at the middle of what each one covers.
var labels: Array[Dictionary] = []
var extent := Rect2()
var minimap: MapCanvas
var full_map: MapCanvas
var _full_frame: PanelContainer
var toggles := 0


func setup(root: Node3D, heading_degrees: float, map_title: String) -> void:
	heading_deg = heading_degrees
	title = map_title
	layer = 20
	if not InputMap.has_action(ACTION):
		InputMap.add_action(ACTION)
		var key := InputEventKey.new()
		key.physical_keycode = KEY_TAB
		InputMap.action_add_event(ACTION, key)
	_read_scene(root)

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
	full_map.clip_contents = true
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


# World ground point to map metres: up the map is the heading.
func to_map(world: Vector3) -> Vector2:
	var yaw := deg_to_rad(heading_deg)
	var forward := Vector2(-sin(yaw), -cos(yaw))
	var right := Vector2(cos(yaw), -sin(yaw))
	var flat := Vector2(world.x, world.z)
	return Vector2(flat.dot(right), -flat.dot(forward))


func direction_to_map(world: Vector3) -> Vector2:
	return to_map(world)


# ------------------------------------------------------------ reading the scene

func _read_scene(root: Node3D) -> void:
	shapes.clear()
	labels.clear()
	var found: Array[Dictionary] = []
	for child in root.get_children():
		var before := found.size()
		_collect(child, found)
		if found.size() > before and child is Node3D:
			var bounds := Rect2()
			for index in range(before, found.size()):
				var part: Rect2 = found[index]["bounds"]
				bounds = part if index == before else bounds.merge(part)
			labels.append({"text": String(child.name), "at": bounds.get_center()})
	found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["order"] != b["order"]:
			return a["order"] < b["order"]
		return a["top"] < b["top"])
	var first := true
	for entry in found:
		shapes.append({"polygon": entry["polygon"], "colour": COLOURS[entry["kind"]]})
		extent = entry["bounds"] if first else extent.merge(entry["bounds"])
		first = false
	extent = extent.grow(10.0)


func _collect(node: Node, found: Array[Dictionary]) -> void:
	var shape := node as CSGShape3D
	if shape != null and shape.is_visible_in_tree() and (shape is CSGBox3D or shape is CSGCylinder3D):
		var entry := _footprint(shape)
		if not entry.is_empty():
			found.append(entry)
	for child in node.get_children():
		_collect(child, found)


func _footprint(shape: CSGShape3D) -> Dictionary:
	var xform := shape.global_transform
	var points := PackedVector2Array()
	var half_y := 0.0
	var box := shape as CSGBox3D
	var cylinder := shape as CSGCylinder3D
	if box != null:
		var half := box.size * 0.5
		half_y = half.y
		for sx: float in [-1.0, 1.0]:
			for sy: float in [-1.0, 1.0]:
				for sz: float in [-1.0, 1.0]:
					points.append(to_map(xform * Vector3(half.x * sx, half.y * sy, half.z * sz)))
	else:
		half_y = cylinder.height * 0.5
		for index in CIRCLE_SIDES:
			var angle := TAU * float(index) / float(CIRCLE_SIDES)
			var rim := Vector3(cos(angle), 0.0, sin(angle)) * cylinder.radius
			points.append(to_map(xform * (rim + Vector3(0.0, half_y, 0.0))))
			points.append(to_map(xform * (rim - Vector3(0.0, half_y, 0.0))))
	var hull := Geometry2D.convex_hull(points)
	# The hull comes back closed (first point repeated); a polygon is not.
	if hull.size() > 1 and hull[0].is_equal_approx(hull[hull.size() - 1]):
		hull.remove_at(hull.size() - 1)
	if hull.size() < 3:
		return {}
	var bounds := Rect2(hull[0], Vector2.ZERO)
	for p in hull:
		bounds = bounds.expand(p)
	if bounds.size.x * bounds.size.y < 0.01:
		return {}
	var height := half_y * 2.0 * xform.basis.get_scale().y
	var top := xform.origin.y + height * 0.5
	var kind := _kind_of(shape, height, top)
	if kind < 0:
		return {}
	return {"polygon": hull, "bounds": bounds, "top": top, "kind": kind, "order": _order_of(kind)}


# What a shape is drawn as. There is no data to ask, so this goes by what the
# blockout already says: whether it is cut out of its combiner, how tall it
# is, and the words in its name and its parents' names.
#   a disc with no collision that is nobody's child shape -> a marked area
#   cut out of a forest                                   -> a path or clearing
#   cut out of anything else (a door)                     -> not drawn
#   over 2 m tall, "forest"/"tree" in the names           -> forest
#   over 1.5 m tall, "rock" in the names                  -> rock
#   over 1.5 m tall otherwise                             -> building
#   flat: "road"/"route" -> road, "beach" -> beach, "field" -> field, else ground
func _kind_of(shape: CSGShape3D, height: float, top: float) -> int:
	var names := _names_of(shape)
	var wooded := names.contains("forest") or names.contains("tree")
	if _is_cut(shape):
		return Kind.CARVE if wooded else -1
	if shape is CSGCylinder3D and shape.is_root_shape() and not shape.use_collision:
		return Kind.MARKER
	if height > 2.0 and wooded:
		return Kind.FOREST
	if height > 1.5 and top > 1.0:
		return Kind.ROCK if names.contains("rock") else Kind.BUILDING
	if names.contains("road") or names.contains("route"):
		return Kind.ROAD
	if String(shape.name).to_lower().contains("beach"):
		return Kind.BEACH
	if names.contains("field"):
		return Kind.FIELD
	return Kind.GROUND


func _order_of(kind: int) -> int:
	match kind:
		Kind.BEACH, Kind.GROUND, Kind.FIELD:
			return 0
		Kind.ROAD:
			return 1
		Kind.FOREST:
			return 2
		Kind.CARVE:
			return 3
		Kind.ROCK, Kind.BUILDING:
			return 4
	return 5


# The shape's own name and its CSG parents', lower case, joined.
func _names_of(shape: CSGShape3D) -> String:
	var text := String(shape.name).to_lower()
	var parent := shape.get_parent()
	while parent is CSGShape3D:
		text += "/" + String(parent.name).to_lower()
		parent = parent.get_parent()
	return text


func _is_cut(shape: CSGShape3D) -> bool:
	var node: Node = shape
	while node is CSGShape3D and not (node as CSGShape3D).is_root_shape():
		if (node as CSGShape3D).operation == CSGShape3D.OPERATION_SUBTRACTION:
			return true
		node = node.get_parent()
	return false


# ================================================================== the canvas

# One drawing of the footprints, as the minimap (a window around the body)
# or the full map (the whole extent fitted).
class MapCanvas:
	extends Control

	var map: BlockoutMap
	var full := false
	var scale_px := 1.0
	var centre_map := Vector2.ZERO
	var centre_px := Vector2.ZERO

	func to_px(at: Vector2) -> Vector2:
		return centre_px + (at - centre_map) * scale_px

	func px_of(world: Vector3) -> Vector2:
		return to_px(map.to_map(world))

	# The metres-to-pixels mapping, kept current whether or not anything is
	# drawn (headless has no drawing; a check still reads px_of).
	func refresh() -> void:
		if map == null:
			return
		if full:
			var ext := map.extent
			if ext.size.x > 0.0 and ext.size.y > 0.0:
				scale_px = minf((size.x - 2.0 * FULL_MARGIN) / ext.size.x, (size.y - 2.0 * FULL_MARGIN) / ext.size.y)
			centre_map = ext.get_center()
		else:
			var body := map.local_body()
			scale_px = size.x / MINIMAP_SPAN
			centre_map = map.to_map(body.global_position) if body != null else Vector2.ZERO
		centre_px = size * 0.5

	func _draw() -> void:
		if map == null:
			return
		refresh()
		draw_rect(Rect2(Vector2.ZERO, size), COLOUR_VOID)
		# The footprints are kept in map metres; the canvas transform does
		# the metres-to-pixels, so nothing is rebuilt per frame.
		draw_set_transform(centre_px - centre_map * scale_px, 0.0, Vector2(scale_px, scale_px))
		for shape in map.shapes:
			draw_colored_polygon(shape["polygon"], shape["colour"])
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		var font := ThemeDB.fallback_font
		if full:
			for label in map.labels:
				var text := String(label["text"])
				var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1.0, 14)
				var at := to_px(label["at"]) + Vector2(-text_size.x * 0.5, 5.0)
				draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 14, 4, Color.BLACK)
				draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 14, COLOUR_TEXT)
		_draw_bodies()
		draw_rect(Rect2(Vector2.ZERO, size), COLOUR_FRAME, false, 2.0)
		draw_string(font, Vector2(size.x * 0.5 - 4.0, 16.0), "N", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, COLOUR_TEXT)
		if full:
			draw_string(font, Vector2(10.0, size.y - 10.0), "Tab: 닫기 · %s" % map.title,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, COLOUR_TEXT)

	func _draw_bodies() -> void:
		var local := map.local_body()
		for body in map.bodies():
			var p := px_of(body.global_position)
			var mine := body == local
			var tick := map.direction_to_map(-body.global_transform.basis.z).normalized() * 12.0
			draw_line(p, p + tick, COLOUR_ME if mine else COLOUR_OTHER, 2.0)
			draw_circle(p, 5.0 if mine else 4.0, COLOUR_ME if mine else COLOUR_OTHER)
			draw_circle(p, 5.0 if mine else 4.0, Color.BLACK, false, 1.0)
