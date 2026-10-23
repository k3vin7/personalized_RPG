class_name OcclusionFader
extends Node

# Walls between the camera and the local character fade out by discarding
# pixels on a dither pattern. The list of faded walls is published statically
# because the click ray has to skip them: you are aiming at what you can see
# through the wall, not at the wall.

const OCCLUDER_GROUP := "occluder"
# Every wall that is allowed to fade, with its top height in the "top_y" meta.
const WALL_GROUP := "fadeable_wall"
# A wall level with the body is beside it, not in front of it.
const FRONT_MARGIN := 0.1
const FADE_HIDDEN := 0.25
const FADE_VISIBLE := 1.0
const FADE_SPEED := 8.0

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
	# Anything standing between the character and the camera fades, decided by
	# depth rather than by a ray: a ray only catches what is covering the body
	# this instant, and a wall that is about to is just as much in the way.
	# Screen down is camera side, so a wall nearer the camera than the body can
	# cover it and a wall further away never can.
	#
	# Fading them all has two effects beyond visibility: the character can never
	# be hidden, and a faded wall stops taking the click, so the ground behind
	# it can be aimed at. The dither keeps the wall readable as a wall.
	var line := target.global_position.z
	for node in get_tree().get_nodes_in_group(WALL_GROUP):
		var wall := node as CollisionObject3D
		if wall == null:
			continue
		var wall_id := wall.get_instance_id()
		if not _levels.has(wall_id):
			_levels[wall_id] = {"body": wall, "level": FADE_VISIBLE}

	for instance_id in _levels.keys():
		var entry: Dictionary = _levels[instance_id]
		var body := entry["body"] as Node3D
		if not is_instance_valid(body):
			_levels.erase(instance_id)
			continue
		var in_front: bool = float(body.get_meta("near_z", -INF)) > line + FRONT_MARGIN
		var wanted := FADE_HIDDEN if in_front else FADE_VISIBLE
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


func _apply_fade(body: Node3D, level: float) -> void:
	for child in body.get_children():
		var mesh_instance := child as MeshInstance3D
		if mesh_instance == null:
			continue
		var material := mesh_instance.material_override as ShaderMaterial
		if material != null:
			material.set_shader_parameter("fade", level)
