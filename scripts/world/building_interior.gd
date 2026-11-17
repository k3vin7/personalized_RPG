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
#   - a door's opening cut out of the wall it is in, with the piece over it
#     and a post on either side of it;
#   - more posts along each wall, about `post_spacing` apart, evened out to
#     the wall's length; a wall piece spans from one post to the next;
#   - floor: the rooms' floor, drawn only, one polygon;
#   - lights/torch_*: a torch light high on every second post (lights/ may
#     hold other lights, such as candle_*; those are left alone).
#
# The lights under lights/ are on only while the local body is inside. They
# are not children of the walls, so a wall that is not drawn keeps its light.
#
# Nothing here is ruled on or sent: InteriorView (one, on the local screen)
# asks whether the local body is inside and drives the picture.

const GROUP := "building_interior"
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
# What "벽 다시 만들기" paints the pieces it makes, and how far apart it
# stands the posts along a wall (the spans are evened out to fit the wall).
@export var wall_color := Color("d8cfc4")
@export var post_color := Color("9c5f40")
@export var floor_color := Color("8c6650")
@export var torch_color := Color("ffb060")
@export var post_spacing := 4.0
# A wall stands this far back from each face of the posts (which are
# `wall_thickness` square): the posts stand proud of the wall, as timber.
@export var wall_inset := 0.1
# The storey whose posts this one's stand over (the storey below; for a
# cellar, the one above). Where a wall of this storey runs along a wall of
# that one, its posts are put where that one's are, so they line up from the
# ground to the roof. Empty, or no wall there: evenly spaced.
@export var post_from: NodePath
# A storey that stands out over the one below (a jetty) has its walls this
# far, at most, outside the walls they take their posts from: the posts keep
# their places along the wall and move out with it.
@export var post_match_reach := 0.6
# A torch on every this-many-th post.
@export var torch_every := 2
# How far short of the rooms' top the walls and posts stop: the thickness
# of the floor that lies over this storey. A wall that ran up into that
# floor had its top in the floor's top, and the two shimmered (measured: 103
# walls and 48 posts of the pub). 0 where only a roof is above.
@export var ceiling_drop := 0.0
# Automatic windows: one in every this-many-th stretch that could take one,
# and only in the walls of these rooms (the room boxes' names; empty: all).
@export var auto_window_every := 2
@export var window_rooms := PackedStringArray()
# Timber on the outer face of the outer walls, drawn only: upright studs
# about this far apart and a rail across the walls that have no window.
# 0: none.
@export var stud_spacing := 1.3
# A band along the foot of the outer walls, standing out from the posts: on
# the ground storey a stone base, on an upper storey the beam that shows
# where one storey ends and the next begins. 0: none (a cellar).
@export var trim_height := 0.3
@export var trim_depth := 0.08
@export var trim_color := Color("9c5f40")
# Windows. A box under windows/ (like a door's box, but off the floor) is a
# window where it stands. With no windows/ node and `auto_windows` on, every
# stretch of outer wall between two posts that is at least
# `auto_window_min` long gets one in its middle, `window_size` wide and
# high, its sill `window_sill` above the floor. A window is a hole to see
# through: the wall under it and over it stays, and nothing walks through.
@export var auto_windows := true
@export var auto_window_min := 2.5
@export var window_size := Vector2(1.2, 1.2)
@export var window_sill := 1.0
# The cut face of a wall that has been cut down for the view.
@export var cut_color := Color("3a2a22")
# How thick a floor "벽 다시 만들기" lays. 0: the ground storey -- the ground
# under it is what bodies stand on, and the floor is only drawn. More: an
# upper storey -- a slab this thick with a collider, its top at the rooms'
# floor. Either way the boxes under holes/ (a stairwell) are cut out of it,
# wherever they are.
@export var floor_thickness := 0.0
# A camera-side wall is not taken away whole: this much of it is left
# standing, so the room's outline and its doors can still be read. 0: none.
@export var stub_height := 0.5
# The rail "벽 다시 만들기" stands round a stair's opening.
@export var rail_height := 1.0
@export var rail_thickness := 0.1

# Lays the floor (with its openings) and the rails again, and nothing else.
@export_tool_button("바닥·난간 다시 만들기", "Reload") var floor_button: Callable = rebuild_floor
# The floors above: hidden while the local body is inside.
# What belongs to this storey but is not under this node (the furniture).
@export var members: Array[NodePath] = []

var room_centres := PackedVector3Array()
var room_halves := PackedVector3Array()
var room_names := PackedStringArray()
var door_centres := PackedVector3Array()
var door_outs := PackedVector3Array()
var door_halves := PackedVector2Array()
# The window boxes under windows/, in this node's space.
# Per door: whether it is between two rooms of this storey (no light, no lit
# strip, not a way out) rather than in an outer wall.
var door_inside: Array[bool] = []
var window_boxes: Array[AABB] = []
var _has_window_marks := false
# Whether the local body is in, kept between frames: it changes only once
# the body is wholly in or wholly out.
var inside := false

# The pieces: {"node": Node3D, "meshes": Array (MeshInstance3D), "post": bool,
# "box": AABB (in this node's space), "out": Vector3 (a wall's outward
# direction, ZERO when it is never hidden), "walls": Array[int] (a post's
# neighbours, as indices here)}.
var pieces: Array[Dictionary] = []

# [light, space] for each way out; [strip, space it is seen from] for each
# strip beyond a door.
var _door_lights: Array = []
var _strips: Array = []
# The lights under lights/, as saved in the map: torches and candles.
var _lamps: Array[OmniLight3D] = []
# Per lamp: the space it stands in.
var _lamp_space := PackedInt32Array()

# Instance id of a node listed in some storey's `members` -> that storey.
static var _member_of := {}


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_read_marks()
	_collect_pieces()
	_collect_lamps()
	_collect_things()
	for path in members:
		var member := get_node_or_null(path)
		if member != null:
			_member_of[member.get_instance_id()] = self
	add_to_group(GROUP)
	for mark_root in ["rooms", "doors", "holes", "windows"]:
		var marks := get_node_or_null(mark_root) as Node3D
		if marks != null:
			marks.visible = false
	_make_door_marks()


func _read_marks() -> void:
	room_centres.clear()
	room_names.clear()
	room_halves.clear()
	door_centres.clear()
	door_outs.clear()
	door_halves.clear()
	door_inside.clear()
	door_room_in.resize(0)
	door_room_out.resize(0)
	window_boxes.clear()
	var windows := get_node_or_null("windows")
	_has_window_marks = windows != null
	if windows != null:
		for child in windows.get_children():
			var box := _box_of(child)
			if box.size != Vector3.ZERO:
				window_boxes.append(box)
	var rooms := get_node_or_null("rooms")
	if rooms != null:
		for child in rooms.get_children():
			var box := _box_of(child)
			if box.size == Vector3.ZERO:
				continue
			room_centres.append(box.get_center())
			room_halves.append(box.size * 0.5)
			room_names.append(String(child.name))
	_find_spaces()
	var doors := get_node_or_null("doors")
	if doors != null:
		for child in doors.get_children():
			var box := _box_of(child)
			if box.size == Vector3.ZERO:
				continue
			var centre := box.get_center()
			# The short flat side runs through the wall.
			var through := Vector3.RIGHT if box.size.x < box.size.z else Vector3.BACK
			var width := box.size.z if box.size.x < box.size.z else box.size.x
			var depth := minf(box.size.x, box.size.z)
			var ahead := centre + through * (depth * 0.5 + OUT_PROBE)
			var behind := centre - through * (depth * 0.5 + OUT_PROBE)
			var room_ahead := _in_a_room(ahead, 0.0)
			var room_behind := _in_a_room(behind, 0.0)
			door_inside.append(room_ahead and room_behind)
			if room_ahead:
				through = -through
				door_room_in.append(_room_at(ahead.x, ahead.z))
				door_room_out.append(_room_at(behind.x, behind.z) if room_behind else -1)
			else:
				door_room_in.append(_room_at(behind.x, behind.z) if room_behind else -1)
				door_room_out.append(-1)
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


