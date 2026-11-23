extends Node

# 2026-11-23 (the user, while away): the village's buildings made the way the
# pub is made -- a Building with storeys (BuildingInterior: room and door
# boxes, walls/posts/windows/floor made by its own "벽 다시 만들기"), stairs
# (BuildingStair "계단 만들기") and a gable roof -- in the place and to the
# size of the blockout boxes they replace. Colours and materials of what is
# kept (fields, roads, pedestals, garden walls) are redone; their places and
# sizes are not touched. Run headless; it rewrites maps/zone_5.tscn.
#
# It builds from the blockout boxes, so it is run on the map as it was
# before (a copy kept 2026-11-23); on the built map it would find nothing to
# replace. Afterwards the scene's uid line is put back (fix_header.py):
#   godot --headless --path . res://tools/village/build_village.tscn
#   python -I tools/village/fix_header.py

const MAP := "res://maps/zone_5.tscn"
const BuildingScript := preload("res://scripts/world/building.gd")
const InteriorScript := preload("res://scripts/world/building_interior.gd")
const StairScript := preload("res://scripts/world/building_stair.gd")

const WALL := 0.5
const STAIR_RUN_PER_RISE := 1.7333  # 30 degrees: run = rise / tan(30)
const ROOF_OVERHANG := 0.45
const ROOF_THICK := 0.18
const ROOF_PITCH := 0.62  # rise per half span
const HOUSE_STAIR := 2.2
const SMALL_WALL := 0.4
const HALL_STAIR := 2.4

var zone: Node3D
var village: Node3D
var made := 0
var removed := 0

# Palettes.
const PLASTER := Color("e4d9c6")
const TIMBER := Color("5a3a27")
const STONE := Color("8d877f")
const ROOF_BROWN := Color("5b4334")
const ROOF_SLATE := Color("46505c")
const ROOF_CLAY := Color("8f4c35")
const ROOF_DARK := Color("3a3331")


func _ready() -> void:
	await get_tree().process_frame
	var packed := load(MAP) as PackedScene
	zone = packed.instantiate() as Node3D
	# What the runtime _ready of the pub's storeys changes (its marks hidden)
	# is put back before saving.
	var shown := {}
	for node in zone.find_children("*", "Node3D", true, false):
		shown[zone.get_path_to(node)] = (node as Node3D).visible
	get_tree().root.add_child(zone)
	await get_tree().process_frame

	village = Node3D.new()
	village.name = "village"
	zone.add_child(village)
	village.owner = zone

	_houses()
	_big_house()
	_l_houses()
	_town_hall()
	_shop()
	_blacksmith()
	_school()
	_restyle()

	for path: NodePath in shown.keys():
		var node := zone.get_node_or_null(path) as Node3D
		if node != null:
			node.visible = shown[path]
	# The new buildings' lights were switched off by their storeys' own
	# runtime view (nobody inside); saved on, as the pub's are.
	for node in village.find_children("*", "Node3D", true, false):
		(node as Node3D).visible = true
	# The loaded resource itself, so the scene keeps its uid.
	var out := packed
	var err := out.pack(zone)
	if err != OK:
		print("VILLAGE_PACK_FAILED ", err)
		get_tree().quit(1)
		return
	var target := MAP
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--out="):
			target = argument.trim_prefix("--out=")
	err = ResourceSaver.save(out, target)
	print("VILLAGE_TARGET ", target)
	print("VILLAGE_SAVED err=%d buildings=%d removed=%d" % [err, made, removed])
	get_tree().quit(0 if err == OK else 1)


# ------------------------------------------------------------ helpers

func _own(node: Node) -> void:
	node.owner = zone
	for child in node.find_children("*", "", true, false):
		if child.owner == null:
			child.owner = zone


func _remove(path: String) -> void:
	var node := zone.get_node_or_null(path)
	if node == null:
		print("VILLAGE_MISSING ", path)
		return
	node.get_parent().remove_child(node)
	node.free()
	removed += 1


func _building(building_name: String, at: Vector3, yaw_deg: float) -> Node3D:
	var building := Node3D.new()
	building.name = building_name
	building.set_script(BuildingScript)
	building.position = at
	building.rotation.y = deg_to_rad(yaw_deg)
	village.add_child(building)
	building.owner = zone
	made += 1
	return building


