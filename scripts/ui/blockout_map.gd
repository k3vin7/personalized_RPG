class_name BlockoutMap
extends CanvasLayer

# The map of a map scene, three ways:
#   the minimap    top-right, a window around this screen's body
#   the full map   M: the whole world, large, in the middle of the screen
#   the walk map   Tab: where a body can walk around this screen's body, drawn
#                  over the game with nothing behind it; the game goes on
#                  under it and the mouse passes through
#
# The ground of the map is a picture of the scene itself: once, when the map
# is set up, an orthogonal camera looks straight down at everything under the
# root and what it sees is kept as a texture (retake() takes it again). So
# the map is whatever the scene is -- a piece moved, added or recoloured in
# the editor is on the map the next time it is taken -- and nothing here
# decides what a shape "is". (It used to: footprints were read off the CSG
# boxes and cylinders and coloured by guesses from names and heights, which
# left out every polygon and every generated wall and went wrong whenever a
# new kind of piece appeared.)
#
# Over the picture: the bodies, and the few places that need a word
# (PLACE_NAMES, by node name).
#
# Up the full map is north: `north_deg`, a fixed heading given at setup. The
# camera can turn; the full map does not. The minimap and the walk map are
# read while moving, so they turn with the camera: up them is up the screen,
# and the minimap's N says where north went.
#
# The walk map is the navigation map the game already baked (the
# NavigationRegion3D under the root): what is drawn is exactly where a body
# can walk, and it follows the scene like the picture does.
#
# The map only draws and answers "where in the world is this point of the
# map" (world_at, the `clicked` signal while someone wants clicks). What a
# click means is not the map's business: the debug teleport is its own node.
# Drawn only: nothing here is read by a ruling, and nothing is replicated.

signal clicked(world: Vector3)
signal full_toggled(open: bool)

const MINIMAP_SIZE := 220.0
const MINIMAP_MARGIN := 16.0
# Metres across the minimap.
const MINIMAP_SPAN := 120.0
# The full map fills this much of the screen, at the world's own proportions.
const FULL_SCREEN_SHARE := 0.9
const FULL_MARGIN := 18.0
# M: the full map. Tab: the walk map.
const ACTION := "world_map_full"
const ACTION_WALK := "world_map_walk"
# Metres across the walk map's shorter side, and how much of the screen's
# shorter side it fills.
const WALK_SPAN := 250.0
const WALK_SCREEN_SHARE := 0.85
# Inside a building only the storey at the building's own level is drawn:
# walkable ground this far below or above the building's origin.
const STOREY_BAND := Vector2(-1.0, 2.0)
# The picture: this many pixels along the world's longer side, and never
# finer than this many per metre.
const PICTURE_PIXELS := 2048
const PICTURE_MAX_PX_PER_M := 8.0
# How far above the highest thing the camera hangs.
const PICTURE_HEADROOM := 20.0
# Frames waited before the picture is read back.
const PICTURE_FRAMES := 3

# Places that get a word on the full map, by the name of their node in the
# map scene: an exact name, or every node whose name begins with `prefix`.
# The one table to add a line to when a new kind of place needs a name.
const PLACE_NAMES := [
	{"name": "pub", "text": "술집"},
	{"name": "clearing_bears", "text": "곰 터"},
	{"prefix": "dungeon_", "text": "던전 입구"},
]

const COLOUR_VOID := Color(0.08, 0.09, 0.12, 0.96)
const COLOUR_ME := Color(1.0, 0.92, 0.3)
const COLOUR_OTHER := Color(0.45, 0.85, 1.0)
const COLOUR_TEXT := Color(0.96, 0.95, 0.9)
const COLOUR_FRAME := Color(0.85, 0.8, 0.65, 0.9)
const COLOUR_WALK := Color(0.72, 0.86, 1.0, 0.16)
const COLOUR_WALK_EDGE := Color(0.85, 0.94, 1.0, 0.8)

var north_deg := 0.0
var title := ""
# The scene from above, covering `extent`. Null until it has been taken (and
# always in a run with no renderer).
var picture: Texture2D
var pictures_taken := 0
# {"text": String, "at": Vector2 (map metres)}.
var labels: Array[Dictionary] = []
# What the picture covers, in map metres (x right, y down, north up).
var extent := Rect2()
var minimap: MapCanvas
var full_map: MapCanvas
var walk_map: MapCanvas
var toggles := 0
# Where a body can walk, in map metres: the filled area as one mesh, and its
# outer edges as pairs of points.
var walk_mesh: ArrayMesh
var walk_edges := PackedVector2Array()
var walk_polygons := 0