# ------------------------------------------------------------ spaces
#
# A space is the rooms of this storey that open into each other with no door
# between: a hall and the wing off it are one space, a kitchen behind a door
# is another, every guest room is its own. It is worked out from the room
# boxes (rooms whose boxes touch are one space).
#
# Inside the building the picture is one space at a time, the one the body
# is in: its floor, the walls round it, what stands in it, its lights. The
# rest of the storey is not drawn. A doorway shows a strip of the floor
# beyond it, and that strip is where a click lands to go through.
#
# The body is in a space once it is wholly in rooms of that space -- past the
# door -- as it is in a building once it is wholly through the door.

# Per room: the space it is in. Spaces are numbered from 0.
var room_space := PackedInt32Array()
var space_count := 0
# The space the local body is in, while this storey is the one it is on.
var current_space := -1
# Per door: the room it leads out of (on the side away from `door_outs`) and
# the room it leads into (-1: outside).
var door_room_in := PackedInt32Array()
var door_room_out := PackedInt32Array()


func _find_spaces() -> void:
	var count := room_centres.size()
	var group: Array[int] = []
	for i in count:
		group.append(i)
	var changed := true
	while changed:
		changed = false
		for a in count:
			for b in range(a + 1, count):
				if group[a] != group[b] and _rooms_touch(a, b):
					var low := mini(group[a], group[b])
					var high := maxi(group[a], group[b])
					for k in count:
						if group[k] == high:
							group[k] = low
					changed = true
	var numbers := {}
	room_space.resize(count)
	for i in count:
		if not numbers.has(group[i]):
			numbers[group[i]] = numbers.size()
		room_space[i] = numbers[group[i]]
	space_count = numbers.size()


# Whether two rooms' boxes share a stretch of side: they open into each other.
func _rooms_touch(a: int, b: int) -> bool:
	var ca := room_centres[a]
	var ha := room_halves[a]
	var cb := room_centres[b]
	var hb := room_halves[b]
	var over_x := minf(ca.x + ha.x, cb.x + hb.x) - maxf(ca.x - ha.x, cb.x - hb.x)
	var over_z := minf(ca.z + ha.z, cb.z + hb.z) - maxf(ca.z - ha.z, cb.z - hb.z)
	return (absf(over_x) < SNAP * 5.0 and over_z > 0.1) or (absf(over_z) < SNAP * 5.0 and over_x > 0.1)


# The space of a point of this node's space: the room it is in, or failing
# that the room it is nearest (a doorway, a wall).
func space_at(at: Vector3) -> int:
	if room_centres.is_empty():
		return -1
	var room := _room_at(at.x, at.z)
	if room < 0:
		var best := INF
		for i in room_centres.size():
			var dx := maxf(absf(at.x - room_centres[i].x) - room_halves[i].x, 0.0)
			var dz := maxf(absf(at.z - room_centres[i].z) - room_halves[i].z, 0.0)
			if dx * dx + dz * dz < best:
				best = dx * dx + dz * dz
				room = i
	return room_space[room]


func space_of_world(point: Vector3) -> int:
	return space_at(global_transform.affine_inverse() * point)


# Moves the local body's space on: to another space once the whole body is
# in rooms of it. In a doorway it is what it was.
func update_space(body_at: Vector3, radius: float) -> int:
	var at := global_transform.affine_inverse() * body_at
	if current_space < 0:
		current_space = space_at(at)
		return current_space
	var found := -1
	for offset: Vector3 in [Vector3.ZERO, Vector3(radius, 0.0, 0.0), Vector3(-radius, 0.0, 0.0),
			Vector3(0.0, 0.0, radius), Vector3(0.0, 0.0, -radius)]:
		var room := _room_at(at.x + offset.x, at.z + offset.z)
		if room < 0:
			return current_space
		if found >= 0 and room_space[room] != found:
			return current_space
		found = room_space[room]
	current_space = found
	return current_space


# Whether a door leads out of, or into, a space.
func _door_touches(door: int, space: int) -> bool:
	return (door_room_in[door] >= 0 and room_space[door_room_in[door]] == space) \
		or (door_room_out[door] >= 0 and room_space[door_room_out[door]] == space)


# The things of this storey that stand in one space and are drawn with it:
# [node, space]. The furniture (each child of furniture/ is a group, or
# furniture/ itself when it holds the shapes directly), the pillars, the
# rails.
var _things: Array = []


func _collect_things() -> void:
	_things.clear()
	var to_here := global_transform.affine_inverse()
	for holder_name: String in ["furniture", "pillars", "rails"]:
		var holder := get_node_or_null(holder_name) as Node3D
		if holder == null:
			continue
		var groups: Array = []
		if holder is CSGShape3D:
			groups.append(holder)
		else:
			groups = holder.get_children()
		for found in groups:
			var thing := found as Node3D
			if thing == null:
				continue
			var middle := Vector3.ZERO
			var parts := 0
			for child in thing.get_children():
				var part := child as Node3D
				if part != null and not (part is CollisionShape3D) and not (part is MeshInstance3D):
					middle += to_here * part.global_position
					parts += 1
			middle = middle / float(parts) if parts > 0 else to_here * thing.global_position
			_things.append([thing, space_at(middle)])


# ------------------------------------------------------------ the walls as they stand

func _collect_lamps() -> void:
	_lamps.clear()
	var holder := get_node_or_null("lights")
	if holder == null:
		return
	for child in holder.get_children():
		var lamp := child as OmniLight3D
		if lamp != null:
			lamp.shadow_enabled = false
			lamp.visible = false
			_lamps.append(lamp)
	_lamp_space.resize(_lamps.size())
	for i in _lamps.size():
		_lamp_space[i] = space_at(_lamps[i].position)


# Reads the pieces under walls/ as they are in the map. Of each wall: the
# spaces it bounds, and for each which way is out of that space through it
# ("sides"). A wall between two spaces bounds both, and is cut down for
# whichever of them the body is in when its far side is toward the camera.
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
		var rest: Array[Transform3D] = []
		for found in meshes:
			rest.append((found as MeshInstance3D).transform)
		pieces.append({
			"node": node, "meshes": meshes, "rest": rest, "post": is_post, "box": box,
			"sides": {} if is_post else _sides_of(box), "walls": [] as Array[int]})
	for i in pieces.size():
		if not pieces[i]["post"]:
			continue
		var mine := (pieces[i]["box"] as AABB).grow(TOUCH)
		var touching: Array[int] = []
		for j in pieces.size():
			if not pieces[j]["post"] and mine.intersects(pieces[j]["box"] as AABB):
				touching.append(j)
		pieces[i]["walls"] = touching