func _box_mark(parent: Node3D, mark_name: String, centre: Vector3, size: Vector3) -> void:
	var mark := MeshInstance3D.new()
	mark.name = mark_name
	var box := BoxMesh.new()
	box.size = size
	mark.mesh = box
	mark.position = centre
	parent.add_child(mark)
	mark.owner = zone


# A storey: rooms [name, Rect2 (x, z interior), floor y, height], doors
# [name, centre, size].
func _storey(building: Node3D, storey_name: String, rooms: Array, doors: Array, look: Dictionary) -> Node3D:
	var storey := Node3D.new()
	storey.name = storey_name
	storey.set_script(InteriorScript)
	building.add_child(storey)
	storey.owner = zone
	for key in look.keys():
		storey.set(key, look[key])
	var room_holder := Node3D.new()
	room_holder.name = "rooms"
	storey.add_child(room_holder)
	room_holder.owner = zone
	for room: Array in rooms:
		var rect: Rect2 = room[1]
		var floor_y: float = room[2]
		var height: float = room[3]
		_box_mark(room_holder, room[0], Vector3(rect.get_center().x, floor_y + height * 0.5, rect.get_center().y),
			Vector3(rect.size.x, height, rect.size.y))
	var door_holder := Node3D.new()
	door_holder.name = "doors"
	storey.add_child(door_holder)
	door_holder.owner = zone
	for door: Array in doors:
		_box_mark(door_holder, door[0], door[1], door[2])
	return storey


func _stair(building: Node3D, stair_name: String, lower: Node3D, upper: Node3D, foot: Vector3, head: Vector3,
		width: float, landing_centre: Vector3, landing: Vector2) -> void:
	var stair := Node3D.new()
	stair.name = stair_name
	stair.set_script(StairScript)
	building.add_child(stair)
	stair.owner = zone
	stair.set("lower", stair.get_path_to(lower))
	stair.set("upper", stair.get_path_to(upper))
	stair.set("foot", foot)
	stair.set("head", head)
	stair.set("width", width)
	stair.set("landing_centre", landing_centre)
	stair.set("landing_size", landing)
	stair.set("color", Color("5e3628"))
	stair.set("step_color", Color("a8814f"))


# A stair going `rise` up along `axis` (+X/-X/+Z/-Z) from `foot`; the landing
# is the next `landing_len` along. Returns [head, landing centre, landing size].
func _stair_ends(foot: Vector3, axis: Vector3, rise: float, width: float, landing_len: float) -> Array:
	var run := rise * STAIR_RUN_PER_RISE
	var head := foot + axis * run + Vector3.UP * rise
	var landing_centre := head + axis * (landing_len * 0.5)
	var landing := Vector2(landing_len, width) if absf(axis.x) > 0.5 else Vector2(width, landing_len)
	return [head, landing_centre, landing]


func _material(colour: Color, rough := 1.0) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = rough
	return material


# A gable roof over the outer rect (x, z, in the building's space) whose
# walls stop at `base`: a solid gable (the wall's plaster) and two roof
# slabs that overhang it. The ridge runs along the longer side.
func _roof(building: Node3D, roof_name: String, outer: Rect2, base: float, roof_colour: Color, gable_colour: Color) -> void:
	var along_x := outer.size.x >= outer.size.y
	var axis := Vector3.RIGHT if along_x else Vector3.BACK
	var length := outer.size.x if along_x else outer.size.y
	var half_span := (outer.size.y if along_x else outer.size.x) * 0.5
	var rise := half_span * ROOF_PITCH
	var centre := Vector3(outer.get_center().x, base, outer.get_center().y)
	var cross := Vector3.UP.cross(axis)

	var gable := CSGPolygon3D.new()
	gable.name = roof_name + "_gable"
	gable.polygon = PackedVector2Array([Vector2(-half_span, 0.0), Vector2(half_span, 0.0), Vector2(0.0, rise)])
	gable.depth = length
	gable.transform = Transform3D(Basis(cross, Vector3.UP, axis), centre + axis * (length * 0.5))
	gable.material = _material(gable_colour)
	gable.use_collision = true
	building.add_child(gable)
	gable.owner = zone

	var angle := atan2(rise, half_span)
	var slope := sqrt(half_span * half_span + rise * rise)
	var slab_len := slope + ROOF_OVERHANG
	for side: float in [1.0, -1.0]:
		var out_dir := cross * side
		# From the eave up to the ridge, and the slab's outward normal.
		var up_slope := (-out_dir * cos(angle) + Vector3.UP * sin(angle)).normalized()
		var normal := (out_dir * sin(angle) + Vector3.UP * cos(angle)).normalized()
		var eave := centre + out_dir * half_span
		var middle := eave + up_slope * (slope * 0.5) - up_slope * (ROOF_OVERHANG * 0.5) + normal * (ROOF_THICK * 0.5)
		var z_axis := axis
		if up_slope.cross(normal).dot(axis) < 0.0:
			z_axis = -axis
		var slab := CSGBox3D.new()
		slab.name = "%s_%s" % [roof_name, "a" if side > 0.0 else "b"]
		slab.size = Vector3(slab_len + 0.05, ROOF_THICK, length + ROOF_OVERHANG * 2.0)
		slab.transform = Transform3D(Basis(up_slope, normal, z_axis), middle)
		slab.material = _material(roof_colour)
		slab.use_collision = true
		building.add_child(slab)
		slab.owner = zone


