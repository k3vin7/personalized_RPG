class_name VillageLayout
extends Resource

# V-1 (2026-11-07): the Finimes starting village, as numbers. Everything the
# village scene builds -- the plaza, the height zones, the roads and their
# stairs, the two gates, the building footprints, the cliff -- is read from
# here, so the map moves by editing this file and nothing in village.gd.
# The shape itself is height_at(): the terrain's height map is filled from
# it, the stairs are placed on it, and the checks compare Terrain3D against
# it on both peers.
#
# Frame: the plaza's centre is (0, 0); north is -z, east is +x; metres.
# Every position was read off the user's sketch of 2026-11-06 (plaza in the
# middle, tavern west, shop / smithy / trainer east, town hall south, houses
# and fields north-west with Malfrost's house at the top, training ground
# north-east, forest east, inn and its field south, the cliff along the
# west and south-west edge, gates north and south-east). All of it is
# provisional: nothing here is canon until the setting says so.

# ---------------------------------------------------------------- plaza
@export var plaza_radius: float = 10.0
@export var fountain_radius: float = 3.0
@export var plaza_height: float = 0.0
# The plaza sits a step below the streets: from the paving's edge the ground
# rises to the terrace over this distance (1.2 m over 1 m: a low wall, not
# a walkable slope), except where a road or a stair leaves the plaza.
@export var plaza_rim: float = 1.0

# ---------------------------------------------------------------- heights
# The built-up ring around the plaza (shops, tavern, smithy, town hall).
@export var terrace_height: float = 1.2
# The upper quarter: houses, fields, Malfrost's house, and the land north.
@export var upper_height: float = 3.0
@export var training_height: float = 2.5
@export var forest_height: float = 7.0
# How wide a zone's edge is: a short edge is a retaining wall (slides), a
# long one is a hill. 1 m (one height cell): a 1.2 m rise is then 50 deg or
# more, which the body cannot walk and the navigation mesh does not offer,
# so every level change goes by a stair. At 1.5 m the edges came out at
# 41 deg: offered as a path (the bake allowed 46) but not walkable (40),
# and bodies stood pushing against them (V-1, first run).
@export var zone_edge: float = 1.0
# The forest hill is a smoothstep: its steepest part is 1.5 x the average,
# so 7 m over 24 m peaks at 24 deg (14 m peaked at 37, at the walk limit).
@export var forest_edge: float = 24.0
@export var cliff_floor_height: float = -30.0
@export var cliff_edge: float = 2.0

# Zone polygons (x, z). The upper quarter runs out to the terrain's north
# edge so the north road sits on the same level all the way to the gate.
# Zones must touch or overlap: a strip left between two raised zones is a
# trench at the terrace level (1.2) with walls the body cannot climb, and
# the navigation mesh led a body down into one (V-1, third run). Where two
# overlap the higher wins (max), and the lower zone's own edge blends down.
@export var upper_polygon: PackedVector2Array = PackedVector2Array([
	Vector2(-36.0, -22.0), Vector2(-6.0, -22.0), Vector2(2.0, -30.0), Vector2(10.0, -38.0),
	Vector2(18.0, -46.0), Vector2(26.0, -49.0), Vector2(62.0, -49.0), Vector2(64.0, -130.0), Vector2(-30.0, -130.0),
])
@export var training_polygon: PackedVector2Array = PackedVector2Array([
	Vector2(21.0, -18.0), Vector2(34.0, -12.0), Vector2(58.0, -14.0), Vector2(60.0, -50.0), Vector2(16.0, -50.0),
])
# The forest hill's flat top; its foot is forest_edge west of this line
# (x = 50, just past the trainer's post at 43 -- the sketch's dark green).
@export var forest_polygon: PackedVector2Array = PackedVector2Array([
	Vector2(74.0, -56.0), Vector2(130.0, -60.0), Vector2(130.0, 50.0), Vector2(82.0, 48.0),
	Vector2(74.0, 20.0), Vector2(74.0, -20.0),
])
# The cliff: the village is on the east side of this line; beyond it the
# ground is gone (cliff_floor_height, under the kill plane).
@export var cliff_line: PackedVector2Array = PackedVector2Array([
	Vector2(-2.0, -130.0), Vector2(-2.0, -88.0), Vector2(-62.0, -3.0), Vector2(14.0, 92.0), Vector2(30.0, 130.0),
])