# The spaces a wall bounds, each with the way out of it through the wall.
# ZERO for a wall with the same space on both sides: it is never cut down.
# The wall's thin side is tried first, then the other (a stub of wall
# shorter than it is thick). A piece no room is found beside is of the space
# it is nearest.
func _sides_of(box: AABB) -> Dictionary:
	var centre := box.get_center()
	var thin_x := box.size.x <= box.size.z
	var within := -1
	for axis: Vector3 in ([Vector3.RIGHT, Vector3.BACK] if thin_x else [Vector3.BACK, Vector3.RIGHT]):
		var reach := (box.size.x if axis.x > 0.5 else box.size.z) * 0.5 + OUT_PROBE
		var after := _room_at(centre.x + axis.x * reach, centre.z + axis.z * reach)
		var before := _room_at(centre.x - axis.x * reach, centre.z - axis.z * reach)
		if after < 0 and before < 0:
			continue
		if after >= 0 and before >= 0 and room_space[after] == room_space[before]:
			within = room_space[after]
			continue
		var out := {}
		if after >= 0:
			out[room_space[after]] = -axis
		if before >= 0:
			out[room_space[before]] = axis
		return out
	return {(within if within >= 0 else space_at(centre)): Vector3.ZERO}


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
	_window_turn = 0
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
			var index := _piece(holder, "post_%d_%d" % [ix, iz], rect, span.x, span.y, true)
			pieces[index]["walls"] = touching
	_build_trim()
	var floor_holder := _build_floor()
	var rails_holder := _build_rails()
	var lights_holder := _build_torches()
	# Saved with the scene being edited (or, in play, just stood up and read).
	var scene_root := get_tree().edited_scene_root if Engine.is_editor_hint() else owner
	if scene_root != null:
		for made_holder: Node in [holder, floor_holder, rails_holder, lights_holder]:
			made_holder.owner = scene_root
			for node in made_holder.find_children("*", "", true, false):
				node.owner = scene_root
	print("BuildingInterior: %d pieces under %s, %d floor pieces, %d lights" % [
		pieces.size(), holder.get_path(), floor_holder.get_child_count(), lights_holder.get_child_count()])
	if Engine.is_editor_hint():
		pieces.clear()
	else:
		_collect_pieces()
		_collect_lamps()
		_collect_things()


# The band along the foot of each outer wall: a mesh under that wall's own
# node, so it goes when the wall is cut down. It reaches half a post past
# each end of the wall, so the bands of neighbouring walls meet in front of
# the post between them.
const TRIM_NAME := "Trim"
const THRESHOLD_HEIGHT := 0.06


func _build_trim() -> void:
	var material := _flat_material(trim_color)
	for piece in pieces:
		var outward: Vector3 = piece["out"]
		if piece["post"] or outward == Vector3.ZERO:
			continue
		var body := piece["node"] as Node3D
		var size := ((body.get_node("Shape") as CollisionShape3D).shape as BoxShape3D).size
		var floor_y := _height_span(Vector2(body.position.x, body.position.z)).x
		if String(body.name).contains("_over_"):
			# The piece over a door: a threshold under it, on the floor.
			var sill := MeshInstance3D.new()
			sill.name = "Threshold"
			var sill_box := BoxMesh.new()
			sill_box.size = Vector3(size.x, THRESHOLD_HEIGHT, wall_thickness) if absf(outward.x) < 0.5 \
				else Vector3(wall_thickness, THRESHOLD_HEIGHT, size.z)
			sill_box.material = _post_material
			sill.mesh = sill_box
			sill.position = Vector3(0.0, floor_y - body.position.y + THRESHOLD_HEIGHT * 0.5, 0.0)
			body.add_child(sill)
			continue
		if absf(body.position.y - size.y * 0.5 - floor_y) > 0.05 or trim_height <= 0.0:
			continue
		var along_x := absf(outward.x) < 0.5
		var length := size.x if along_x else size.z
		# Half a post longer at an end that meets a post, so that the bands of
		# two walls join in front of it. Not at an end that meets another
		# piece of wall (beside a window): there both were made longer, and
		# lay in each other (measured: some 300 pairs of faces).
		var more_low := 0.0 if _band_stops(body, along_x, -1.0, outward) else wall_thickness * 0.5
		var more_high := 0.0 if _band_stops(body, along_x, 1.0, outward) else wall_thickness * 0.5
		var reach := length + more_low + more_high
		var shift := (more_high - more_low) * 0.5
		var band := MeshInstance3D.new()
		band.name = TRIM_NAME
		var box := BoxMesh.new()
		box.size = Vector3(reach if along_x else trim_depth, trim_height, trim_depth if along_x else reach)
		box.material = material
		band.mesh = box
		band.position = outward * (wall_thickness * 0.5 + trim_depth * 0.5) + Vector3(0.0, -size.y * 0.5 + trim_height * 0.5, 0.0) \
			+ (Vector3(shift, 0.0, 0.0) if along_x else Vector3(0.0, 0.0, shift))
		body.add_child(band)
	_build_timber()


# Whether a wall's band ends with the wall on the given side: where another
# piece of wall stands end to end with it, and at an inside corner, where
# going on would run it into the wall round the corner.
func _band_stops(body: Node3D, along_x: bool, side: float, outward: Vector3) -> bool:
	if _wall_adjoins(body, along_x, side):
		return true
	var size := ((body.get_node("Shape") as CollisionShape3D).shape as BoxShape3D).size
	var run := Vector3(side, 0.0, 0.0) if along_x else Vector3(0.0, 0.0, side)
	var beyond := body.position + run * ((size.x if along_x else size.z) * 0.5 + wall_thickness * 0.25) 		+ outward * (wall_thickness * 0.5 + trim_depth * 0.5)
	return _ring_at(beyond.x, beyond.z) >= 0 or _room_at(beyond.x, beyond.z) >= 0


# Whether another piece of wall (not a post) stands end to end with this one
# on the given side along its length.
func _wall_adjoins(body: Node3D, along_x: bool, side: float) -> bool:
	var size := ((body.get_node("Shape") as CollisionShape3D).shape as BoxShape3D).size
	var end := (body.position.x if along_x else body.position.z) + side * (size.x if along_x else size.z) * 0.5
	for piece in pieces:
		var other := piece["node"] as Node3D
		if piece["post"] or other == body:
			continue
		var other_size := ((other.get_node("Shape") as CollisionShape3D).shape as BoxShape3D).size
		if absf((other.position.z if along_x else other.position.x) - (body.position.z if along_x else body.position.x)) > 0.05:
			continue
		var other_end := (other.position.x if along_x else other.position.z) - side * (other_size.x if along_x else other_size.z) * 0.5
		if absf(other_end - end) < 0.02:
			return true
	return false


# Timber on the outer face of each outer wall, as meshes under that wall's
# own node (so they go with it when it is cut down): upright studs, and a
# rail across a wall that reaches from floor to ceiling. The studs stand a
# little prouder than the rail, so their faces are not in one plane.
const STUD_WIDTH := 0.12
const STUD_PROUD := 0.05
const RAIL_PROUD := 0.03
const RAIL_HEIGHT := 0.12


func _build_timber() -> void:
	if stud_spacing <= 0.0:
		return
	for piece in pieces:
		var outward: Vector3 = piece["out"]
		if piece["post"] or outward == Vector3.ZERO:
			continue
		var body := piece["node"] as Node3D
		var size := ((body.get_node("Shape") as CollisionShape3D).shape as BoxShape3D).size
		var along_x := absf(outward.x) < 0.5
		var length := size.x if along_x else size.z
		var thin := size.z if along_x else size.x
		var count := maxi(0, roundi(length / stud_spacing) - 1)
		for i in count:
			var at := -length * 0.5 + length * float(i + 1) / float(count + 1)
			var stud := MeshInstance3D.new()
			stud.name = "Stud%d" % i
			var box := BoxMesh.new()
			box.size = Vector3(STUD_WIDTH if along_x else STUD_PROUD, size.y, STUD_PROUD if along_x else STUD_WIDTH)
			box.material = _post_material
			stud.mesh = box
			stud.position = outward * (thin * 0.5 + STUD_PROUD * 0.5) + (Vector3(at, 0.0, 0.0) if along_x else Vector3(0.0, 0.0, at))
			body.add_child(stud)
		var floor_y := _height_span(Vector2(body.position.x, body.position.z))
		var whole := absf(body.position.y - size.y * 0.5 - floor_y.x) < 0.05 and absf(body.position.y + size.y * 0.5 - floor_y.y) < 0.05
		if whole and length > 0.6:
			var rail := MeshInstance3D.new()
			rail.name = "Rail"
			var bar := BoxMesh.new()
			bar.size = Vector3(length if along_x else RAIL_PROUD, RAIL_HEIGHT, RAIL_PROUD if along_x else length)
			bar.material = _post_material
			rail.mesh = bar
			rail.position = outward * (thin * 0.5 + RAIL_PROUD * 0.5) + Vector3(0.0, size.y * 0.1, 0.0)
			body.add_child(rail)