func _look(wall: Color, post: Color, trim: Color, extra := {}) -> Dictionary:
	var out := {"wall_color": wall, "post_color": post, "trim_color": trim, "floor_color": Color("7d5b43"),
		"wall_thickness": WALL}
	out.merge(extra, true)
	return out


func _build(building: Node3D) -> void:
	for child in building.get_children():
		if child.get_script() == InteriorScript:
			child.call("rebuild_walls")
	for child in building.get_children():
		if child.get_script() == StairScript:
			child.call("build")


# ------------------------------------------------------------ the houses

# Two-storey 8 x 8 houses (and house8, one storey). `door_side`: the outer
# face the road comes to, "e" (+x) or "s" (-z); `door_at` along that face.
const HOUSES := [
	["building_SE/house1", "house_se1", Vector3(-10, 0, -36), "e", 0.5, 2, ROOF_BROWN],
	["building_SE/house2", "house_se2", Vector3(-16, 0, -50), "e", 1.5, 2, ROOF_CLAY],
	["building_SE/house3", "house_se3", Vector3(-10, 0, -65), "e", 0.5, 2, ROOF_SLATE],
	["building_SE/house4", "house_se4", Vector3(-16, 0, -79), "e", 1.5, 2, ROOF_BROWN],
	["building_NE/house5", "house_ne5", Vector3(-36.5, 0, 10), "s", 0.5, 2, ROOF_CLAY],
	["building_NE/house6", "house_ne6", Vector3(-50.5, 0, 16), "s", 1.5, 2, ROOF_SLATE],
	["building_NE/house7", "house_ne7", Vector3(-95.5, 0, 10), "s", 0.5, 2, ROOF_BROWN],
	["building_NE/house8", "house_ne8", Vector3(-109.5, 0, 16), "s", 1.5, 1, ROOF_CLAY],
]


func _houses() -> void:
	for row: Array in HOUSES:
		var group: String = row[0]
		var storeys: int = row[5]
		for box_name in ["house", "house2", "house3"]:
			if zone.get_node_or_null(group + "/" + box_name) != null:
				_remove(group + "/" + box_name)
		var building := _building(row[1], row[2], 0.0)
		# Walls 0.4 (the outside stays 8 x 8): 7.2 inside takes the stair
		# with a metre clear before its foot and beyond its head.
		var inner := Rect2(-3.6, -3.6, 7.2, 7.2)
		var door: Array
		if row[3] == "e":
			door = ["front", Vector3(3.8, 1.75, row[4]), Vector3(SMALL_WALL, 2.5, 1.6)]
		else:
			door = ["front", Vector3(row[4], 1.75, -3.8), Vector3(1.6, 2.5, SMALL_WALL)]
		var look := _look(PLASTER, TIMBER, STONE, {"ceiling_drop": 0.3 if storeys > 1 else 0.0,
			"torch_every": 3, "post_spacing": 3.6, "trim_height": 0.4, "wall_thickness": SMALL_WALL})
		var s1 := _storey(building, "storey_1", [["room", inner, 0.5, 3.0]], [door], look)
		var top := 3.5
		if storeys > 1:
			var look2 := _look(PLASTER, TIMBER, TIMBER, {"post_from": NodePath("../storey_1"), "floor_thickness": 0.3,
				"torch_every": 3, "post_spacing": 3.6, "wall_thickness": SMALL_WALL})
			var s2 := _storey(building, "storey_2", [["room", inner, 3.5, 3.0]], [], look2)
			# The stair along the wall away from the door.
			var foot: Vector3
			var axis: Vector3
			# (2.2 m wide: at 1.4 the navigation map's body radius took both
			# edges off the ramp and the way up was cut, measured 11-23.)
			if row[3] == "e":
				foot = Vector3(-2.35, 0.5, -2.6)
				axis = Vector3.BACK
			else:
				foot = Vector3(-2.6, 0.5, 2.35)
				axis = Vector3.RIGHT
			var ends := _stair_ends(foot, axis, 3.0, HOUSE_STAIR, 1.0)
			_stair(building, "stair_1", s1, s2, foot, ends[0], HOUSE_STAIR, ends[1], ends[2])
			top = 6.5
		_roof(building, "roof", Rect2(-4.0, -4.0, 8.0, 8.0), top, row[6], PLASTER)
		_build(building)


