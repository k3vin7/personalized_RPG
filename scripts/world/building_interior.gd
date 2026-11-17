@tool
class_name BuildingInterior
extends Node3D

# 건물 진입 a..c: what a building marks so that its inside can be shown, and
# the walls of its ground floor, which are built from those marks.
#
# Put one of these in the building, with two children:
#
#   rooms/*   MeshInstance3D + BoxMesh: one box per room, on this node's axes
#             (not turned), covering the room's air -- wall face to wall
#             face, floor to ceiling. Rooms that open into each other touch.
#   doors/*   MeshInstance3D + BoxMesh: one box per door, filling the doorway
#             in the wall. Its long flat side is the door's width, its short
#             one the wall's thickness; which way is out is worked out.
#
# and set `wall_thickness` and `upstairs` (the nodes that are the floors
# above: anything drawn, each on its own so it can be hidden on its own).
# The boxes are for the editor and are hidden in play.
#
# c/d: the walls are pieces, not a box with its inside dug out, and they are
# ordinary nodes saved in the map under walls/ -- each a body with a box
# collider and a mesh, so one can stop being drawn while it goes on stopping
# bodies. They can be moved, resized, deleted or added to by hand. What the
# game reads off each one:
#
#   - a node whose name starts with "post" (or that is in the group
#     "interior_post") is a post; anything else is a wall;
#   - a wall faces out along its thin side, away from the room it stands
#     against (worked out from where it is and how big it is); a wall with a
#     room on both sides, or on neither, is never hidden;
#   - a post belongs to the walls it touches.
#
# While the local body is inside, the walls whose outer face is turned toward
# the camera are not drawn, nor the floors above (and a thing not drawn casts
# no shadow); a post goes only when every wall it touches has gone.
#
# The walls can be made again from the room and door boxes -- only when asked:
# the "벽 다시 만들기" button in the inspector (rebuild_walls). That replaces
# everything under walls/:
#
#   - a wall on each side of each room, `wall_thickness` thick and as high
#     as the room, except where two rooms touch and open into each other;
#   - a post (thickness x thickness) at every corner, the inner corners where
#     two rooms meet included; a wall fills only the span between two posts;
#   - a door's opening cut out of the wall it is in, with the piece over it.
#
# Nothing here is ruled on or sent: InteriorView (one, on the local screen)
# asks whether the local body is inside and drives the picture.

const GROUP := "building_interior"
const CUT_SHADER := preload("res://shaders/interior_cut.gdshader")
const MAX_ROOMS := 8
const MAX_DOORS := 8
# How far outside a door the "which way is out" probe looks.
const OUT_PROBE := 0.3
# A body this far over a ceiling box (a jump) is still in the room.
const HEADROOM := 1.0
const DOOR_LIGHT_RANGE := 5.0
# Two edges closer than this are one edge.
const SNAP := 0.001
# A wall is turned toward the camera past this much of the view's direction.
const FACING := 0.02
# The picture changes over at this much of the easing.
const SWITCH_AT := 0.5
const POST_PREFIX := "post"
const POST_GROUP := "interior_post"
# Two pieces this close are touching.
const TOUCH := 0.05

# Replaces everything under walls/ with walls made from the room and door
# boxes. In the editor the new nodes belong to the scene and are saved.
@export_tool_button("벽 다시 만들기", "Reload") var rebuild_button: Callable = rebuild_walls

@export var wall_thickness := 0.5
@export var wall_color := Color(0.9, 0.88, 0.84)
# The floors above: hidden while the local body is inside.
@export var upstairs: Array[NodePath] = []

var room_centres := PackedVector3Array()
var room_halves := PackedVector3Array()
var door_centres := PackedVector3Array()
var door_outs := PackedVector3Array()
var door_halves := PackedVector2Array()

# Whether the local body is in, kept between frames: it changes only once
# the body is wholly in or wholly out.
var inside := false

# The pieces: {"node": Node3D, "meshes": Array (MeshInstance3D), "post": bool,
# "box": AABB (in this node's space), "out": Vector3 (a wall's outward
# direction, ZERO when it is never hidden), "walls": Array[int] (a post's
# neighbours, as indices here)}.
var pieces: Array[Dictionary] = []

var _lights: Array[OmniLight3D] = []