func rebuild_floor() -> void:
	_read_marks()
	var made: Array[Node] = [_build_floor(), _build_rails()]
	var scene_root := get_tree().edited_scene_root if Engine.is_editor_hint() else owner
	if scene_root != null:
		for made_holder in made:
			made_holder.owner = scene_root
			for node in made_holder.find_children("*", "", true, false):
				node.owner = scene_root
	print("BuildingInterior %s: %d floor pieces, %d rails" % [
		name, made[0].get_child_count(), made[1].get_child_count()])


# The stairs of this building that touch this storey, each with the end of
# it that is on this storey, in this node's space.
func _stair_ends() -> Array[Vector3]:
	var ends: Array[Vector3] = []
	var to_here := global_transform.affine_inverse()
	for sibling in get_parent().get_children():
		var stair := sibling as BuildingStair
		if stair == null:
			continue
		if stair.lower_storey() == self:
			ends.append(to_here * (stair.global_transform * stair.foot))
		if stair.upper_storey() == self:
			ends.append(to_here * (stair.global_transform * stair.head))
	return ends


# What a rail is drawn as: uprights, a top bar, a bar half way up and a kerb
# along the floor. The collider is the one solid box it always was.
const RAIL_UPRIGHT := 0.08
const RAIL_BAR := 0.06
const RAIL_KERB := 0.1
const RAIL_UPRIGHT_GAP := 1.2


func _rail_look(body: Node3D, size: Vector3, material: Material) -> void:
	var along_x := size.x >= size.z
	var length := size.x if along_x else size.z
	var parts: Array = []
	# [name, middle, size]
	var bar := Vector3(length, RAIL_BAR, RAIL_BAR) if along_x else Vector3(RAIL_BAR, RAIL_BAR, length)
	parts.append(["Top", Vector3(0.0, size.y * 0.5 - RAIL_BAR * 0.5, 0.0), bar])
	parts.append(["Middle", Vector3(0.0, 0.0, 0.0), bar])
	parts.append(["Kerb", Vector3(0.0, -size.y * 0.5 + RAIL_KERB * 0.5, 0.0),
		Vector3(length, RAIL_KERB, RAIL_KERB + 0.02) if along_x else Vector3(RAIL_KERB + 0.02, RAIL_KERB, length)])
	var count := maxi(2, ceili(length / RAIL_UPRIGHT_GAP) + 1)
	for i in count:
		var at := -length * 0.5 + RAIL_UPRIGHT * 0.5 + (length - RAIL_UPRIGHT) * float(i) / float(count - 1)
		parts.append(["Upright%d" % i, Vector3(at, 0.0, 0.0) if along_x else Vector3(0.0, 0.0, at),
			Vector3(RAIL_UPRIGHT, size.y, RAIL_UPRIGHT)])
	for part: Array in parts:
		var mesh := MeshInstance3D.new()
		mesh.name = String(part[0])
		var drawn := BoxMesh.new()
		drawn.size = part[2]
		drawn.material = material
		mesh.mesh = drawn
		mesh.position = part[1]
		body.add_child(mesh)


# A rail along each side of each opening in the floor, except the sides that
# are a wall already and the sides a stair comes onto or leaves by. A rail
# also stops RAIL_CLEAR short of a stair's end, wherever that end is: a body
# has to be able to walk round onto the stair, and a rail right up to its
# corner closes the way (measured: it cut the cellar off).
const RAIL_STAIR_GAP := 0.6
const RAIL_CLEAR := 1.2


func _build_rails() -> Node3D:
	var old := get_node_or_null("rails")
	if old != null:
		remove_child(old)
		old.free()
	var holder := Node3D.new()
	holder.name = "rails"
	add_child(holder)
	var holes := get_node_or_null("holes")
	if holes == null:
		return holder
	var ends := _stair_ends()
	var material := _flat_material(post_color)
	for child in holes.get_children():
		var box := _box_of(child)
		if box.size == Vector3.ZERO:
			continue
		var level := _height_span(Vector2(box.get_center().x, box.get_center().z)).x
		var low := Vector2(box.position.x, box.position.z)
		var high := Vector2(box.end.x, box.end.z)
		# [from, to, the way out of the opening across this side]
		var sides := [
			[Vector2(low.x, low.y), Vector2(high.x, low.y), Vector2(0.0, -1.0)],
			[Vector2(low.x, high.y), Vector2(high.x, high.y), Vector2(0.0, 1.0)],
			[Vector2(low.x, low.y), Vector2(low.x, high.y), Vector2(-1.0, 0.0)],
			[Vector2(high.x, low.y), Vector2(high.x, high.y), Vector2(1.0, 0.0)],
		]
		var number := 0
		for edge: Array in sides:
			var from: Vector2 = edge[0]
			var to: Vector2 = edge[1]
			var outward: Vector2 = edge[2]
			var middle := (from + to) * 0.5
			# No floor beyond this side: it is a wall.
			if _room_at(middle.x + outward.x * OUT_PROBE, middle.y + outward.y * OUT_PROBE) < 0:
				continue
			var stair_here := false
			for end in ends:
				var flat := Vector2(end.x, end.z)
				var nearest := Geometry2D.get_closest_point_to_segment(flat, from, to)
				if nearest.distance_to(flat) <= RAIL_STAIR_GAP and absf(end.y - level) <= 0.5:
					stair_here = true
			if stair_here:
				continue
			# Trimmed back from each stair end near it.
			var line := (to - from).normalized()
			var start := 0.0
			var stop := from.distance_to(to)
			for end in ends:
				if absf(end.y - level) > 0.5:
					continue
				var flat := Vector2(end.x, end.z) - from
				var along := flat.dot(line)
				var off := absf(flat.cross(line))
				if off >= RAIL_CLEAR:
					continue
				var reach := sqrt(RAIL_CLEAR * RAIL_CLEAR - off * off)
				# The longer of what is left on either side of the cut.
				if along - reach - start >= stop - (along + reach):
					stop = minf(stop, along - reach)
				else:
					start = maxf(start, along + reach)
			if stop - start < rail_thickness * 2.0:
				continue
			to = from + line * stop
			from = from + line * start
			middle = (from + to) * 0.5
			# A rail along x runs half its thickness past each corner; one along
			# z stops that much short, so two that meet at a corner abut.
			var along_x_rail := absf(to.x - from.x) >= absf(to.y - from.y)
			var size := Vector3(absf(to.x - from.x) + rail_thickness, rail_height, rail_thickness) if along_x_rail \
				else Vector3(rail_thickness, rail_height, maxf(absf(to.y - from.y) - rail_thickness, rail_thickness))
			var body := StaticBody3D.new()
			body.name = "rail_%s_%d" % [child.name, number]
			number += 1
			body.collision_layer = Layers.WORLD
			body.collision_mask = 0
			body.position = Vector3(middle.x, level + rail_height * 0.5, middle.y)
			var shape := CollisionShape3D.new()
			shape.name = "Shape"
			var solid := BoxShape3D.new()
			solid.size = size
			shape.shape = solid
			body.add_child(shape)
			_rail_look(body, size, material)
			holder.add_child(body)
	return holder


# The rooms' floor and the doors' thresholds as one piece: a CSGPolygon3D
# whose outline is the rooms and the doorways joined together, drawn only
# (the ground under it is what bodies stand on), a hair above that ground.
# One piece has no seams for anything to show through; the outline can be
# edited by hand afterwards. Nothing is laid under the walls: where a wall is
# not drawn there is then nothing to draw.
#
# One piece is also one object to the renderer, which lights an object with
# only so many lights: rendering/limits/opengl/max_lights_per_object is
# raised in the project settings for this.
const FLOOR_LIFT := 0.01