func _big_house() -> void:
	var group := "building_NE/big house"
	for box_name in ["house", "house2", "house3"]:
		_remove(group + "/" + box_name)
	var building := _building("big_house", Vector3(-74.5, 0, 16), 0.0)
	var inner := Rect2(-9.5, -3.5, 19.0, 7.0)
	var door := ["front", Vector3(0.0, 1.75, -3.75), Vector3(2.0, 2.5, WALL)]
	var s1 := _storey(building, "storey_1", [["hall", inner, 0.5, 3.0]], [door],
		_look(PLASTER, TIMBER, STONE, {"ceiling_drop": 0.3, "trim_height": 0.4}))
	var s2 := _storey(building, "storey_2", [["hall", inner, 3.5, 3.0]], [],
		_look(PLASTER, TIMBER, TIMBER, {"ceiling_drop": 0.3, "post_from": NodePath("../storey_1"), "floor_thickness": 0.3}))
	var s3 := _storey(building, "storey_3", [["hall", inner, 6.5, 3.0]], [],
		_look(PLASTER, TIMBER, TIMBER, {"post_from": NodePath("../storey_2"), "floor_thickness": 0.3}))
	# Each stair's head two metres short of an end wall (the arrangement the
	# small houses pass the building check with); the first goes up east along
	# the north wall, the second west along the south wall.
	var foot1 := Vector3(2.3, 0.5, 2.3)
	var e1 := _stair_ends(foot1, Vector3.RIGHT, 3.0, HOUSE_STAIR, 1.6)
	_stair(building, "stair_1", s1, s2, foot1, e1[0], HOUSE_STAIR, e1[1], e1[2])
	var foot2 := Vector3(-2.3, 3.5, -2.3)
	var e2 := _stair_ends(foot2, Vector3.LEFT, 3.0, HOUSE_STAIR, 1.6)
	_stair(building, "stair_2", s2, s3, foot2, e2[0], HOUSE_STAIR, e2[1], e2[2])
	_roof(building, "roof", Rect2(-10.0, -4.0, 20.0, 8.0), 9.5, ROOF_SLATE, PLASTER)
	_build(building)


# The two houses on the south floor: a two-storey main house and a
# one-storey annex beside it, a wall and a door between them.
func _l_houses() -> void:
	# house5: main 8 x 10 at (35, -37), annex 5 x 8 at (41.5, -36); the road
	# comes to the main house's south face.
	_remove("floor_S/house5/house")
	_remove("floor_S/house5/house3")
	_remove("floor_S/house5/house2")
	var b5 := _building("house_s5", Vector3(35, 0, -37), 0.0)
	_l_house(b5, Rect2(4.0, -2.6, 4.6, 7.2), Vector3(3.8, 1.75, 1.0), Vector3(-0.5, 1.75, -4.8), Vector3(1.6, 2.5, SMALL_WALL),
		Vector3(-2.35, 0.5, -3.1), Vector3.BACK, Rect2(4.0, -3.0, 5.0, 8.0), ROOF_CLAY)
	# house6: main at (35, -81), annex 5 x 4 at (41.5, -84); the road comes to
	# the main house's north face.
	_remove("floor_S/house6/house")
	_remove("floor_S/house6/house3")
	_remove("floor_S/house6/house2")
	var b6 := _building("house_s6", Vector3(35, 0, -81), 0.0)
	_l_house(b6, Rect2(4.0, -4.6, 4.6, 3.2), Vector3(3.8, 1.75, -3.0), Vector3(-0.5, 1.75, 4.8), Vector3(1.6, 2.5, SMALL_WALL),
		Vector3(-2.35, 0.5, 3.1), Vector3.FORWARD, Rect2(4.0, -5.0, 5.0, 4.0), ROOF_BROWN)


