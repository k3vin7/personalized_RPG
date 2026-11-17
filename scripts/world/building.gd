class_name Building
extends Node3D

# 건물 진입: a building of storeys (BuildingInterior) and stairs
# (BuildingStair). Its only job is to check itself once the game has a map
# of where a body can walk: that every stair can be walked from its foot to
# its head, and that every storey above or below the ground has a stair.
#
# A stair whose opening is too short, or whose foot is boxed in, looks right
# and cannot be climbed; this is what says so. The answer is printed
# (BUILDING_CHECK ...) and each problem is also raised as a warning, which
# the editor's debugger lists.

const REACH_FLAT := 0.75
const REACH_HEIGHT := 1.0
# Frames to wait after the navigation map first has something in it.
const SETTLE_FRAMES := 30
# The map is ready when it has ground this close to the foot of one of the
# building's stairs; and after this many frames the check runs regardless.
const READY_WITHIN := 1.5
const GIVE_UP_FRAMES := 3600
# How far outside a door the walk to every stair is measured from.
const DOOR_STAND_OFF := 1.5

var problems: Array[String] = []
var checked := false

var _waited := 0
var _asked := 0


# Somewhere in the building a body can certainly stand: the foot of a stair
# (or, with no stairs, the building's own place).
func _a_stair_foot() -> Vector3:
	for child in get_children():
		var stair := child as BuildingStair
		if stair != null:
			return stair.global_transform * stair.foot
	return global_position


func _process(_delta: float) -> void:
	if checked:
		set_process(false)
		return
	# The map counts as ready once it has ground inside this building: before
	# the bake lands it answers every question with nothing (or with ground
	# far away), and every stair would be reported shut.
	var map := get_world_3d().navigation_map
	if NavigationServer3D.map_get_iteration_id(map) == 0:
		return
	_asked += 1
	var probe := _a_stair_foot()
	var near := NavigationServer3D.map_get_closest_point(map, probe)
	if near.distance_to(probe) > READY_WITHIN and _asked < GIVE_UP_FRAMES:
		_waited = 0
		return
	_waited += 1
	if _waited < SETTLE_FRAMES:
		return
	check()


func check() -> void:
	checked = true
	problems.clear()
	var map := get_world_3d().navigation_map
	var storeys: Array[BuildingInterior] = []
	var stairs: Array[BuildingStair] = []
	for child in get_children():
		if child is BuildingInterior:
			storeys.append(child as BuildingInterior)
		elif child is BuildingStair:
			stairs.append(child as BuildingStair)
	var joined := {}
	for stair in stairs:
		var down := stair.lower_storey()
		var up := stair.upper_storey()
		if down == null or up == null:
			problems.append("계단 %s: 아래층/위층이 지정되지 않음" % stair.name)
			continue
		joined[down] = true
		joined[up] = true
		var from := stair.global_transform * stair.foot
		var to := stair.global_transform * stair.head
		var path := NavigationServer3D.map_get_path(map, from, to, true)
		var reached := false
		if not path.is_empty():
			var end := path[path.size() - 1]
			reached = Vector2(end.x - to.x, end.z - to.z).length() <= REACH_FLAT and absf(end.y - to.y) <= REACH_HEIGHT
		if not reached:
			problems.append("계단 %s: 발치에서 꼭대기까지 길이 끊김 (머리 위 여유나 구멍 길이 확인)" % stair.name)
	for storey in storeys:
		if not storey.is_ground() and not joined.has(storey):
			problems.append("층 %s: 이어진 계단이 없음" % storey.name)
	# From outside the first door of a ground storey, every stair's head has
	# to be somewhere a body can walk to: a stair that can be climbed but not
	# got to is as shut as one that cannot be climbed.
	for storey in storeys:
		if not storey.is_ground() or storey.door_centres.is_empty():
			continue
		var outside := storey.global_transform * (storey.door_centres[0] + storey.door_outs[0] * DOOR_STAND_OFF)
		for stair in stairs:
			if stair.upper_storey() == null:
				continue
			var to := stair.global_transform * stair.head
			var path := NavigationServer3D.map_get_path(map, outside, to, true)
			var reached := false
			if not path.is_empty():
				var end := path[path.size() - 1]
				reached = Vector2(end.x - to.x, end.z - to.z).length() <= REACH_FLAT and absf(end.y - to.y) <= REACH_HEIGHT
			if not reached:
				problems.append("계단 %s: 문 밖에서 계단 꼭대기까지 걸어갈 길이 없음" % stair.name)
		break
	if problems.is_empty():
		print("BUILDING_CHECK %s ok storeys=%d stairs=%d" % [name, storeys.size(), stairs.size()])
	else:
		print("BUILDING_CHECK %s problems=%d" % [name, problems.size()])
		for problem in problems:
			print("BUILDING_CHECK %s: %s" % [name, problem])
			push_warning("건물 %s — %s" % [name, problem])