# ---------------------------------------------------------------- roads
# Each road: a polyline of (x, height, z) and a width. The ground inside the
# width is the road's own profile (linear between points); it blends into
# the terrain over road_blend outside. A segment whose height changes by
# more than stair_min_rise is a stair: the collision is the ramp the
# profile makes (walkable, under walk_slope_max_deg), the steps are drawn
# on it. Main roads 4.5 m, alleys 2.5-3 m (the work order's widths).
# 1.2 m: beside a stair the flank from the road up to the level above is
# then a wall (1.8 m over 1.2 m, 56 deg), not a 42 deg slope the mesh
# offered and the body could not climb.
@export var road_blend: float = 1.2
@export var stair_min_rise: float = 0.3
@export var stair_riser: float = 0.2
# A stair's ramp is this much wider than its road on each side, at the
# ramp's own height: the retaining wall beside it then stands a metre off
# the walking line, instead of under the capsule's shoulder (a 2.5 m alley
# ramp with the wall at its edge stopped the body dead, V-1 second run).
@export var stair_shoulder: float = 1.0
@export var roads: Array[Dictionary] = [
	{"name": "north_road", "width": 4.5, "points": PackedVector3Array([
		Vector3(0.0, 0.0, -9.0), Vector3(0.0, 1.2, -12.0), Vector3(5.0, 1.2, -20.0), Vector3(10.0, 1.2, -30.0),
		Vector3(13.5, 1.2, -36.0), Vector3(15.0, 3.0, -40.0), Vector3(20.0, 3.0, -52.0), Vector3(24.0, 3.0, -62.0),
		Vector3(28.0, 3.0, -78.0), Vector3(34.0, 3.0, -128.0)])},
	{"name": "southeast_road", "width": 4.5, "points": PackedVector3Array([
		Vector3(6.4, 0.0, 6.4), Vector3(8.5, 1.2, 8.5), Vector3(16.0, 1.2, 16.0), Vector3(26.0, 1.2, 28.0),
		Vector3(34.0, 1.2, 40.0), Vector3(45.0, 1.2, 46.0), Vector3(60.0, 1.2, 60.0), Vector3(90.0, 1.2, 90.0)])},
	{"name": "tavern_alley", "width": 3.0, "points": PackedVector3Array([
		Vector3(-9.0, 0.0, 0.0), Vector3(-12.0, 1.2, -1.0), Vector3(-20.0, 1.2, -6.0), Vector3(-28.0, 1.2, -8.0)])},
	{"name": "hall_alley", "width": 3.0, "points": PackedVector3Array([
		Vector3(0.0, 0.0, 9.0), Vector3(0.0, 1.2, 12.0), Vector3(-2.0, 1.2, 20.0), Vector3(0.0, 1.2, 30.0),
		Vector3(3.0, 1.2, 42.0), Vector3(3.0, 1.2, 48.0)])},
	{"name": "shop_alley", "width": 3.0, "points": PackedVector3Array([
		Vector3(9.0, 0.0, -1.0), Vector3(12.0, 1.2, -1.0), Vector3(20.0, 1.2, -4.0), Vector3(34.0, 1.2, -3.0),
		Vector3(44.0, 1.2, -6.0)])},
	{"name": "training_alley", "width": 2.5, "points": PackedVector3Array([
		Vector3(20.0, 1.2, -4.0), Vector3(26.0, 1.2, -12.0), Vector3(28.0, 1.2, -14.0), Vector3(30.0, 2.5, -16.5),
		Vector3(36.0, 2.5, -24.0), Vector3(40.0, 2.5, -30.0)])},
	{"name": "houses_alley", "width": 2.5, "points": PackedVector3Array([
		Vector3(-6.4, 0.0, -6.4), Vector3(-8.5, 1.2, -8.5), Vector3(-14.0, 1.2, -16.0), Vector3(-18.0, 1.2, -22.0),
		Vector3(-20.0, 3.0, -25.0), Vector3(-18.0, 3.0, -34.0), Vector3(-14.0, 3.0, -42.0), Vector3(-6.0, 3.0, -48.0),
		Vector3(4.0, 3.0, -50.0), Vector3(19.0, 3.0, -51.0)])},
	{"name": "malfrost_alley", "width": 2.5, "points": PackedVector3Array([
		Vector3(4.0, 3.0, -50.0), Vector3(6.0, 3.0, -58.0), Vector3(14.0, 3.0, -64.0), Vector3(18.0, 3.0, -70.0)])},
]

# ---------------------------------------------------------------- gates
# The two ways in, on the main roads. A guard post goes beside each later.
@export var gate_north: Vector2 = Vector2(24.0, -62.0)
@export var gate_southeast: Vector2 = Vector2(45.0, 46.0)