var _root: Node3D
var _full_frame: PanelContainer
var _overlay: Control
var _height := Vector2.ZERO
var _click_wanted := false
var _taking := false


func setup(root: Node3D, north_degrees: float, map_title: String) -> void:
	_root = root
	north_deg = north_degrees
	title = map_title
	layer = 20
	_bind(ACTION, KEY_M)
	_bind(ACTION_WALK, KEY_TAB)
	_measure()
	_read_places()
	_read_walkable()

	walk_map = MapCanvas.new()
	walk_map.name = "WalkMap"
	walk_map.map = self
	walk_map.kind = MapCanvas.Kind.WALK
	walk_map.set_anchors_preset(Control.PRESET_FULL_RECT)
	walk_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	walk_map.visible = false
	add_child(walk_map)

	minimap = MapCanvas.new()
	minimap.name = "Minimap"
	minimap.map = self
	minimap.kind = MapCanvas.Kind.MINI
	minimap.size = Vector2(MINIMAP_SIZE, MINIMAP_SIZE)
	minimap.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	minimap.position = Vector2(-MINIMAP_SIZE - MINIMAP_MARGIN, MINIMAP_MARGIN)
	minimap.clip_contents = true
	minimap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(minimap)

	_full_frame = PanelContainer.new()
	_full_frame.name = "FullMapFrame"
	_full_frame.visible = false
	_full_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_full_frame)
	full_map = MapCanvas.new()
	full_map.name = "FullMap"
	full_map.map = self
	full_map.kind = MapCanvas.Kind.FULL
	full_map.clip_contents = true
	full_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_full_frame.add_child(full_map)
	# Whatever is drawn over the open map by someone else (overlay()).
	_overlay = Control.new()
	_overlay.name = "Overlay"
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_full_frame.add_child(_overlay)
	if is_inside_tree():
		_begin()
	else:
		ready.connect(_begin, CONNECT_ONE_SHOT)


func _begin() -> void:
	_fit_full()
	retake()


static func _bind(action: String, keycode: Key) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	var key := InputEventKey.new()
	key.physical_keycode = keycode
	InputMap.action_add_event(action, key)


func is_walk_open() -> bool:
	return walk_map != null and walk_map.visible


func toggle_walk() -> void:
	if walk_map != null:
		walk_map.visible = not walk_map.visible


func is_full_open() -> bool:
	return _full_frame != null and _full_frame.visible


func toggle_full() -> void:
	if _full_frame == null:
		return
	_fit_full()
	_full_frame.visible = not _full_frame.visible
	toggles += 1
	full_toggled.emit(_full_frame.visible)


# A place over the open full map for someone else's controls (a banner, a
# frame). The map draws nothing there itself.
func overlay() -> Control:
	return _overlay


# While true the open full map takes mouse clicks and reports each as
# `clicked` with the ground point under it (y = 0); otherwise the mouse
# passes through the map to the game.
func want_clicks(on: bool) -> void:
	_click_wanted = on
	if full_map != null:
		full_map.mouse_filter = Control.MOUSE_FILTER_STOP if on else Control.MOUSE_FILTER_IGNORE


func wants_clicks() -> bool:
	return _click_wanted


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(ACTION) and not event.is_echo():
		toggle_full()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(ACTION_WALK) and not event.is_echo():
		toggle_walk()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if minimap != null:
		minimap.refresh()
		minimap.queue_redraw()
	if walk_map != null and walk_map.visible:
		walk_map.refresh()
		walk_map.queue_redraw()
	if full_map != null:
		if is_full_open():
			_fit_full()
		full_map.refresh()
		if is_full_open():
			full_map.queue_redraw()


# The full map at the world's proportions, as large as the screen share lets
# it be, in the middle of the screen.
func _fit_full() -> void:
	if _full_frame == null or not is_inside_tree() or extent.size.x <= 0.0 or extent.size.y <= 0.0:
		return
	var room := Vector2(get_viewport().get_visible_rect().size) * FULL_SCREEN_SHARE
	var scale := minf(room.x / extent.size.x, room.y / extent.size.y)
	var wanted := (extent.size * scale).floor()
	if full_map.custom_minimum_size.is_equal_approx(wanted):
		return
	full_map.custom_minimum_size = wanted
	_overlay.custom_minimum_size = wanted
	_full_frame.reset_size()
	_full_frame.position = ((Vector2(get_viewport().get_visible_rect().size) - _full_frame.size) * 0.5).floor()


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


