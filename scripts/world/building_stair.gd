@tool
class_name BuildingStair
extends Node3D

# 건물 진입: a stair (or any way between two storeys of a building). It is
# not part of either storey: with its landing at the top it is its own zone
# between `lower` and `upper`. A body on the stair or on the landing sees the
# lower storey and the stair; one step off the landing and it is on the
# upper storey. The line is the landing's edge -- flat ground, in plain
# sight -- not some share of the way up the slope.
#
# Put one under the building's node, beside its storeys, and set:
#
#   lower, upper   the two storeys (BuildingInterior nodes) it joins;
#   foot, head     where it starts on the lower storey and ends on the upper
#                  one, in this node's space (the middle of each end);
#   landing_*      the landing at the head (see below).
#
# "계단 만들기" (build) then makes the rest from those:
#
#   - ramp: the stair itself, `width` wide -- a wedge filled down to the
#     lower floor when `filled`, a slab otherwise (for a stair over another
#     stair, which needs the space under it);
#   - the opening in the upper storey's floor: a box under that storey's
#     holes/, as long as the whole stair (anything shorter leaves too little
#     headroom at the foot and the path up is cut), and that storey's floor
#     and rails made again around it.
#
# The stair has to run along one of the storey's axes for the opening to fit
# it; one that runs askew gets the box that contains it.
#
# What a thing under this node belongs to is this stair (BuildingStair.of),
# which is how the view knows a body is on it and a click landed on it.

const SLAB_THICKNESS := 0.25
const LANDING_LIFT := 0.02

@export_tool_button("계단 만들기", "Reload") var build_button: Callable = build

@export var lower: NodePath
@export var upper: NodePath
@export var foot := Vector3.ZERO
@export var head := Vector3.ZERO
@export var width := 2.0
@export var filled := true
@export var color := Color("5e3628")
# The steps drawn on the stair: about this high each, in this colour. They
# are drawn only -- what a body walks on is the smooth ramp under them.
@export var step_height := 0.2
@export var step_color := Color("b08a5a")
# The landing: the patch of the upper storey's floor at the head of the
# stair, in this node's space (its middle at floor height, and how far it
# reaches along x and z). The stair and its landing are one zone: standing on
# either, the picture is the lower storey with the stair, and only stepping
# off the landing makes it the upper storey. Keep it clear of where people
# walk past -- crossing it flips the picture.
@export var landing_centre := Vector3.ZERO
@export var landing_size := Vector2(3.0, 3.0)
@export var landing_color := Color("8c6650")

var _landing_patch: MeshInstance3D


func _ready() -> void:
	if Engine.is_editor_hint() or landing_size.x <= 0.0 or landing_size.y <= 0.0:
		return
	# The landing as it is drawn while the storey it is part of is not.
	_landing_patch = MeshInstance3D.new()
	_landing_patch.name = "LandingPatch"
	var plane := PlaneMesh.new()
	plane.size = landing_size
	var material := StandardMaterial3D.new()
	material.albedo_color = landing_color
	material.roughness = 1.0
	plane.material = material
	_landing_patch.mesh = plane
	_landing_patch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_landing_patch.position = landing_centre + Vector3(0.0, LANDING_LIFT, 0.0)
	_landing_patch.visible = false
	add_child(_landing_patch)


func show_landing(shown: bool) -> void:
	if _landing_patch != null:
		_landing_patch.visible = shown


# Whether a point of the world is over the landing (its height is not asked:
# what the body stands on has been settled already).
func in_landing(world_point: Vector3) -> bool:
	var at := global_transform.affine_inverse() * world_point
	return absf(at.x - landing_centre.x) <= landing_size.x * 0.5 and absf(at.z - landing_centre.z) <= landing_size.y * 0.5


func lower_storey() -> BuildingInterior:
	return get_node_or_null(lower) as BuildingInterior


func upper_storey() -> BuildingInterior:
	return get_node_or_null(upper) as BuildingInterior


# How far up the stair a point of the world is, 0 at the foot to 1 at the head.
func progress(world_point: Vector3) -> float:
	var at := global_transform.affine_inverse() * world_point
	var run := head - foot
	var length_squared := run.length_squared()
	if length_squared < 0.0001:
		return 0.0
	return clampf((at - foot).dot(run) / length_squared, 0.0, 1.0)


# How far along the stair a point of the world is, in metres from the foot.
func along(world_point: Vector3) -> float:
	return progress(world_point) * Vector3(head.x - foot.x, 0.0, head.z - foot.z).length()


# The ground the stair stands over, in the world: the box round its two
# ends, as wide as it is.
func footprint() -> Rect2:
	var flat := Vector3(head.x - foot.x, 0.0, head.z - foot.z)
	var side_axis := (flat.normalized() if flat.length() > 0.001 else Vector3.RIGHT).cross(Vector3.UP)
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for end: Vector3 in [foot, head]:
		for share: float in [-0.5, 0.5]:
			var corner := global_transform * (end + side_axis * (width * share))
			low = Vector2(minf(low.x, corner.x), minf(low.y, corner.z))
			high = Vector2(maxf(high.x, corner.x), maxf(high.y, corner.z))
	return Rect2(low, high - low)