# ---------------------------------------------------------------- footprints
# Where buildings will stand: a box each, drawn and listed, nothing built.
# Sizes are guesses; the names are the sketch's.
@export var footprints: Array[Dictionary] = [
	{"name": "술집", "at": Vector2(-27.0, -14.0), "size": Vector2(10.0, 8.0), "yaw": 15.0},
	{"name": "상점", "at": Vector2(27.0, -3.0), "size": Vector2(8.0, 8.0), "yaw": 0.0},
	{"name": "대장간", "at": Vector2(25.0, 11.0), "size": Vector2(8.0, 8.0), "yaw": -20.0},
	{"name": "교관", "at": Vector2(43.0, -2.0), "size": Vector2(6.0, 6.0), "yaw": 0.0},
	{"name": "청사", "at": Vector2(0.0, 27.0), "size": Vector2(14.0, 10.0), "yaw": 0.0},
	{"name": "여관", "at": Vector2(3.0, 53.0), "size": Vector2(12.0, 10.0), "yaw": 25.0},
	{"name": "집1", "at": Vector2(1.0, -40.0), "size": Vector2(6.0, 6.0), "yaw": 0.0},
	{"name": "집2", "at": Vector2(-8.0, -57.0), "size": Vector2(6.0, 6.0), "yaw": 0.0},
	{"name": "집3", "at": Vector2(10.0, -54.0), "size": Vector2(6.0, 6.0), "yaw": 0.0},
	{"name": "집4", "at": Vector2(-18.0, -42.0), "size": Vector2(6.0, 6.0), "yaw": 0.0},
	{"name": "말프로스트의 집", "at": Vector2(18.0, -65.0), "size": Vector2(8.0, 8.0), "yaw": 0.0},
	{"name": "수련장", "at": Vector2(39.0, -28.0), "size": Vector2(16.0, 12.0), "yaw": -20.0},
	{"name": "밭 (상)", "at": Vector2(-6.0, -58.0), "size": Vector2(20.0, 12.0), "yaw": 0.0},
	{"name": "밭 (하)", "at": Vector2(-9.0, -44.0), "size": Vector2(16.0, 10.0), "yaw": 0.0},
	{"name": "여관 밭", "at": Vector2(25.0, 60.0), "size": Vector2(34.0, 30.0), "yaw": 25.0},
	{"name": "경비 초소 (북)", "at": Vector2(28.5, -62.0), "size": Vector2(3.0, 3.0), "yaw": 0.0},
	{"name": "경비 초소 (남동)", "at": Vector2(42.0, 49.0), "size": Vector2(3.0, 3.0), "yaw": 45.0},
]

# ---------------------------------------------------------------- session
# The village walks: the server's base move speed while this world runs
# (the playground keeps its 6 m/s). The walk clip's own pace is about
# 1.05 m/s, so at 2 m/s it plays at x1.9, under the x2 cap, feet planted.
@export var move_speed: float = 2.0
@export var spawn_points: PackedVector3Array = PackedVector3Array([
	Vector3(-2.0, 1.0, 2.0), Vector3(2.0, 1.0, 2.0), Vector3(-2.0, 1.0, -2.0), Vector3(2.0, 1.0, -2.0),
])

# ---------------------------------------------------------------- terrain extent
# 4 x 4 Terrain3D regions of 64 m: x, z in -128..128. The village itself
# spans about x -62..95, z -88..92.
@export var terrain_origin: Vector2 = Vector2(-128.0, -128.0)
@export var terrain_size: int = 256


# ================================================================== the shape

func height_at(x: float, z: float) -> float:
	var p := Vector2(x, z)
	var side := _cliff_side(p)
	if side <= 0.0:
		return cliff_floor_height
	var h := terrace_height
	if side < cliff_edge:
		h = lerpf(cliff_floor_height, terrace_height, side / cliff_edge)
	h = maxf(h, _zone(p, upper_polygon, upper_height, zone_edge))
	h = maxf(h, _zone(p, training_polygon, training_height, zone_edge))
	h = maxf(h, _zone(p, forest_polygon, forest_height, forest_edge))
	var r := p.length()
	if r < plaza_radius:
		h = plaza_height
	elif r < plaza_radius + plaza_rim:
		h = lerpf(plaza_height, h, smoothstep(0.0, 1.0, (r - plaza_radius) / plaza_rim))
	for road in roads:
		var hit := road_at(road, p)
		if hit["weight"] > 0.0:
			h = lerpf(h, float(hit["height"]), float(hit["weight"]))
	return h