# Every cut material in the world: the view fills them with the opened
# building's numbers, so that what stands in front of it is not drawn.
static var world_materials: Array[ShaderMaterial] = []
static var _world_by_source := {}


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_read_marks()
	_collect_pieces()
	add_to_group(GROUP)
	for mark_root in ["rooms", "doors"]:
		var marks := get_node_or_null(mark_root) as Node3D
		if marks != null:
			marks.visible = false
	_make_lights()
	# Deferred: the scene this is part of is not the current one yet.
	_dress_world.call_deferred()


func _read_marks() -> void:
	room_centres.clear()
	room_halves.clear()
	door_centres.clear()
	door_outs.clear()
	door_halves.clear()
	var rooms := get_node_or_null("rooms")
	if rooms != null:
		for child in rooms.get_children():
			var box := _box_of(child)
			if box.size == Vector3.ZERO or room_centres.size() >= MAX_ROOMS:
				continue
			room_centres.append(box.get_center())
			room_halves.append(box.size * 0.5)
	var doors := get_node_or_null("doors")
	if doors != null:
		for child in doors.get_children():
			var box := _box_of(child)
			if box.size == Vector3.ZERO or door_centres.size() >= MAX_DOORS:
				continue
			var centre := box.get_center()
			# The short flat side runs through the wall.
			var through := Vector3.RIGHT if box.size.x < box.size.z else Vector3.BACK
			var width := box.size.z if box.size.x < box.size.z else box.size.x
			var depth := minf(box.size.x, box.size.z)
			if _in_a_room(centre + through * (depth * 0.5 + OUT_PROBE), 0.0):
				through = -through
			door_centres.append(centre)
			door_outs.append(through)
			door_halves.append(Vector2(width, box.size.y) * 0.5)


# A marker's box in this node's space. The markers are not turned.
func _box_of(node: Node) -> AABB:
	var mark := node as MeshInstance3D
	if mark == null or not (mark.mesh is BoxMesh):
		return AABB()
	var size := (mark.mesh as BoxMesh).size * mark.scale
	var centre := (mark.get_parent() as Node3D).transform * mark.position
	return AABB(centre - size * 0.5, size)


func _in_a_room(at: Vector3, grow: float) -> bool:
	for i in room_centres.size():
		var q := at - room_centres[i]
		var h := room_halves[i]
		if absf(q.x) < h.x + grow and absf(q.z) < h.z + grow and q.y > -h.y - grow and q.y < h.y + HEADROOM:
			return true
	return false


# ------------------------------------------------------------ the walls as they stand

# Reads the pieces under walls/ as they are in the map.
func _collect_pieces() -> void:
	pieces.clear()
	var holder := get_node_or_null("walls")
	if holder == null:
		return
	var to_here := global_transform.affine_inverse()
	for child in holder.get_children():
		var node := child as Node3D
		if node == null:
			continue
		var meshes := node.find_children("*", "MeshInstance3D", true, false)
		if node is MeshInstance3D:
			meshes.append(node)
		var box := _piece_box(node, meshes, to_here)
		if box.size == Vector3.ZERO:
			continue
		var is_post := String(node.name).to_lower().begins_with(POST_PREFIX) or node.is_in_group(POST_GROUP)
		pieces.append({
			"node": node, "meshes": meshes, "post": is_post, "box": box,
			"out": Vector3.ZERO if is_post else _facing_of(box), "walls": [] as Array[int]})
	for i in pieces.size():
		if not pieces[i]["post"]:
			continue
		var mine := (pieces[i]["box"] as AABB).grow(TOUCH)
		var touching: Array[int] = []
		for j in pieces.size():
			if not pieces[j]["post"] and mine.intersects(pieces[j]["box"] as AABB):
				touching.append(j)
		pieces[i]["walls"] = touching


# A piece's box in this node's space: its box colliders, or failing those
# its meshes. Turned or scaled pieces are measured as they stand.
static func _piece_box(node: Node3D, meshes: Array, to_here: Transform3D) -> AABB:
	var out := AABB()
	var first := true
	var boxes: Array = []
	for found in node.find_children("*", "CollisionShape3D", true, false):
		var shape := found as CollisionShape3D
		var box_shape := shape.shape as BoxShape3D
		if box_shape != null:
			boxes.append([to_here * shape.global_transform, AABB(-box_shape.size * 0.5, box_shape.size)])
	if boxes.is_empty():
		for found in meshes:
			var mesh := found as MeshInstance3D
			if mesh.mesh != null:
				boxes.append([to_here * mesh.global_transform, mesh.get_aabb()])
	for entry: Array in boxes:
		var placed: AABB = (entry[0] as Transform3D) * (entry[1] as AABB)
		out = placed if first else out.merge(placed)
		first = false
	return out