func _north() -> Vector2:
	var yaw := deg_to_rad(north_deg)
	return Vector2(-sin(yaw), -cos(yaw))


func _east() -> Vector2:
	var yaw := deg_to_rad(north_deg)
	return Vector2(cos(yaw), -sin(yaw))


# World ground point to map metres: up the map is north.
func to_map(world: Vector3) -> Vector2:
	var flat := Vector2(world.x, world.z)
	return Vector2(flat.dot(_east()), -flat.dot(_north()))


# Map metres back to the world's ground plane (y = 0).
func from_map(at: Vector2) -> Vector3:
	var flat := _east() * at.x - _north() * at.y
	return Vector3(flat.x, 0.0, flat.y)


func direction_to_map(world: Vector3) -> Vector2:
	return to_map(world)


# How far the minimap and the walk map are turned so that up them is the way
# this screen's camera looks (0 with no camera: north up).
func view_turn() -> float:
	var body := local_body() as Player
	if body == null or body.camera == null:
		return 0.0
	var ahead := to_map(body.camera.get_camera_flat_forward())
	if ahead.length_squared() < 0.0001:
		return 0.0
	return ahead.angle_to(Vector2.UP)


# ------------------------------------------------------------ reading the scene

# What is under the root, as a box in map metres and a height range: every
# visible piece of geometry, wherever it came from.
func _measure() -> void:
	var first := true
	var low := 0.0
	var high := 0.0
	for node in _geometry_under(_root):
		var box := node.get_aabb()
		if box.size.length_squared() < 0.0001:
			continue
		var xform := node.global_transform
		for index in 8:
			var corner := xform * box.get_endpoint(index)
			var at := to_map(corner)
			if first:
				extent = Rect2(at, Vector2.ZERO)
				low = corner.y
				high = corner.y
				first = false
			else:
				extent = extent.expand(at)
				low = minf(low, corner.y)
				high = maxf(high, corner.y)
	extent = extent.grow(10.0)
	_height = Vector2(low, high)


func _geometry_under(node: Node) -> Array[GeometryInstance3D]:
	var out: Array[GeometryInstance3D] = []
	if node == Net.spawn_root:
		return out
	var piece := node as GeometryInstance3D
	if piece != null and piece.is_visible_in_tree():
		out.append(piece)
	for child in node.get_children():
		out.append_array(_geometry_under(child))
	return out


# Where a body can walk: the polygons of the navigation map baked for this
# scene, flattened to map metres. Inside a building's footprint only the
# storey at the building's own level is kept, so the floors above and the
# cellar do not pile onto one another.
func _read_walkable() -> void:
	walk_mesh = null
	walk_edges = PackedVector2Array()
	walk_polygons = 0
	var stacked: Array[Dictionary] = []
	for node in _root.find_children("*", "Building", true, false):
		var building := node as Node3D
		var first := true
		var box := Rect2()
		for piece in _geometry_under(building):
			var aabb := piece.get_aabb()
			var xform := piece.global_transform
			for index in 8:
				var corner := xform * aabb.get_endpoint(index)
				var at := Vector2(corner.x, corner.z)
				box = Rect2(at, Vector2.ZERO) if first else box.expand(at)
				first = false
		if not first:
			stacked.append({"box": box, "y": building.global_position.y})
	var triangles := PackedVector2Array()
	var edge_count := {}
	var edge_points := {}
	for node in _root.find_children("*", "NavigationRegion3D", true, false):
		var region := node as NavigationRegion3D
		var nav := region.navigation_mesh
		if nav == null:
			continue
		var vertices := nav.get_vertices()
		var xform := region.global_transform
		for index in nav.get_polygon_count():
			var polygon := nav.get_polygon(index)
			if polygon.size() < 3:
				continue
			var middle := Vector3.ZERO
			for vertex in polygon:
				middle += xform * vertices[vertex]
			middle /= float(polygon.size())
			if _on_another_storey(middle, stacked):
				continue
			walk_polygons += 1
			var points := PackedVector2Array()
			for vertex in polygon:
				points.append(to_map(xform * vertices[vertex]))
			for corner in range(1, points.size() - 1):
				triangles.append(points[0])
				triangles.append(points[corner])
				triangles.append(points[corner + 1])
			for corner in polygon.size():
				var a: int = polygon[corner]
				var b: int = polygon[(corner + 1) % polygon.size()]
				var key := Vector2i(mini(a, b), maxi(a, b))
				edge_count[key] = int(edge_count.get(key, 0)) + 1
				edge_points[key] = [points[corner], points[(corner + 1) % points.size()]]
	# An edge only one polygon has is the rim of the walkable area.
	for key: Vector2i in edge_count:
		if int(edge_count[key]) == 1:
			walk_edges.append(edge_points[key][0])
			walk_edges.append(edge_points[key][1])
	if triangles.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = triangles
	walk_mesh = ArrayMesh.new()
	walk_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