# Signed distance to the cliff line: positive on the village side (east).
func _cliff_side(p: Vector2) -> float:
	var best := INF
	var sign_at := 1.0
	for index in cliff_line.size() - 1:
		var a := cliff_line[index]
		var b := cliff_line[index + 1]
		var closest := Geometry2D.get_closest_point_to_segment(p, a, b)
		var d := p.distance_to(closest)
		if d < best:
			best = d
			# The line runs north to south; east of it is the village.
			var along := b - a
			var cross := along.x * (p.y - a.y) - along.y * (p.x - a.x)
			# Going from a north point to a south point, a point to the
			# east has a negative cross product.
			sign_at = 1.0 if cross < 0.0 else -1.0
	return best * sign_at


# `height` inside the polygon, falling to 0 over `edge` outside it.
static func _zone(p: Vector2, polygon: PackedVector2Array, height: float, edge: float) -> float:
	if polygon.size() < 3:
		return 0.0
	if Geometry2D.is_point_in_polygon(p, polygon):
		return height
	var d := _distance_to_polygon(p, polygon)
	if d >= edge:
		return 0.0
	return height * (1.0 - smoothstep(0.0, 1.0, d / edge))


static func _distance_to_polygon(p: Vector2, polygon: PackedVector2Array) -> float:
	var best := INF
	for index in polygon.size():
		var a := polygon[index]
		var b := polygon[(index + 1) % polygon.size()]
		best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b)))
	return best


# Each road's bounds on the ground, grown by everything that can reach
# past its line (half width, shoulder, blend), so a cell far from a road
# skips it: 65,536 cells x 8 roads x every segment was most of a 10 s
# scene build (V-1).
var _road_bounds := {}


func _bounds_of(road: Dictionary) -> Rect2:
	var key: String = road["name"]
	if _road_bounds.has(key):
		return _road_bounds[key]
	var points: PackedVector3Array = road["points"]
	var rect := Rect2(Vector2(points[0].x, points[0].z), Vector2.ZERO)
	for p3 in points:
		rect = rect.expand(Vector2(p3.x, p3.z))
	rect = rect.grow(float(road["width"]) * 0.5 + stair_shoulder + road_blend + 0.5)
	_road_bounds[key] = rect
	return rect


# The road's profile height at the point nearest `p`, and how much of it
# applies: 1 inside the width, falling to 0 over road_blend outside.
func road_at(road: Dictionary, p: Vector2) -> Dictionary:
	if not _bounds_of(road).has_point(p):
		return {"height": 0.0, "weight": 0.0, "distance": INF}
	var points: PackedVector3Array = road["points"]
	var half := float(road["width"]) * 0.5
	var best := INF
	var best_height := 0.0
	for index in points.size() - 1:
		var a3 := points[index]
		var b3 := points[index + 1]
		var a := Vector2(a3.x, a3.z)
		var b := Vector2(b3.x, b3.z)
		var closest := Geometry2D.get_closest_point_to_segment(p, a, b)
		var d := p.distance_to(closest)
		# A stair segment counts as wider: the shoulder is taken off the
		# distance so the ramp's flat part reaches past the road's edge.
		if absf(b3.y - a3.y) >= stair_min_rise:
			d = maxf(d - stair_shoulder, 0.0)
		if d < best:
			best = d
			var length := a.distance_to(b)
			var t := 0.0 if length < 0.001 else a.distance_to(closest) / length
			best_height = lerpf(a3.y, b3.y, t)
	var weight := 0.0
	if best <= half:
		weight = 1.0
	elif best < half + road_blend:
		weight = 1.0 - smoothstep(0.0, 1.0, (best - half) / road_blend)
	return {"height": best_height, "weight": weight, "distance": best}


# The stair segments: every road segment that rises more than stair_min_rise.
func stairs() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for road in roads:
		var points: PackedVector3Array = road["points"]
		for index in points.size() - 1:
			var a := points[index]
			var b := points[index + 1]
			if absf(b.y - a.y) >= stair_min_rise:
				out.append({"road": road["name"], "from": a, "to": b, "width": float(road["width"])})
	return out


func road_named(name_text: String) -> Dictionary:
	for road in roads:
		if road["name"] == name_text:
			return road
	return {}


# A road's point by index, as a body centre on the ground.
func road_point(name_text: String, index: int, half_height: float) -> Vector3:
	var road := road_named(name_text)
	if road.is_empty():
		return Vector3.INF
	var points: PackedVector3Array = road["points"]
	var p := points[clampi(index, 0, points.size() - 1)]
	return Vector3(p.x, height_at(p.x, p.z) + half_height, p.z)


func is_in_terrain(x: float, z: float) -> bool:
	return x >= terrain_origin.x and x < terrain_origin.x + terrain_size \
		and z >= terrain_origin.y and z < terrain_origin.y + terrain_size