# Which way a wall faces out: along its thin flat side, away from the room
# it has on one side. ZERO with a room on both sides or on neither.
func _facing_of(box: AABB) -> Vector3:
	var axis := Vector3.RIGHT if box.size.x <= box.size.z else Vector3.BACK
	var reach := minf(box.size.x, box.size.z) * 0.5 + OUT_PROBE
	var centre := box.get_center()
	var room_after := _in_a_room(centre + axis * reach, 0.0)
	var room_before := _in_a_room(centre - axis * reach, 0.0)
	if room_before and not room_after:
		return axis
	if room_after and not room_before:
		return -axis
	return Vector3.ZERO


# ------------------------------------------------------------ making the walls again

# Flat tests, in this node's space.
func _room_at(x: float, z: float) -> int:
	for i in room_centres.size():
		if absf(x - room_centres[i].x) < room_halves[i].x and absf(z - room_centres[i].z) < room_halves[i].z:
			return i
	return -1


# The room whose ring of wall a point is in (-1: none, or inside a room).
func _ring_at(x: float, z: float) -> int:
	if _room_at(x, z) >= 0:
		return -1
	for i in room_centres.size():
		if absf(x - room_centres[i].x) < room_halves[i].x + wall_thickness \
				and absf(z - room_centres[i].z) < room_halves[i].z + wall_thickness:
			return i
	return -1


static func _edges(values: Array[float]) -> Array[float]:
	values.sort()
	var out: Array[float] = []
	for value in values:
		if out.is_empty() or value - out[out.size() - 1] > SNAP:
			out.append(value)
	return out