# The stair a node belongs to, or null.
static func of(node: Node) -> BuildingStair:
	var at := node
	while at != null:
		if at is BuildingStair:
			return at as BuildingStair
		at = at.get_parent()
	return null


# ------------------------------------------------------------ making it

func build() -> void:
	var flat := Vector3(head.x - foot.x, 0.0, head.z - foot.z)
	var run := flat.length()
	if run < 0.1:
		push_warning("BuildingStair %s: foot and head are not apart" % name)
		return
	var old := get_node_or_null("ramp")
	if old != null:
		remove_child(old)
		old.free()
	# The polygon is drawn in (distance along the stair, height) and pushed
	# out sideways by the width; the same turn the maps' other polygons use.
	var along := flat / run
	var side_axis := along.cross(Vector3.UP)
	var ramp := CSGPolygon3D.new()
	ramp.name = "ramp"
	ramp.transform = Transform3D(
		Basis(along, Vector3.UP, side_axis), Vector3(foot.x, 0.0, foot.z) + side_axis * (width * 0.5))
	if filled:
		ramp.polygon = PackedVector2Array([Vector2(0.0, foot.y), Vector2(run, foot.y), Vector2(run, head.y)])
	else:
		ramp.polygon = PackedVector2Array([
			Vector2(0.0, foot.y - SLAB_THICKNESS), Vector2(run, head.y - SLAB_THICKNESS),
			Vector2(run, head.y), Vector2(0.0, foot.y)])
	ramp.depth = width
	ramp.use_collision = true
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 1.0
	ramp.material = material
	add_child(ramp)
	var scene_root := get_tree().edited_scene_root if Engine.is_editor_hint() else owner
	if scene_root != null:
		ramp.owner = scene_root

	# The steps: boxes standing on the ramp, each with its top level.
	var old_steps := get_node_or_null("steps")
	if old_steps != null:
		remove_child(old_steps)
		old_steps.free()
	var steps := Node3D.new()
	steps.name = "steps"
	add_child(steps)
	var rise := head.y - foot.y
	var count := maxi(1, roundi(absf(rise) / maxf(step_height, 0.05)))
	var tread := run / float(count)
	var each := rise / float(count)
	var step_material := StandardMaterial3D.new()
	step_material.albedo_color = step_color
	step_material.roughness = 1.0
	for i in count:
		var step := MeshInstance3D.new()
		step.name = "step_%d" % i
		var step_box := BoxMesh.new()
		step_box.size = Vector3(tread, absf(each), width)
		step_box.material = step_material
		step.mesh = step_box
		step.transform = Transform3D(
			Basis(along, Vector3.UP, side_axis),
			Vector3(foot.x, 0.0, foot.z) + along * (tread * (i + 0.5)) + Vector3.UP * (foot.y + each * (i + 0.5)))
		steps.add_child(step)
	if scene_root != null:
		steps.owner = scene_root
		for step in steps.get_children():
			step.owner = scene_root

	var up := upper_storey()
	if up == null:
		push_warning("BuildingStair %s: no upper storey set; no opening made" % name)
		return
	# The opening: the stair's whole footprint, as a box in the upper storey.
	var to_storey := up.global_transform.affine_inverse() * global_transform
	var low := Vector3(INF, 0.0, INF)
	var high := Vector3(-INF, 0.0, -INF)
	for end: Vector3 in [foot, head]:
		for sign: float in [-0.5, 0.5]:
			var corner := to_storey * (end + side_axis * (width * sign))
			low = Vector3(minf(low.x, corner.x), 0.0, minf(low.z, corner.z))
			high = Vector3(maxf(high.x, corner.x), 0.0, maxf(high.z, corner.z))
	var holes := up.get_node_or_null("holes") as Node3D
	if holes == null:
		holes = Node3D.new()
		holes.name = "holes"
		up.add_child(holes)
		if scene_root != null:
			holes.owner = scene_root
	var mark := holes.get_node_or_null(String(name)) as MeshInstance3D
	if mark == null:
		mark = MeshInstance3D.new()
		mark.name = name
		holes.add_child(mark)
		if scene_root != null:
			mark.owner = scene_root
	var box := BoxMesh.new()
	box.size = Vector3(high.x - low.x, 1.0, high.z - low.z)
	mark.mesh = box
	mark.position = Vector3((low.x + high.x) * 0.5, (to_storey * head).y, (low.z + high.z) * 0.5)
	up.rebuild_floor()
	if up.is_ground():
		var world_at := up.global_transform * mark.position
		print("BuildingStair %s: the world's ground under %s needs the same opening cut by hand (%.2f x %.2f m at %s)" % [
			name, up.name, box.size.x, box.size.z, world_at])
	print("BuildingStair %s: ramp %.2f m long, opening %.2f x %.2f m in %s" % [name, run, box.size.x, box.size.z, up.name])