func _build_floor() -> Node3D:
	var old := get_node_or_null("floor")
	if old != null:
		remove_child(old)
		old.free()
	# One floor to a space, so that a space can be drawn on its own; and one
	# small piece in each doorway between two spaces, which is of both.
	var holder := Node3D.new()
	holder.name = "floor"
	add_child(holder)
	var slab := floor_thickness > 0.0
	var under := floor_thickness if slab else FLOOR_LIFT
	var depth := floor_thickness if slab else FLOOR_LIFT * 2.0
	var material := _flat_material(floor_color)
	for space in space_count:
		var rects: Array[Rect2] = []
		var bottom := INF
		for i in room_centres.size():
			if room_space[i] != space:
				continue
			rects.append(Rect2(
				room_centres[i].x - room_halves[i].x, room_centres[i].z - room_halves[i].z,
				room_halves[i].x * 2.0, room_halves[i].z * 2.0))
			bottom = minf(bottom, room_centres[i].y - room_halves[i].y)
		# A way out of the building is part of the floor of the room it leaves.
		for i in door_centres.size():
			if door_inside[i] or door_room_in[i] < 0 or room_space[door_room_in[i]] != space:
				continue
			rects.append(_door_rect(i))
		# Joined one at a time: rooms that touch and the doorways in their
		# walls make one outline.
		var outline := PackedVector2Array()
		var waiting := rects.duplicate()
		var grew := true
		while grew and not waiting.is_empty():
			grew = false
			for rect: Rect2 in waiting.duplicate():
				var corners := PackedVector2Array([
					rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)])
				if outline.is_empty():
					outline = corners
				else:
					var joined := Geometry2D.merge_polygons(outline, corners)
					var solid: Array[PackedVector2Array] = []
					for polygon in joined:
						if not Geometry2D.is_polygon_clockwise(polygon):
							solid.append(polygon)
					if solid.size() != 1:
						continue
					outline = solid[0]
				waiting.erase(rect)
				grew = true
		# The outline as one polygon, with each opening (the boxes under
		# holes/) taken out of it by the engine's own CSG -- so an opening may
		# be anywhere, the middle of the floor included.
		var piece := CSGCombiner3D.new()
		piece.name = "space_%d" % space
		piece.use_collision = slab
		if not slab:
			piece.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var plate := CSGPolygon3D.new()
		plate.name = "plate"
		# The outline's (x, y) are this node's (x, z); the plate goes from
		# `under` below the rooms' floor up to it.
		plate.transform = Transform3D(Basis(Vector3.RIGHT, Vector3.BACK, Vector3.DOWN), Vector3(0.0, bottom - under, 0.0))
		plate.polygon = outline
		plate.depth = depth
		plate.material = material
		piece.add_child(plate)
		var holes := get_node_or_null("holes")
		if holes != null:
			for child in holes.get_children():
				var box := _box_of(child)
				if box.size == Vector3.ZERO or space_at(box.get_center()) != space:
					continue
				var opening := CSGBox3D.new()
				opening.name = "opening_%s" % child.name
				opening.operation = CSGShape3D.OPERATION_SUBTRACTION
				opening.size = Vector3(box.size.x, depth + 0.2, box.size.z)
				opening.position = Vector3(box.get_center().x, bottom - under + depth * 0.5, box.get_center().z)
				opening.material = material
				piece.add_child(opening)
		holder.add_child(piece)
	for i in door_centres.size():
		if not door_inside[i]:
			continue
		var rect := _door_rect(i)
		var sill := CSGBox3D.new()
		sill.name = "sill_%d" % i
		sill.use_collision = slab
		if not slab:
			sill.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		sill.size = Vector3(rect.size.x, depth, rect.size.y)
		sill.position = Vector3(rect.get_center().x, door_centres[i].y - door_halves[i].y - under + depth * 0.5, rect.get_center().y)
		sill.material = material
		holder.add_child(sill)
	return holder


# A doorway's patch of floor: the door's width, through the wall.
func _door_rect(door: int) -> Rect2:
	var along_x := absf(door_outs[door].x) < 0.5
	var half := Vector2(door_halves[door].x if along_x else wall_thickness * 0.5,
		wall_thickness * 0.5 if along_x else door_halves[door].x)
	return Rect2(door_centres[door].x - half.x, door_centres[door].z - half.y, half.x * 2.0, half.y * 2.0)


# A torch light high on every second post, going round the building. Other
# lights under lights/ (candles put there by hand) are left alone.
const TORCH_PREFIX := "torch"
const CANDLE_PREFIX := "candle"
const TORCH_BELOW_TOP := 0.6
const TORCH_OFF_POST := 0.2


func _build_torches() -> Node3D:
	var holder := get_node_or_null("lights") as Node3D
	if holder == null:
		holder = Node3D.new()
		holder.name = "lights"
		add_child(holder)
	for child in holder.get_children():
		if String(child.name).begins_with(TORCH_PREFIX):
			holder.remove_child(child)
			child.free()
	var middle := Vector3.ZERO
	var posts: Array[Node3D] = []
	for piece in pieces:
		if piece["post"]:
			posts.append(piece["node"] as Node3D)
			middle += (piece["node"] as Node3D).position
	if posts.is_empty():
		return holder
	middle /= float(posts.size())
	posts.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		return atan2(a.position.z - middle.z, a.position.x - middle.x) < atan2(b.position.z - middle.z, b.position.x - middle.x))
	var number := 0
	for i in range(0, posts.size(), maxi(torch_every, 1)):
		var post := posts[i]
		# Toward the room: the average of the directions that lead into one.
		var inward := Vector3.ZERO
		for step in 8:
			var direction := Vector3.RIGHT.rotated(Vector3.UP, TAU * step / 8.0)
			var probe := post.position + direction * (wall_thickness * 0.5 + OUT_PROBE)
			if _room_at(probe.x, probe.z) >= 0:
				inward += direction
		if inward.length() < 0.01:
			continue
		var span := _height_span(Vector2(post.position.x, post.position.z))
		var light := OmniLight3D.new()
		light.name = "%s_%d" % [TORCH_PREFIX, number]
		number += 1
		light.light_color = torch_color
		light.shadow_enabled = false
		light.position = Vector3(post.position.x, span.y - TORCH_BELOW_TOP, post.position.z) \
			+ inward.normalized() * (wall_thickness * 0.5 + TORCH_OFF_POST)
		holder.add_child(light)
	return holder


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
	return Vector2(room_centres[room].y - room_halves[room].y, room_centres[room].y + room_halves[room].y - ceiling_drop)


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
	var thick := wall_thickness
	# Solid stretches between the run's ends and the doors, each ending at a
	# post that flanks a door where there is room for one.
	var stretches: Array[Vector2] = []
	var cursor := start
	var part := 0
	for cut in cuts:
		var stretch_end := cut.x
		if cut.x - thick - cursor > -SNAP:
			stretch_end = cut.x - thick
			made.append(_piece(holder, "post_door_%d" % pieces.size(), _along(rect, stretch_end, cut.x, runs_along_z), span.x, span.y, true))
		stretches.append(Vector2(cursor, stretch_end))
		if span.y - cut.z > SNAP:
			# The piece over the door.
			made.append(_piece(holder, "%s_over_%d" % [label, part], _along(rect, cut.x, cut.y, runs_along_z), cut.z, span.y, false, true))
			part += 1
		cursor = cut.y
		if end - (cut.y + thick) > -SNAP:
			made.append(_piece(holder, "post_door_%d" % pieces.size(), _along(rect, cut.y, cut.y + thick, runs_along_z), span.x, span.y, true))
			cursor = cut.y + thick
	stretches.append(Vector2(cursor, end))
	for stretch in stretches:
		var length := stretch.y - stretch.x
		if length <= SNAP:
			continue
		# Where the posts go (each from its start to start + thick): over the
		# posts of `post_from` where it has any along this stretch, otherwise
		# every `post_spacing` or so, centre to centre, evened out.
		var starts: Array[float] = []
		for centre in _posts_below(rect, runs_along_z):
			var begins := centre - thick * 0.5
			if begins > stretch.x + SNAP and begins + thick < stretch.y - SNAP:
				starts.append(begins)
		starts.sort()
		# What is left between those (all of the stretch, when there are
		# none) is divided evenly wherever it is too long to go unposted.
		var edges: Array[float] = [stretch.x - thick]
		edges.append_array(starts)
		edges.append(stretch.y)
		var more: Array[float] = []
		for index in edges.size() - 1:
			var gap_from := edges[index] + thick
			var gap := edges[index + 1] - gap_from
			var bays := maxi(1, roundi((gap + thick) / maxf(post_spacing, thick * 2.0)))
			if bays < 2 or (not starts.is_empty() and gap < post_spacing * 1.5):
				continue
			var pitch := (gap + thick) / float(bays)
			for bay in bays - 1:
				more.append(gap_from + pitch * (bay + 1) - thick)
		starts.append_array(more)
		starts.sort()
		# One post to a place: two walls of the storey below, side by side,
		# each gave the same spot.
		var single: Array[float] = []
		for begins in starts:
			if single.is_empty() or begins - single[single.size() - 1] >= thick - SNAP:
				single.append(begins)
		starts = single
		var from := stretch.x
		for begins in starts:
			if begins - from > SNAP:
				part = _span_pieces(holder, label, part, rect, from, begins, runs_along_z, span, out, made)
			made.append(_piece(holder, "post_mid_%d" % pieces.size(), _along(rect, begins, begins + thick, runs_along_z), span.x, span.y, true))
			from = begins + thick
		if stretch.y - from > SNAP:
			part = _span_pieces(holder, label, part, rect, from, stretch.y, runs_along_z, span, out, made)
	for index in made:
		pieces[index]["out"] = out
	return made