# The plan is cut into cells along every room's faces, inner and outer. A
# cell that is in some room's ring of wall and in no room is solid. A solid
# cell with solid neighbours along one axis only is a stretch of wall; any
# other (a corner, a T, an end) is a post. Stretches between posts are merged
# into one wall each, and the doors are cut out of the walls they are in.
func rebuild_walls() -> void:
	_read_marks()
	var old := get_node_or_null("walls")
	if old != null:
		remove_child(old)
		old.free()
	pieces.clear()
	_wall_material = null
	if room_centres.is_empty():
		return
	var holder := Node3D.new()
	holder.name = "walls"
	add_child(holder)

	var raw_x: Array[float] = []
	var raw_z: Array[float] = []
	for i in room_centres.size():
		for reach: float in [room_halves[i].x, room_halves[i].x + wall_thickness]:
			raw_x.append(room_centres[i].x - reach)
			raw_x.append(room_centres[i].x + reach)
		for reach: float in [room_halves[i].z, room_halves[i].z + wall_thickness]:
			raw_z.append(room_centres[i].z - reach)
			raw_z.append(room_centres[i].z + reach)
	var xs := _edges(raw_x)
	var zs := _edges(raw_z)
	var nx := xs.size() - 1
	var nz := zs.size() - 1

	# kind: 0 empty, 1 wall running along z (its normal is x), 2 wall running
	# along x, 3 post.
	var solid := {}
	for ix in nx:
		for iz in nz:
			solid[Vector2i(ix, iz)] = _ring_at((xs[ix] + xs[ix + 1]) * 0.5, (zs[iz] + zs[iz + 1]) * 0.5) >= 0
	var kind := {}
	for ix in nx:
		for iz in nz:
			var cell := Vector2i(ix, iz)
			if not solid[cell]:
				kind[cell] = 0
				continue
			var along_x: bool = solid.get(cell + Vector2i(-1, 0), false) or solid.get(cell + Vector2i(1, 0), false)
			var along_z: bool = solid.get(cell + Vector2i(0, -1), false) or solid.get(cell + Vector2i(0, 1), false)
			kind[cell] = 2 if along_x and not along_z else (1 if along_z and not along_x else 3)

	var owner_of := {}
	# Walls along z: runs down each column.
	for ix in nx:
		var iz := 0
		while iz < nz:
			if kind[Vector2i(ix, iz)] != 1:
				iz += 1
				continue
			var first := iz
			while iz < nz and kind[Vector2i(ix, iz)] == 1:
				iz += 1
			var out := _outward(Vector3.RIGHT, xs[ix], xs[ix + 1], (zs[first] + zs[iz]) * 0.5, true)
			var made := _wall(holder, Rect2(xs[ix], zs[first], xs[ix + 1] - xs[ix], zs[iz] - zs[first]), out, true)
			for run in range(first, iz):
				owner_of[Vector2i(ix, run)] = made
	# Walls along x: runs along each row.
	for iz in nz:
		var ix := 0
		while ix < nx:
			if kind[Vector2i(ix, iz)] != 2:
				ix += 1
				continue
			var first := ix
			while ix < nx and kind[Vector2i(ix, iz)] == 2:
				ix += 1
			var out := _outward(Vector3.BACK, zs[iz], zs[iz + 1], (xs[first] + xs[ix]) * 0.5, false)
			var made := _wall(holder, Rect2(xs[first], zs[iz], xs[ix] - xs[first], zs[iz + 1] - zs[iz]), out, false)
			for run in range(first, ix):
				owner_of[Vector2i(run, iz)] = made
	# Posts, each with the walls it touches.
	for ix in nx:
		for iz in nz:
			var cell := Vector2i(ix, iz)
			if kind[cell] != 3:
				continue
			var touching: Array[int] = []
			for step: Vector2i in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
				for index: int in owner_of.get(cell + step, []):
					if not touching.has(index):
						touching.append(index)
			var rect := Rect2(xs[ix], zs[iz], xs[ix + 1] - xs[ix], zs[iz + 1] - zs[iz])
			var span := _height_span(rect.get_center())
			var index := _piece(holder, "post_%d_%d" % [ix, iz], rect, span.x, span.y)
			pieces[index]["post"] = true
			pieces[index]["walls"] = touching
	# Saved with the scene being edited (or, in play, just stood up and read).
	var scene_root := get_tree().edited_scene_root if Engine.is_editor_hint() else owner
	if scene_root != null:
		holder.owner = scene_root
		for node in holder.find_children("*", "", true, false):
			node.owner = scene_root
	print("BuildingInterior: %d pieces under %s" % [pieces.size(), holder.get_path()])
	if Engine.is_editor_hint():
		pieces.clear()
	else:
		_collect_pieces()


# Which way is out of a wall: the side of it that is not a room. ZERO when
# both sides are (a wall between two rooms), which is never hidden.
func _outward(axis: Vector3, low: float, high: float, mid_along: float, normal_is_x: bool) -> Vector3:
	var before := _room_at(low - SNAP * 10.0, mid_along) if normal_is_x else _room_at(mid_along, low - SNAP * 10.0)
	var after := _room_at(high + SNAP * 10.0, mid_along) if normal_is_x else _room_at(mid_along, high + SNAP * 10.0)
	if before >= 0 and after < 0:
		return axis
	if after >= 0 and before < 0:
		return -axis
	return Vector3.ZERO


# Floor and ceiling of the wall at a flat point: those of the room whose
# ring it is in.
func _height_span(at: Vector2) -> Vector2:
	var room := _ring_at(at.x, at.y)
	if room < 0:
		room = 0
	return Vector2(room_centres[room].y - room_halves[room].y, room_centres[room].y + room_halves[room].y)