func _on_another_storey(point: Vector3, stacked: Array[Dictionary]) -> bool:
	for entry in stacked:
		var box: Rect2 = entry["box"]
		if not box.has_point(Vector2(point.x, point.z)):
			continue
		var above := point.y - float(entry["y"])
		return above < STOREY_BAND.x or above > STOREY_BAND.y
	return false


func _read_places() -> void:
	labels.clear()
	_collect_places(_root)


func _collect_places(node: Node) -> void:
	var spot := node as Node3D
	if spot != null and spot != _root:
		var text := _place_text(String(spot.name))
		if text != "":
			labels.append({"text": text, "at": to_map(_middle_of(spot))})
	for child in node.get_children():
		_collect_places(child)


func _place_text(node_name: String) -> String:
	for entry: Dictionary in PLACE_NAMES:
		if entry.has("name") and node_name == String(entry["name"]):
			return String(entry["text"])
		if entry.has("prefix") and node_name.begins_with(String(entry["prefix"])):
			return String(entry["text"])
	return ""


# The middle of what a node covers: a polygon's own outline, a piece's box,
# or -- for a plain node -- the box of the geometry under it.
func _middle_of(spot: Node3D) -> Vector3:
	var polygon := spot as CSGPolygon3D
	if polygon != null and polygon.polygon.size() > 0:
		var sum := Vector2.ZERO
		for point in polygon.polygon:
			sum += point
		sum /= float(polygon.polygon.size())
		return polygon.global_transform * Vector3(sum.x, sum.y, -polygon.depth * 0.5)
	var first := true
	var low := Vector3.ZERO
	var high := Vector3.ZERO
	for piece in _geometry_under(spot):
		var box := piece.get_aabb()
		var centre := piece.global_transform * box.get_center()
		if box.size.length_squared() < 0.0001:
			centre = piece.global_position
		low = centre if first else low.min(centre)
		high = centre if first else high.max(centre)
		first = false
	return spot.global_position if first else (low + high) * 0.5


# ------------------------------------------------------------ the picture