var _window_turn := 0


# Whether the room a stretch of wall belongs to is one that takes windows.
func _room_takes_windows(rect: Rect2, from: float, to: float, runs_along_z: bool) -> bool:
	if window_rooms.is_empty():
		return true
	var middle := (from + to) * 0.5
	var across := (rect.position.x + rect.end.x) * 0.5 if runs_along_z else (rect.position.y + rect.end.y) * 0.5
	var room := _ring_at(across, middle) if runs_along_z else _ring_at(middle, across)
	return room >= 0 and window_rooms.has(room_names[room])


# One stretch of wall between two posts, with its windows cut out: the wall
# to either side of a window whole, and under and over it a piece each.
# Returns the next part number.
func _span_pieces(holder: Node3D, label: String, part: int, rect: Rect2, from: float, to: float,
		runs_along_z: bool, span: Vector2, out: Vector3, made: Array[int]) -> int:
	# [from, to, sill, top] along this stretch.
	var holes: Array = []
	if _has_window_marks:
		for box in window_boxes:
			var across := box.get_center().x if runs_along_z else box.get_center().z
			var low := rect.position.x if runs_along_z else rect.position.y
			var high := rect.end.x if runs_along_z else rect.end.y
			if across < low - 0.3 or across > high + 0.3:
				continue
			var starts := maxf(box.position.z if runs_along_z else box.position.x, from)
			var ends := minf(box.end.z if runs_along_z else box.end.x, to)
			if ends - starts > 0.1:
				holes.append([starts, ends, box.position.y, box.end.y])
	elif auto_windows and out != Vector3.ZERO and to - from >= auto_window_min and _room_takes_windows(rect, from, to, runs_along_z):
		_window_turn += 1
		var middle := (from + to) * 0.5
		if (_window_turn - 1) % maxi(auto_window_every, 1) != 0:
			middle = INF
		holes.append([middle - window_size.x * 0.5, middle + window_size.x * 0.5,
			span.x + window_sill, span.x + window_sill + window_size.y])
	holes = holes.filter(func(hole: Array) -> bool: return is_finite(float(hole[0])))
	holes.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var cursor := from
	for hole: Array in holes:
		var starts: float = hole[0]
		var ends: float = hole[1]
		var sill := clampf(float(hole[2]), span.x, span.y)
		var top := clampf(float(hole[3]), span.x, span.y)
		if starts - cursor > SNAP:
			made.append(_piece(holder, "%s_%d" % [label, part], _along(rect, cursor, starts, runs_along_z), span.x, span.y))
			part += 1
		if sill - span.x > SNAP:
			made.append(_piece(holder, "%s_wsill_%d" % [label, part], _along(rect, starts, ends, runs_along_z), span.x, sill))
			part += 1
		if span.y - top > SNAP:
			made.append(_piece(holder, "%s_wover_%d" % [label, part], _along(rect, starts, ends, runs_along_z), top, span.y))
			part += 1
		cursor = ends
	if to - cursor > SNAP:
		made.append(_piece(holder, "%s_%d" % [label, part], _along(rect, cursor, to, runs_along_z), span.x, span.y))
		part += 1
	return part


# Where the posts of `post_from` stand along a wall of this storey: their
# middles along the wall, for those that are on the wall's line.
func _posts_below(rect: Rect2, runs_along_z: bool) -> Array[float]:
	var out: Array[float] = []
	if post_from.is_empty():
		return out
	var other := get_node_or_null(post_from)
	var other_walls := other.get_node_or_null("walls") if other != null else null
	if other_walls == null:
		return out
	var to_here := global_transform.affine_inverse()
	for child in other_walls.get_children():
		var post := child as Node3D
		if post == null or not String(post.name).to_lower().begins_with(POST_PREFIX):
			continue
		var at := to_here * post.global_position
		var across := at.x if runs_along_z else at.z
		var low := rect.position.x if runs_along_z else rect.position.y
		var high := rect.end.x if runs_along_z else rect.end.y
		if across > low - post_match_reach and across < high + post_match_reach:
			out.append(at.z if runs_along_z else at.x)
	return out


static func _along(rect: Rect2, from: float, to: float, runs_along_z: bool) -> Rect2:
	if runs_along_z:
		return Rect2(rect.position.x, from, rect.size.x, to - from)
	return Rect2(from, rect.position.y, to - from, rect.size.y)


var _wall_material: StandardMaterial3D
var _post_material: StandardMaterial3D


static func _flat_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 1.0
	return material


func _piece(holder: Node3D, piece_name: String, rect: Rect2, bottom: float, top: float, is_post := false, beam := false) -> int:
	if _wall_material == null:
		_wall_material = _flat_material(wall_color)
		_post_material = _flat_material(post_color)
	if not is_post and wall_inset > 0.0:
		# Thinner than the posts, across whichever way it is thin.
		if rect.size.x <= rect.size.y and rect.size.x > wall_inset * 2.0 + 0.05:
			rect = Rect2(rect.position.x + wall_inset, rect.position.y, rect.size.x - wall_inset * 2.0, rect.size.y)
		elif rect.size.y < rect.size.x and rect.size.y > wall_inset * 2.0 + 0.05:
			rect = Rect2(rect.position.x, rect.position.y + wall_inset, rect.size.x, rect.size.y - wall_inset * 2.0)
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
	box_mesh.material = _post_material if (is_post or beam) else _wall_material
	mesh.mesh = box_mesh
	body.add_child(mesh)
	holder.add_child(body)
	pieces.append({"node": body, "meshes": [mesh], "post": is_post, "out": Vector3.ZERO, "walls": [] as Array[int]})
	return pieces.size() - 1


# ------------------------------------------------------------ the world's CSG

# ------------------------------------------------------------ asked by the view