func _l_house(building: Node3D, annex: Rect2, inner_door: Vector3, front_door: Vector3, front_size: Vector3,
		stair_foot: Vector3, stair_axis: Vector3, annex_outer: Rect2, roof_colour: Color) -> void:
	var main := Rect2(-3.6, -4.6, 7.2, 9.2)
	var s1 := _storey(building, "storey_1", [["main", main, 0.5, 3.0], ["annex", annex, 0.5, 3.0]],
		[["front", front_door, front_size], ["annex", inner_door, Vector3(SMALL_WALL, 2.5, 1.4)]],
		_look(PLASTER, TIMBER, STONE, {"ceiling_drop": 0.3, "trim_height": 0.4, "post_spacing": 3.6, "wall_thickness": SMALL_WALL}))
	var s2 := _storey(building, "storey_2", [["main", main, 3.5, 3.0]], [],
		_look(PLASTER, TIMBER, TIMBER, {"post_from": NodePath("../storey_1"), "floor_thickness": 0.3, "post_spacing": 3.6,
			"wall_thickness": SMALL_WALL}))
	var ends := _stair_ends(stair_foot, stair_axis, 3.0, HOUSE_STAIR, 1.6)
	_stair(building, "stair_1", s1, s2, stair_foot, ends[0], HOUSE_STAIR, ends[1], ends[2])
	_roof(building, "roof", Rect2(-4.0, -5.0, 8.0, 10.0), 6.5, roof_colour, PLASTER)
	_roof(building, "roof_annex", annex_outer, 3.2, roof_colour, PLASTER)
	_build(building)


# ------------------------------------------------------------ the centre

func _town_hall() -> void:
	var group := "building_center/town hall"
	_remove(group + "/floor1")
	_remove(group + "/floor2")
	_remove(group + "/front door")
	var building := _building("town_hall", Vector3(-20.41, 0, 20.41), -45.0)
	var inner := Rect2(-8.5, -6.0, 17.0, 12.0)
	var stone_wall := Color("cfc6b5")
	var s1 := _storey(building, "storey_1", [["hall", inner, 2.0, 5.0]],
		[["front", Vector3(0.0, 3.25, -6.25), Vector3(3.5, 2.5, WALL)]],
		_look(stone_wall, Color("4a3426"), Color("75706a"), {"ceiling_drop": 0.3, "trim_height": 0.6,
			"window_size": Vector2(1.4, 2.0), "window_sill": 1.4, "post_spacing": 4.25}))
	var s2 := _storey(building, "storey_2", [["hall", inner, 7.0, 5.0]], [],
		_look(stone_wall, Color("4a3426"), Color("4a3426"), {"post_from": NodePath("../storey_1"), "floor_thickness": 0.3,
			"window_size": Vector2(1.4, 2.0), "window_sill": 1.4, "post_spacing": 4.25}))
	var foot := Vector3(-7.0, 2.0, 4.6)
	var ends := _stair_ends(foot, Vector3.RIGHT, 5.0, HALL_STAIR, 1.8)
	_stair(building, "stair_1", s1, s2, foot, ends[0], HALL_STAIR, ends[1], ends[2])
	_roof(building, "roof", Rect2(-9.0, -6.5, 18.0, 13.0), 12.0, ROOF_SLATE, stone_wall)
	_build(building)