# One wall between two posts, with any door in it cut out. Returns the
# indices of the pieces it became.
func _wall(holder: Node3D, rect: Rect2, out: Vector3, runs_along_z: bool) -> Array[int]:
	var made: Array[int] = []
	var span := _height_span(rect.get_center())
	var start := rect.position.y if runs_along_z else rect.position.x
	var end := rect.end.y if runs_along_z else rect.end.x
	# The doors in this wall, as [from, to, top] along it.
	var cuts: Array[Vector3] = []
	for i in door_centres.size():
		var centre := door_centres[i]
		var across := centre.x if runs_along_z else centre.z
		var low := rect.position.x if runs_along_z else rect.position.y
		var high := rect.end.x if runs_along_z else rect.end.y
		if across < low - SNAP or across > high + SNAP:
			continue
		if absf(door_outs[i].x) > 0.5 != runs_along_z:
			continue
		var along := centre.z if runs_along_z else centre.x
		var from := maxf(along - door_halves[i].x, start)
		var to := minf(along + door_halves[i].x, end)
		if to - from > SNAP:
			cuts.append(Vector3(from, to, centre.y + door_halves[i].y))
	cuts.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.x < b.x)
	var label := "wall_%s_%d" % ["z" if runs_along_z else "x", pieces.size()]
	var cursor := start
	var part := 0
	for cut in cuts:
		if cut.x - cursor > SNAP:
			made.append(_piece(holder, "%s_%d" % [label, part], _along(rect, cursor, cut.x, runs_along_z), span.x, span.y))
			part += 1
		if span.y - cut.z > SNAP:
			# The piece over the door.
			made.append(_piece(holder, "%s_over_%d" % [label, part], _along(rect, cut.x, cut.y, runs_along_z), cut.z, span.y))
			part += 1
		cursor = cut.y
	if end - cursor > SNAP:
		made.append(_piece(holder, "%s_%d" % [label, part], _along(rect, cursor, end, runs_along_z), span.x, span.y))
	for index in made:
		pieces[index]["out"] = out
	return made


static func _along(rect: Rect2, from: float, to: float, runs_along_z: bool) -> Rect2:
	if runs_along_z:
		return Rect2(rect.position.x, from, rect.size.x, to - from)
	return Rect2(from, rect.position.y, to - from, rect.size.y)


var _wall_material: StandardMaterial3D


func _piece(holder: Node3D, piece_name: String, rect: Rect2, bottom: float, top: float) -> int:
	if _wall_material == null:
		_wall_material = StandardMaterial3D.new()
		_wall_material.albedo_color = wall_color
		_wall_material.roughness = 1.0
	var size := Vector3(rect.size.x, top - bottom, rect.size.y)
	var body := StaticBody3D.new()
	body.name = piece_name
	body.collision_layer = Layers.WORLD
	body.collision_mask = 0
	body.position = Vector3(rect.get_center().x, (top + bottom) * 0.5, rect.get_center().y)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.name = "Shape"
	shape.shape = box
	body.add_child(shape)
	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	box_mesh.material = _wall_material
	mesh.mesh = box_mesh
	body.add_child(mesh)
	holder.add_child(body)
	pieces.append({"node": body, "meshes": [mesh], "post": false, "out": Vector3.ZERO, "walls": [] as Array[int]})
	return pieces.size() - 1


# ------------------------------------------------------------ the world's CSG

# The CSG of the scene being played (or the scene this building was saved
# in) gets the cut material, so that what stands between the camera and an
# opened building can be left undrawn.
func _dress_world() -> void:
	if not is_inside_tree():
		return
	var root := get_tree().current_scene
	if root == null or not root.is_ancestor_of(self):
		root = owner
	if root != null:
		_dress(root)


# Gives every plain CSG shape under `root` the cut material in place of its
# own (one per source material, keeping its colour). Shapes that already
# have it, and see-through or textured ones, are left as they are.
static func _dress(root: Node) -> void:
	for node in root.find_children("*", "CSGPrimitive3D", true, false):
		var shape := node as CSGPrimitive3D
		var source: Material = shape.get("material")
		if source is ShaderMaterial:
			continue
		var standard := source as BaseMaterial3D
		if source != null and (standard == null or standard.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED
				or standard.albedo_texture != null):
			continue
		if not _world_by_source.has(source):
			var cut := ShaderMaterial.new()
			cut.shader = CUT_SHADER
			cut.set_shader_parameter("albedo", standard.albedo_color if standard != null else Color.WHITE)
			_world_by_source[source] = cut
			world_materials.append(cut)
		shape.set("material", _world_by_source[source])


func _make_lights() -> void:
	for i in door_centres.size():
		var light := OmniLight3D.new()
		light.name = "DoorLight%d" % i
		light.omni_range = DOOR_LIGHT_RANGE
		light.shadow_enabled = false
		light.position = door_centres[i]
		light.visible = false
		add_child(light)
		_lights.append(light)


# ------------------------------------------------------------ asked by the view