# Takes the picture of the scene again (after the scene has changed: a world
# state swapped in, pieces moved). One frame of work; nothing to draw with in
# a run with no renderer, where the map keeps its void and its bodies.
func retake() -> void:
	if _taking or _root == null or extent.size.x <= 0.0 or extent.size.y <= 0.0:
		return
	if DisplayServer.get_name() == "headless":
		return
	_taking = true
	var px_per_m := minf(float(PICTURE_PIXELS) / maxf(extent.size.x, extent.size.y), PICTURE_MAX_PX_PER_M)
	var viewport := SubViewport.new()
	viewport.name = "MapPicture"
	viewport.size = Vector2i((extent.size * px_per_m).ceil())
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	# The pieces' own colours, flat: no sun, no shadows, no torches.
	viewport.debug_draw = Viewport.DEBUG_DRAW_UNSHADED
	viewport.transparent_bg = true
	viewport.msaa_3d = Viewport.MSAA_4X
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.size = extent.size.y
	camera.near = 0.5
	camera.far = (_height.y - _height.x) + PICTURE_HEADROOM * 2.0
	# Nothing of the world's sky, fog or glow: only what is under the root.
	var plain := Environment.new()
	plain.background_mode = Environment.BG_COLOR
	plain.background_color = Color(0.0, 0.0, 0.0, 0.0)
	plain.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	plain.ambient_light_color = Color.WHITE
	camera.environment = plain
	# Looking straight down with north up the picture: right is east, up is
	# north, and the lens looks along its own -Z, which is down.
	var east := _east()
	var north := _north()
	var middle := from_map(extent.get_center())
	camera.transform = Transform3D(
		Basis(Vector3(east.x, 0.0, east.y), Vector3(north.x, 0.0, north.y), Vector3.UP),
		Vector3(middle.x, _height.y + PICTURE_HEADROOM, middle.z))
	viewport.add_child(camera)
	add_child(viewport)
	camera.current = true
	# Handed to the renderer directly as well: the node's own transform did
	# not reach it (measured twice: the picture came out as the view from
	# the origin along -Z, the world edge-on, with the node's
	# global_transform correct; written before and after joining the tree).
	# Why the node does not pass it on was not found.
	RenderingServer.camera_set_transform(camera.get_camera_rid(), camera.transform)
	# The bodies are drawn over the picture, not baked into it.
	var bodies_root := Net.spawn_root as Node3D
	var bodies_shown := bodies_root != null and bodies_root.visible
	if bodies_root != null:
		bodies_root.visible = false
	# The viewport draws on the frame after it joins the tree: the first
	# frame's end can come before it has drawn anything.
	for _frame in PICTURE_FRAMES:
		await RenderingServer.frame_post_draw
	if bodies_root != null and is_instance_valid(bodies_root):
		bodies_root.visible = bodies_shown
	var image := viewport.get_texture().get_image()
	viewport.queue_free()
	_taking = false
	if image == null or image.is_empty():
		return
	picture = ImageTexture.create_from_image(image)
	pictures_taken += 1