func _shop() -> void:
	_remove("building_center/shop/display")
	_remove("building_center/shop/front door")
	var building := _building("shop", Vector3(23.5, 0, -0.5), -90.0)
	var walls := Color("ead9b0")
	_storey(building, "storey_1", [["shop", Rect2(-7.0, -5.0, 14.0, 10.0), 0.5, 5.0]],
		[["front", Vector3(-3.5, 1.75, 5.25), Vector3(2.0, 2.5, WALL)]],
		_look(walls, TIMBER, STONE, {"trim_height": 0.4, "window_size": Vector2(1.6, 1.6), "post_spacing": 3.75}))
	_roof(building, "roof", Rect2(-7.5, -5.5, 15.0, 11.0), 5.5, ROOF_CLAY, walls)
	_build(building)


func _blacksmith() -> void:
	_remove("building_center/blacksmith/display")
	_remove("building_center/blacksmith/fire")
	_remove("building_center/blacksmith/front door")
	var building := _building("blacksmith", Vector3(-14, 0, -22), 90.0)
	var walls := Color("a8a196")
	_storey(building, "storey_1",
		[["display", Rect2(-3.5, -3.75, 7.0, 7.25), 0.5, 5.0], ["forge", Rect2(-11.5, -11.5, 15.0, 7.25), 0.5, 5.0]],
		[["front", Vector3(-2.0, 1.75, 3.75), Vector3(2.0, 2.5, WALL)], ["forge", Vector3(0.0, 1.75, -4.0), Vector3(2.0, 2.5, WALL)]],
		_look(walls, Color("3b2a20"), Color("6d6862"), {"trim_height": 0.6, "post_spacing": 4.0}))
	_roof(building, "roof", Rect2(-4.0, -4.0, 8.0, 8.0), 5.5, ROOF_DARK, walls)
	_roof(building, "roof_forge", Rect2(-12.0, -12.0, 16.0, 8.0), 5.5, ROOF_DARK, walls)
	_build(building)


# ------------------------------------------------------------ the school

func _school() -> void:
	var group := "building_NW/training school"
	_remove(group + "/main school/floor1")
	_remove(group + "/main school/floor2")
	_remove(group + "/main school/floor3")
	_remove(group + "/dormitory")
	_remove(group + "/dormitory2")
	var walls := Color("ddd5c4")
	var post := Color("4b3527")
	var building := _building("training_school", Vector3(0, 0, 103), 0.0)
	var storeys: Array[Node3D] = []
	for level in 3:
		var floor_y := 2.5 + 3.0 * level
		var rooms := [
			["hall", Rect2(-7.5, -7.5, 15.0, 15.0), floor_y, 3.0],
			["room1", Rect2(-17.5, -7.5, 9.5, 7.25), floor_y, 3.0],
			["room2", Rect2(-17.5, 0.25, 9.5, 7.25), floor_y, 3.0],
			["room3", Rect2(8.0, -7.5, 9.5, 7.25), floor_y, 3.0],
			["room4", Rect2(8.0, 0.25, 9.5, 7.25), floor_y, 3.0],
		]
		var door_y := floor_y + 1.25
		var doors := [
			["room1", Vector3(-7.75, door_y, -3.9), Vector3(WALL, 2.5, 1.4)],
			["room2", Vector3(-7.75, door_y, 3.9), Vector3(WALL, 2.5, 1.4)],
			["room3", Vector3(7.75, door_y, -3.9), Vector3(WALL, 2.5, 1.4)],
			["room4", Vector3(7.75, door_y, 3.9), Vector3(WALL, 2.5, 1.4)],
		]
		if level == 0:
			doors.append(["front", Vector3(0.0, door_y, -7.75), Vector3(3.0, 2.5, WALL)])
		var extra := {"ceiling_drop": 0.3 if level < 2 else 0.0, "post_spacing": 4.0}
		if level == 0:
			extra["trim_height"] = 0.5
		else:
			extra["post_from"] = NodePath("../storey_%d" % level)
			extra["floor_thickness"] = 0.3
		storeys.append(_storey(building, "storey_%d" % (level + 1), rooms, doors,
			_look(walls, post, STONE if level == 0 else post, extra)))
	var foot1 := Vector3(-5.6, 2.5, 6.0)
	var e1 := _stair_ends(foot1, Vector3.RIGHT, 3.0, HALL_STAIR, 1.6)
	_stair(building, "stair_1", storeys[0], storeys[1], foot1, e1[0], HALL_STAIR, e1[1], e1[2])
	var foot2 := Vector3(5.6, 5.5, -6.0)
	var e2 := _stair_ends(foot2, Vector3.LEFT, 3.0, HALL_STAIR, 1.6)
	_stair(building, "stair_2", storeys[1], storeys[2], foot2, e2[0], HALL_STAIR, e2[1], e2[2])
	_roof(building, "roof", Rect2(-18.0, -8.0, 36.0, 16.0), 11.5, ROOF_SLATE, walls)
	_build(building)
	# The dormitories, 12 x 30, three rooms each along their length, the way
	# in from the yard's side.
	for row: Array in [["dormitory_e", Vector3(24, 0, 58.5), -5.75], ["dormitory_w", Vector3(-24, 0, 58.5), 5.75]]:
		var dorm := _building(row[0], row[1], 0.0)
		var face_x: float = row[2]
		var rooms := [
			["room_s", Rect2(-5.5, -14.5, 11.0, 9.25), 0.5, 3.0],
			["room_m", Rect2(-5.5, -4.75, 11.0, 9.5), 0.5, 3.0],
			["room_n", Rect2(-5.5, 5.25, 11.0, 9.25), 0.5, 3.0],
		]
		var doors := [
			["front", Vector3(face_x, 1.75, 0.0), Vector3(WALL, 2.5, 1.8)],
			["south", Vector3(0.0, 1.75, -5.0), Vector3(1.6, 2.5, WALL)],
			["north", Vector3(0.0, 1.75, 5.0), Vector3(1.6, 2.5, WALL)],
		]
		_storey(dorm, "storey_1", rooms, doors, _look(walls, post, STONE, {"trim_height": 0.4, "post_spacing": 3.6}))
		_roof(dorm, "roof", Rect2(-6.0, -15.0, 12.0, 30.0), 3.5, ROOF_SLATE, walls)
		_build(dorm)


