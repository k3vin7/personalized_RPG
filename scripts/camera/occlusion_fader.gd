class_name OcclusionFader
extends Node

# Walls between the camera and the local character fade out by discarding
# pixels on a dither pattern. The list of faded walls is published statically
# because the click ray has to skip them: you are aiming at what you can see
# through the wall, not at the wall.

const OCCLUDER_GROUP := "occluder"
# Every wall that is allowed to fade, with its top height in the "top_y" meta.
const WALL_GROUP := "fadeable_wall"
# Strictly below our feet by this much, so a wall whose top is level with the
# ground we stand on stays solid.
const FADE_BELOW_MARGIN := 0.1
const FADE_HIDDEN := 0.25
const FADE_VISIBLE := 1.0
const FADE_SPEED := 8.0
const RAY_MASK := 1 | 2 | 4
const CHEST_HEIGHT := 0.9
const MAX_WALLS := 8

static var _faded: Array[RID] = []

var camera: QuarterCamera
var target: Node3D

var _levels: Dictionary = {}


static func faded_rids() -> Array[RID]:
	return _faded.duplicate()


func setup(view: QuarterCamera, follow: Node3D) -> void:
	camera = view
	target = follow
	set_physics_process(true)


func _exit_tree() -> void:
	_faded.clear()


func _physics_process(delta: float) -> void:
	if not is_instance_valid(camera) or camera.camera == null or not is_instance_valid(target):
		return
	var blocking := _walls_in_the_way()
	# Height rule, independent of what the camera ray happens to graze: a wall
	# that tops out below our feet is behind us as far as the view is concerned,
	# so it fades whether it is next to us or across the map.
	var feet_y := target.global_position.y - Player.BODY_HALF_HEIGHT - FADE_BELOW_MARGIN
	for node in get_tree().get_nodes_in_group(WALL_GROUP):
		var wall := node as CollisionObject3D
		if wall == null:
			continue
		var wall_id := wall.get_instance_id()
		if not _levels.has(wall_id):
			_levels[wall_id] = {"body": wall, "level": FADE_VISIBLE}
		if float(wall.get_meta("top_y", INF)) < feet_y:
			blocking[wall_id] = true

	# Known walls ease towards hidden or visible; the dither makes the change
	# readable without any sorting problems.
	for instance_id in _levels.keys():
		var entry: Dictionary = _levels[instance_id]
		var body := entry["body"] as Node3D
		if not is_instance_valid(body):
			_levels.erase(instance_id)
			continue
		var wanted := FADE_HIDDEN if blocking.has(instance_id) else FADE_VISIBLE
		var level := lerpf(float(entry["level"]), wanted, 1.0 - exp(-FADE_SPEED * delta))
		entry["level"] = level
		_apply_fade(body, level)

	_faded.clear()
	for instance_id in _levels.keys():
		var entry: Dictionary = _levels[instance_id]
		if float(entry["level"]) < 0.85:
			var body := entry["body"] as CollisionObject3D
			if is_instance_valid(body):
				_faded.append(body.get_rid())


func _walls_in_the_way() -> Dictionary:
	var found := {}
	var from := camera.camera.global_position
	var to := target.global_position + Vector3.UP * CHEST_HEIGHT
	var query := PhysicsRayQueryParameters3D.create(from, to, RAY_MASK)
	query.collide_with_areas = false
	query.hit_from_inside = true
	var excludes: Array[RID] = []
	for _index in range(MAX_WALLS):
		query.exclude = excludes
		var hit := camera.get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty():
			break
		var body := hit.get("collider") as CollisionObject3D
		if body == null:
			break
		excludes.append(body.get_rid())
		if not body.is_in_group(OCCLUDER_GROUP):
			continue
		found[body.get_instance_id()] = true
		if not _levels.has(body.get_instance_id()):
			_levels[body.get_instance_id()] = {"body": body, "level": FADE_VISIBLE}
	return found


func _apply_fade(body: Node3D, level: float) -> void:
	for child in body.get_children():
		var mesh_instance := child as MeshInstance3D
		if mesh_instance == null:
			continue
		var material := mesh_instance.material_override as ShaderMaterial
		if material != null:
			material.set_shader_parameter("fade", level)