# The top of the rooms, in the world: above it is upstairs.
func ceiling_y() -> float:
	var top := -INF
	for i in room_centres.size():
		top = maxf(top, room_centres[i].y + room_halves[i].y)
	return (global_transform * Vector3(0.0, top, 0.0)).y


# Whether a body (its centre and radius, in the world) is in: it goes in once
# the whole body is in a room -- past the wall the door is in -- and out once
# the whole body is clear of the walls. In a doorway it is what it was.
func update_inside(body_at: Vector3, radius: float) -> bool:
	var at := global_transform.affine_inverse() * body_at
	var probes: Array[Vector3] = [
		at, at + Vector3(radius, 0.0, 0.0), at - Vector3(radius, 0.0, 0.0),
		at + Vector3(0.0, 0.0, radius), at - Vector3(0.0, 0.0, radius)]
	var all_in := true
	var any_near := false
	for probe in probes:
		if not _in_a_room(probe, 0.0):
			all_in = false
		if _in_a_room(probe, wall_thickness):
			any_near = true
	if not inside and all_in:
		inside = true
	elif inside and not any_near:
		inside = false
	return inside


# Which side of the rooms the camera is on, per axis of this node. `to_camera`
# is the flat world direction from the body to the camera.
func near_sign(to_camera: Vector3) -> Vector2:
	var local := global_transform.basis.inverse() * to_camera
	return Vector2(1.0 if local.x >= 0.0 else -1.0, 1.0 if local.z >= 0.0 else -1.0)


# Which pieces are not drawn when the building is opened toward `to_camera`:
# the walls whose outer face is turned to the camera, and the posts all of
# whose walls are among them.
func hidden_pieces(to_camera: Vector3) -> Array[bool]:
	var local := (global_transform.basis.inverse() * to_camera).normalized()
	var out: Array[bool] = []
	out.resize(pieces.size())
	for i in pieces.size():
		var outward: Vector3 = pieces[i]["out"]
		out[i] = not pieces[i]["post"] and outward != Vector3.ZERO and outward.dot(local) > FACING
	for i in pieces.size():
		if not pieces[i]["post"]:
			continue
		var walls: Array = pieces[i]["walls"]
		var all_gone := not walls.is_empty()
		for index: int in walls:
			if not out[index]:
				all_gone = false
		out[i] = all_gone
	return out


# The picture at `amount` (0 closed, 1 opened), seen from `to_camera`.
func show_amount(amount: float, to_camera: Vector3) -> void:
	var near := near_sign(to_camera)
	for material in world_materials:
		fill(material, amount, near)
		fill_doors(material)
	var opened := amount >= SWITCH_AT
	var gone := hidden_pieces(to_camera)
	for i in pieces.size():
		for mesh: MeshInstance3D in pieces[i]["meshes"]:
			mesh.visible = not (opened and gone[i])
	for path in upstairs:
		var floor_above := get_node_or_null(path) as Node3D
		if floor_above != null:
			floor_above.visible = not opened
	var energy: float = Tuning.values.interior_door_light * amount
	for light in _lights:
		light.visible = energy > 0.0
		light.light_energy = energy


# The numbers both shaders read.
func fill(material: ShaderMaterial, amount: float, near: Vector2) -> void:
	material.set_shader_parameter("amount", amount)
	material.set_shader_parameter("to_local", global_transform.affine_inverse())
	material.set_shader_parameter("room_count", room_centres.size())
	material.set_shader_parameter("room_centre", _padded(room_centres, MAX_ROOMS))
	material.set_shader_parameter("room_half", _padded(room_halves, MAX_ROOMS))
	material.set_shader_parameter("near_sign", near)
	material.set_shader_parameter("wall", wall_thickness)


func fill_doors(material: ShaderMaterial) -> void:
	material.set_shader_parameter("door_count", door_centres.size())
	material.set_shader_parameter("door_centre", _padded(door_centres, MAX_DOORS))
	material.set_shader_parameter("door_out", _padded(door_outs, MAX_DOORS))
	var halves := door_halves.duplicate()
	halves.resize(MAX_DOORS)
	material.set_shader_parameter("door_half", halves)
	material.set_shader_parameter("glimpse", Tuning.values.interior_door_glimpse)


static func _padded(values: PackedVector3Array, count: int) -> PackedVector3Array:
	var out := values.duplicate()
	out.resize(count)
	return out