# ------------------------------------------------------------ what is kept

# Fields, roads, pedestals, garden walls and gates: their place and size as
# they are; a new look. Fields get crop rows on top (drawn only: a row a
# body walks over is not a lip to stop at).
func _restyle() -> void:
	var soil := _material(Color("6b4f34"))
	var crop := _material(Color("6c8a3a"))
	var crop_dry := _material(Color("a39243"))
	var road := _material(Color("8b7452"))
	var stone := _material(Color("a39b8e"))
	var wall_stone := _material(Color("8c867e"))
	var gate := _material(Color("6b4a33"))
	var count := 0
	for node in zone.find_children("*", "CSGBox3D", true, false):
		var box := node as CSGBox3D
		var path := String(zone.get_path_to(box))
		# Only the village's own lots, not the zone's big floors and fields.
		if not (path.begins_with("building_") or path.begins_with("floor_S/house")):
			continue
		var label := String(box.name)
		if label.begins_with("field") or label.begins_with("farm"):
			box.material = soil
			_rows(box, crop if count % 3 != 2 else crop_dry)
			count += 1
		elif label.begins_with("route") or label.contains("road"):
			box.material = road
		elif label.begins_with("pedestal") or label == "ramp":
			box.material = stone
		elif label.begins_with("wall") and box.operation == CSGShape3D.OPERATION_UNION:
			box.material = wall_stone
		elif path.contains("front door") and label.begins_with("door"):
			box.material = gate
	print("VILLAGE_RESTYLED fields=%d" % count)


# Crop rows on a field: thin strips along its longer side, 1.2 m apart.
func _rows(field: CSGBox3D, material: Material) -> void:
	var size := field.size
	var along_x := size.x >= size.z
	var across := size.z if along_x else size.x
	var length := (size.x if along_x else size.z) - 1.0
	var count := int(floor((across - 1.0) / 1.2))
	if count < 1 or length <= 0.5:
		return
	var holder := Node3D.new()
	holder.name = "crops"
	field.add_child(holder)
	holder.owner = zone
	var mesh := BoxMesh.new()
	mesh.size = Vector3(length, 0.16, 0.45) if along_x else Vector3(0.45, 0.16, length)
	mesh.material = material
	var first := -(count - 1) * 0.6
	for i in count:
		var row := MeshInstance3D.new()
		row.name = "row_%d" % i
		row.mesh = mesh
		var offset := first + 1.2 * i
		row.position = Vector3(0.0, size.y * 0.5 + 0.08, offset) if along_x else Vector3(offset, size.y * 0.5 + 0.08, 0.0)
		row.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(row)
		row.owner = zone