# How many colours the picture is made of, for telling whether the map can be
# read: the picture's opaque pixels gathered into steps of `step` per channel
# (0..255), and every group that covers at least `share_min` of them, largest
# first: {"colour": Color, "share": float}.
func colour_census(step := 16, share_min := 0.002) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if picture == null:
		return out
	var image := picture.get_image()
	if image == null or image.is_empty():
		return out
	if image.is_compressed():
		image.decompress()
	image.convert(Image.FORMAT_RGBA8)
	var data := image.get_data()
	var counts := {}
	var total := 0
	for index in range(0, data.size(), 4):
		if data[index + 3] < 128:
			continue
		total += 1
		@warning_ignore("integer_division")
		var key := (data[index] / step) << 16 | (data[index + 1] / step) << 8 | (data[index + 2] / step)
		counts[key] = int(counts.get(key, 0)) + 1
	if total == 0:
		return out
	for key: int in counts:
		var share := float(counts[key]) / float(total)
		if share < share_min:
			continue
		var half := float(step) * 0.5
		out.append({
			"colour": Color(
				(float((key >> 16) & 255) * step + half) / 255.0,
				(float((key >> 8) & 255) * step + half) / 255.0,
				(float(key & 255) * step + half) / 255.0),
			"share": share,
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["share"] > b["share"])
	return out


# ================================================================== the canvas

# One drawing of the map: the minimap (a window around the body, turned with
# the camera), the full map (the whole extent, north up) or the walk map
# (the walkable area around the body over the whole screen, turned with the
# camera).
class MapCanvas:
	extends Control

	enum Kind { MINI, FULL, WALK }

	var map: BlockoutMap
	var kind := Kind.MINI
	var scale_px := 1.0
	var centre_map := Vector2.ZERO
	var centre_px := Vector2.ZERO
	# Radians the map is turned about its centre on this canvas.
	var turn := 0.0

	func to_px(at: Vector2) -> Vector2:
		return centre_px + ((at - centre_map) * scale_px).rotated(turn)

	func px_of(world: Vector3) -> Vector2:
		return to_px(map.to_map(world))

	# The ground point (y = 0) under a point of this canvas.
	func world_at(px: Vector2) -> Vector3:
		return map.from_map(centre_map + (px - centre_px).rotated(-turn) / maxf(scale_px, 0.0001))

	# Map metres to this canvas, as the transform a drawing in metres uses.
	func metres_to_px() -> Transform2D:
		return Transform2D(turn, Vector2(scale_px, scale_px), 0.0, centre_px) * Transform2D(0.0, -centre_map)

	# The metres-to-pixels mapping, kept current whether or not anything is
	# drawn (headless has no drawing; a check still reads px_of).
	func refresh() -> void:
		if map == null:
			return
		centre_px = size * 0.5
		if kind == Kind.FULL:
			var ext := map.extent
			if ext.size.x > 0.0 and ext.size.y > 0.0:
				scale_px = minf(size.x / ext.size.x, size.y / ext.size.y)
			centre_map = ext.get_center()
			turn = 0.0
			return
		var body := map.local_body()
		centre_map = map.to_map(body.global_position) if body != null else Vector2.ZERO
		turn = map.view_turn()
		if kind == Kind.MINI:
			scale_px = size.x / MINIMAP_SPAN
		else:
			scale_px = minf(size.x, size.y) * WALK_SCREEN_SHARE / WALK_SPAN

	func _gui_input(event: InputEvent) -> void:
		var button := event as InputEventMouseButton
		if button == null or not button.pressed or button.button_index != MOUSE_BUTTON_LEFT:
			return
		if kind != Kind.FULL or not map.wants_clicks():
			return
		refresh()
		map.clicked.emit(world_at(button.position))
		accept_event()

	func _draw() -> void:
		if map == null:
			return
		refresh()
		var font := ThemeDB.fallback_font
		if kind == Kind.WALK:
			_draw_walkable()
			_draw_labels(font)
			_draw_bodies()
			draw_string_outline(font, Vector2(12.0, size.y - 12.0), "Tab: 닫기 · M: 전체 지도",
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, 4, Color.BLACK)
			draw_string(font, Vector2(12.0, size.y - 12.0), "Tab: 닫기 · M: 전체 지도",
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, COLOUR_TEXT)
			return
		draw_rect(Rect2(Vector2.ZERO, size), COLOUR_VOID)
		if map.picture != null:
			draw_set_transform_matrix(metres_to_px())
			draw_texture_rect(map.picture, map.extent, false)
			draw_set_transform_matrix(Transform2D.IDENTITY)
		if kind == Kind.FULL:
			_draw_labels(font)
		_draw_bodies()
		draw_rect(Rect2(Vector2.ZERO, size), COLOUR_FRAME, false, 2.0)
		# N sits on the rim where north is: the top of the full map, wherever
		# the camera has turned it to on the minimap.
		var north := Vector2.UP.rotated(turn)
		var rim := centre_px + north * (minf(size.x, size.y) * 0.5 - 12.0)
		draw_string_outline(font, rim + Vector2(-4.0, 5.0), "N", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, 4, Color.BLACK)
		draw_string(font, rim + Vector2(-4.0, 5.0), "N", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, COLOUR_TEXT)
		if kind == Kind.FULL:
			draw_string(font, Vector2(10.0, size.y - 10.0), "M: 닫기 · %s" % map.title,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, COLOUR_TEXT)

	# The walkable area: filled faintly, its rim drawn clearly, nothing
	# behind it.
	func _draw_walkable() -> void:
		draw_set_transform_matrix(metres_to_px())
		if map.walk_mesh != null:
			draw_mesh(map.walk_mesh, null, Transform2D.IDENTITY, COLOUR_WALK)
		if map.walk_edges.size() >= 2:
			# The width is in metres here: two pixels' worth.
			draw_multiline(map.walk_edges, COLOUR_WALK_EDGE, 2.0 / maxf(scale_px, 0.0001))
		draw_set_transform_matrix(Transform2D.IDENTITY)

	func _draw_labels(font: Font) -> void:
		for label in map.labels:
			var text := String(label["text"])
			var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1.0, 14)
			var at := to_px(label["at"]) + Vector2(-text_size.x * 0.5, 5.0)
			draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 14, 4, Color.BLACK)
			draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 14, COLOUR_TEXT)

	func _draw_bodies() -> void:
		var local := map.local_body()
		for body in map.bodies():
			var p := px_of(body.global_position)
			var mine := body == local
			var tick := map.direction_to_map(-body.global_transform.basis.z).rotated(turn).normalized() * 12.0
			draw_line(p, p + tick, COLOUR_ME if mine else COLOUR_OTHER, 2.0)
			draw_circle(p, 5.0 if mine else 4.0, COLOUR_ME if mine else COLOUR_OTHER)
			draw_circle(p, 5.0 if mine else 4.0, Color.BLACK, false, 1.0)