# ------------------------------------------------------------ what belongs to which storey
#
# Everything under a storey's node is that storey's: its walls, its floor,
# its lights, a stair that starts on it. `members` adds what lives elsewhere
# in the scene (the ground floor's furniture). What is shown, what takes a
# click and which storey the body is on are all decided by this -- by what a
# thing belongs to, not by how high it is or which box it falls in.

# The storey a node belongs to, or null (the world outside any building).
static func storey_of(node: Node) -> BuildingInterior:
	var at := node
	while at != null:
		if at is BuildingInterior:
			return at as BuildingInterior
		var claimed: Variant = _member_of.get(at.get_instance_id())
		if claimed != null and is_instance_valid(claimed):
			return claimed as BuildingInterior
		at = at.get_parent()
	return null


# The height of this storey's floor, in the world.
func floor_level() -> float:
	var bottom := INF
	for i in room_centres.size():
		bottom = minf(bottom, room_centres[i].y - room_halves[i].y)
	if bottom == INF:
		bottom = 0.0
	return (global_transform * Vector3(0.0, bottom, 0.0)).y


# The storeys of this building (the nodes like this one beside it), lowest first.
func storeys() -> Array[BuildingInterior]:
	var out: Array[BuildingInterior] = []
	for sibling in get_parent().get_children():
		var storey := sibling as BuildingInterior
		if storey != null:
			out.append(storey)
	out.sort_custom(func(a: BuildingInterior, b: BuildingInterior) -> bool: return a.floor_level() < b.floor_level())
	return out


func lowest_storey() -> BuildingInterior:
	return storeys()[0]


# Whether this storey stands on the world's ground rather than on a floor
# of its own: the body is on it once it is wholly through the door.
func is_ground() -> bool:
	return floor_thickness <= 0.0


# Whether a body (its centre, radius and half height, in the world) is in:
# it goes in once the whole body is in a room -- past the wall the door is
# in -- and out once the whole body is clear of the walls. In a doorway it is
# what it was.
#
# This is one storey, so the body's feet have to be on it: from LEVEL_BELOW
# under the rooms' floor to LEVEL_UNDER_TOP short of their top. On a stair
# the feet leave this storey a step before the top, where the one above
# (whose floor is this one's top) has already taken them.
const LEVEL_BELOW := 0.3
const LEVEL_UNDER_TOP := 0.1


func update_inside(body_at: Vector3, radius: float, half_height: float) -> bool:
	var at := global_transform.affine_inverse() * body_at
	var feet := at.y - half_height
	var on_level := false
	for i in room_centres.size():
		if feet > room_centres[i].y - room_halves[i].y - LEVEL_BELOW \
				and feet < room_centres[i].y + room_halves[i].y - LEVEL_UNDER_TOP:
			on_level = true
	if not on_level:
		inside = false
		return false
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


# What each piece is, seen from a space with the camera at `to_camera`:
# 0 not drawn (it is not of that space), 1 drawn whole, 2 cut down (its far
# side is toward the camera). A post is of the space of the walls it
# touches, and is cut down only when every one of those is.
func piece_states(to_camera: Vector3, space: int) -> PackedInt32Array:
	var local := (global_transform.basis.inverse() * to_camera).normalized()
	var out := PackedInt32Array()
	out.resize(pieces.size())
	for i in pieces.size():
		if pieces[i]["post"]:
			continue
		var sides: Dictionary = pieces[i]["sides"]
		if not sides.has(space):
			out[i] = 0
			continue
		var outward: Vector3 = sides[space]
		out[i] = 2 if outward != Vector3.ZERO and outward.dot(local) > FACING else 1
	for i in pieces.size():
		if not pieces[i]["post"]:
			continue
		var of_space := 0
		var cut := 0
		for index: int in pieces[i]["walls"]:
			if out[index] != 0:
				of_space += 1
				if out[index] == 2:
					cut += 1
		out[i] = 0 if of_space == 0 else (2 if cut == of_space else 1)
	return out


# ------------------------------------------------------------ doors, from inside

# A light in each doorway and a strip of lit ground outside it: what is seen
# of the outside from in here. Made as the game starts, from the door boxes.
const DOOR_STRIP_LIFT := 0.02
const DOOR_STRIP_COLOR := Color(0.85, 0.83, 0.78)


func _make_door_marks() -> void:
	var material := _strip_material(DOOR_STRIP_COLOR)
	var inner := _strip_material(floor_color)
	for i in door_centres.size():
		var out := door_outs[i]
		if door_inside[i]:
			# Between two spaces: from each, a strip of the other's floor.
			for way: float in [1.0, -1.0]:
				var from_room := door_room_in[i] if way > 0.0 else door_room_out[i]
				if from_room < 0:
					continue
				_strips.append([_strip(i, out * way, inner, "InnerStrip%d_%s" % [i, "a" if way > 0.0 else "b"]), room_space[from_room]])
			continue
		var light := OmniLight3D.new()
		light.name = "DoorLight%d" % i
		light.omni_range = DOOR_LIGHT_RANGE
		light.shadow_enabled = false
		light.position = door_centres[i]
		light.visible = false
		add_child(light)
		var space := room_space[door_room_in[i]] if door_room_in[i] >= 0 else -1
		_door_lights.append([light, space])
		_strips.append([_strip(i, out, material, "DoorStrip%d" % i), space])


static func _strip_material(near: Color) -> StandardMaterial3D:
	var fade := Gradient.new()
	fade.set_color(0, near)
	fade.set_color(1, Color.BLACK)
	var texture := GradientTexture2D.new()
	texture.gradient = fade
	texture.fill_from = Vector2(0.5, 0.0)
	texture.fill_to = Vector2(0.5, 1.0)
	texture.width = 4
	texture.height = 64
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_texture = texture
	return material


# A plane one metre long from the far face of a door's wall, going `way`;
# stretched to the slider's length when shown. Its v runs away from the
# door: bright to black.
func _strip(door: int, way: Vector3, material: Material, strip_name: String) -> MeshInstance3D:
	var strip := MeshInstance3D.new()
	strip.name = strip_name
	var plane := PlaneMesh.new()
	plane.size = Vector2(door_halves[door].x * 2.0, 1.0)
	plane.center_offset = Vector3(0.0, 0.0, 0.5)
	plane.material = material
	strip.mesh = plane
	strip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	strip.transform = Transform3D(
		Basis(Vector3(way.z, 0.0, -way.x), Vector3.UP, way),
		door_centres[door] + way * (wall_thickness * 0.5) + Vector3(0.0, -door_halves[door].y + DOOR_STRIP_LIFT, 0.0))
	strip.visible = false
	add_child(strip)
	return strip


# ------------------------------------------------------------ asked by the view

# This storey's part of the picture while the body is in the building.
# `current`: the body is on this storey. Then it is one space of it that is
# drawn (`current_space`): that space's floor, the walls round it with the
# camera-side ones cut down, what stands in it, its lights, and a strip
# beyond each of its doors.
func apply_view(current: bool, to_camera: Vector3) -> void:
	if not current:
		for lamp in _lamps:
			lamp.visible = false
		return
	var floor_y := INF
	for i in room_centres.size():
		floor_y = minf(floor_y, room_centres[i].y - room_halves[i].y)
	var states := piece_states(to_camera, current_space)
	for i in pieces.size():
		_show_piece(pieces[i], states[i], floor_y)
	var floor_holder := get_node_or_null("floor")
	if floor_holder != null:
		for child in floor_holder.get_children():
			var part := child as Node3D
			var part_name := String(part.name)
			if part_name.begins_with("space_"):
				part.visible = part_name.trim_prefix("space_").to_int() == current_space
			elif part_name.begins_with("sill_"):
				part.visible = _door_touches(part_name.trim_prefix("sill_").to_int(), current_space)
	for thing: Array in _things:
		(thing[0] as Node3D).visible = int(thing[1]) == current_space
	for i in _lamps.size():
		var lamp := _lamps[i]
		var candle := String(lamp.name).begins_with(CANDLE_PREFIX)
		lamp.visible = _lamp_space[i] == current_space
		var energy: float = Tuning.values.interior_candle_energy if candle else Tuning.values.interior_torch_energy
		var reach: float = Tuning.values.interior_candle_range if candle else Tuning.values.interior_torch_range
		if String(lamp.name).begins_with(HEARTH_PREFIX):
			# The fire: the room's main light, off the torches' sliders.
			energy = Tuning.values.interior_torch_energy * HEARTH_ENERGY
			reach = Tuning.values.interior_torch_range * HEARTH_REACH
		lamp.light_energy = energy
		lamp.omni_range = reach
	for entry: Array in _door_lights:
		var light := entry[0] as OmniLight3D
		light.visible = int(entry[1]) == current_space and Tuning.values.interior_door_light > 0.0
		light.light_energy = Tuning.values.interior_door_light
	for entry: Array in _strips:
		var strip := entry[0] as MeshInstance3D
		strip.visible = int(entry[1]) == current_space
		strip.scale = Vector3(1.0, 1.0, maxf(Tuning.values.interior_door_glimpse, 0.01))


const STAIR_LAMP_REACH := 6.0
const HEARTH_PREFIX := "hearth"
const HEARTH_ENERGY := 2.5
const HEARTH_REACH := 2.0
const CUT_FACE := 0.03
const BELOW_LAMP_SHARE := 0.6


# One piece: not drawn (state 0), whole (1) or cut down (2). A piece that
# stands on the floor is left `stub_height` high when cut; one that does not
# (the piece over a door) goes.
func _show_piece(piece: Dictionary, state: int, floor_y: float) -> void:
	var cut := state == 2
	var meshes: Array = piece["meshes"]
	var rest: Array = piece["rest"]
	var box: AABB = piece["box"]
	var stub := cut and stub_height > 0.0 and box.position.y <= floor_y + 0.05 and box.size.y > stub_height
	# The cut face: a dark lid on what is left standing, so a wall that has
	# been cut down does not read as a low wall. Made the first time.
	var lid := piece.get("lid") as MeshInstance3D
	if stub and lid == null:
		lid = MeshInstance3D.new()
		lid.name = "CutFace"
		var face := BoxMesh.new()
		face.size = Vector3(box.size.x + 0.01, CUT_FACE, box.size.z + 0.01)
		face.material = _flat_material(cut_color)
		lid.mesh = face
		lid.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		lid.position = Vector3(0.0, -box.size.y * 0.5 + stub_height + CUT_FACE * 0.5, 0.0)
		(piece["node"] as Node3D).add_child(lid)
		piece["lid"] = lid
	if lid != null:
		lid.visible = stub
	for i in meshes.size():
		var mesh := meshes[i] as MeshInstance3D
		var stands: Transform3D = rest[i]
		if stub and i == 0:
			var share := stub_height / box.size.y
			mesh.transform = Transform3D(
				stands.basis.scaled(Vector3(1.0, share, 1.0)),
				stands.origin + Vector3(0.0, -(box.size.y - stub_height) * 0.5, 0.0))
			mesh.visible = true
		else:
			mesh.transform = stands
			mesh.visible = state == 1


# As it stands when nobody is looking from inside: every wall, floor and
# thing drawn, the lights and the door strips off.
func reset_view() -> void:
	for piece in pieces:
		_show_piece(piece, 1, 0.0)
	var floor_holder := get_node_or_null("floor")
	if floor_holder != null:
		for child in floor_holder.get_children():
			(child as Node3D).visible = true
	for thing: Array in _things:
		(thing[0] as Node3D).visible = true
	for lamp in _lamps:
		lamp.visible = false
	for entry: Array in _door_lights:
		(entry[0] as OmniLight3D).visible = false
	for entry: Array in _strips:
		(entry[0] as MeshInstance3D).visible = false
	inside = false
	current_space = -1


# update_inside without the memory: whether a body is wholly in right now.
# For bodies other than the local one.
func holds(body_at: Vector3, radius: float, half_height: float) -> bool:
	var at := global_transform.affine_inverse() * body_at
	var feet := at.y - half_height
	var on_level := false
	for i in room_centres.size():
		if feet > room_centres[i].y - room_halves[i].y - LEVEL_BELOW \
				and feet < room_centres[i].y + room_halves[i].y - LEVEL_UNDER_TOP:
			on_level = true
	if not on_level:
		return false
	for offset: Vector3 in [Vector3.ZERO, Vector3(radius, 0.0, 0.0), Vector3(-radius, 0.0, 0.0),
			Vector3(0.0, 0.0, radius), Vector3(0.0, 0.0, -radius)]:
		if not _in_a_room(at + offset, 0.0):
			return false
	return true


# Whether a point of the world's ground is this storey's floor, as far as a
# click goes: in a room of the space the body is in, at its floor, or in a
# doorway of that space. With `any_space`: in any of its rooms (where some
# other body stands, what a stair's landing is part of).
func over_floor(point: Vector3, any_space := false) -> bool:
	var only := -1 if any_space else current_space
	var at := global_transform.affine_inverse() * point
	for i in room_centres.size():
		if only >= 0 and room_space[i] != only:
			continue
		var q := at - room_centres[i]
		var h := room_halves[i]
		if absf(q.x) <= h.x and absf(q.z) <= h.z and absf(q.y + h.y) <= LEVEL_BELOW:
			return true
	for i in door_centres.size():
		if not door_inside[i] or (only >= 0 and not _door_touches(i, only)):
			continue
		var d := at - door_centres[i]
		var across := absf(d.z) if absf(door_outs[i].x) > 0.5 else absf(d.x)
		var through := absf(d.x) if absf(door_outs[i].x) > 0.5 else absf(d.z)
		if across <= door_halves[i].x and through <= wall_thickness and absf(d.y + door_halves[i].y) <= LEVEL_BELOW:
			return true
	return false


# Whether a point is on the strip beyond one of the doors of the space the
# body is in (the doorway itself included): outside a way out, or on the
# floor of the space a door between two spaces leads to. That is where a
# click lands to go through the door.
func on_door_strip(point: Vector3) -> bool:
	var at := global_transform.affine_inverse() * point
	for i in door_centres.size():
		for way: float in [1.0, -1.0]:
			var from_room := door_room_in[i] if way > 0.0 else door_room_out[i]
			if from_room < 0 or (current_space >= 0 and room_space[from_room] != current_space):
				continue
			var d := at - door_centres[i]
			var out := door_outs[i] * way
			var along := d.x * out.x + d.z * out.z
			var across := absf(d.x * -out.z + d.z * out.x)
			if across <= door_halves[i].x and along > -wall_thickness \
					and along < Tuning.values.interior_door_glimpse + wall_thickness \
					and absf(d.y + door_halves[i].y) <= LEVEL_BELOW:
				return true
	return false


# Whether a collider is this storey's floor.
func is_floor(collider: Node) -> bool:
	var floor_piece := get_node_or_null("floor")
	return floor_piece != null and (collider == floor_piece or floor_piece.is_ancestor_of(collider))


# Whether a click on this storey's floor lands: on the floor of the space
# the body is in, in one of that space's doorways, or on the strip beyond
# one of its doors.
func floor_takes_click(collider: Node, point: Vector3) -> bool:
	var floor_piece := get_node_or_null("floor")
	if floor_piece == null:
		return false
	var part := collider
	while part != null and part.get_parent() != floor_piece:
		part = part.get_parent()
	if part == null:
		return false
	var part_name := String(part.name)
	if part_name.begins_with("space_") and part_name.trim_prefix("space_").to_int() == current_space:
		return true
	if part_name.begins_with("sill_") and _door_touches(part_name.trim_prefix("sill_").to_int(), current_space):
		return true
	return on_door_strip(point)


