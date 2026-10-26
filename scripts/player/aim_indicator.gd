class_name AimIndicator
extends Node3D

# Stage C-2: where a jump or a dash would go, drawn for the person holding the
# key. Two flat rings -- how far the action can reach, and where this one would
# land -- plus a colour change when the cursor is out of reach and the landing
# ring is therefore the limit rather than the cursor.
#
# Local view only: it is built by the owning client, has no collision, is on its
# own render layer and never travels. Nothing here decides anything.

const RENDER_LAYER := 1 << 18
const REACH_COLOUR := Color(0.55, 0.85, 1.0, 0.5)
const LANDING_COLOUR := Color(0.6, 1.0, 0.65, 0.85)
# Out of reach: the ring is the budget's edge, not the cursor.
const CLAMPED_COLOUR := Color(1.0, 0.72, 0.25, 0.9)

var _reach: MeshInstance3D
var _landing: MeshInstance3D
# The dash shows where it is going as an arrow from here to there, because a
# dash is a line and a ring says nothing about which way it runs.
var _arrow: MeshInstance3D
var _clamped := false


# How much of the arrow is the head, and how wide the two parts are.
const ARROW_HEAD := 0.5
const ARROW_SHAFT_HALF_WIDTH := 0.1
const ARROW_HEAD_HALF_WIDTH := 0.28


func _ready() -> void:
	_reach = _ring(0.06)
	_landing = _ring(0.1)
	_arrow = _flat_mesh()
	hide_all()


func _flat_mesh() -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = ImmediateMesh.new()
	node.layers = RENDER_LAYER
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = LANDING_COLOUR
	node.material_override = material
	add_child(node)
	return node


func _ring(thickness: float) -> MeshInstance3D:
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 1.0 - thickness
	torus.outer_radius = 1.0
	torus.rings = 48
	torus.ring_segments = 6
	ring.mesh = torus
	# Flat on the ground: a torus stands up by default.
	ring.rotation_degrees.x = 90.0
	ring.layers = RENDER_LAYER
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.albedo_color = REACH_COLOUR
	ring.material_override = material
	add_child(ring)
	return ring


func hide_all() -> void:
	if _reach != null:
		_reach.visible = false
	if _landing != null:
		_landing.visible = false
	if _arrow != null:
		_arrow.visible = false
	_clamped = false


# from: where the body stands. reach: how far the action can go. landing: where
# this one would end up. clamped: the cursor was past the reach.
func show_aim(from: Vector3, reach: float, landing: Vector3, clamped: bool) -> void:
	if _reach == null or _landing == null:
		return
	_arrow.visible = false
	_clamped = clamped
	# A ring sitting exactly on the floor z-fights with it.
	_reach.global_position = Vector3(from.x, from.y - Player.BODY_HALF_HEIGHT + 0.03, from.z)
	_reach.scale = Vector3(maxf(reach, 0.1), 1.0, maxf(reach, 0.1))
	_reach.visible = true
	_landing.global_position = Vector3(landing.x, landing.y - Player.BODY_HALF_HEIGHT + 0.04, landing.z)
	_landing.scale = Vector3(0.45, 1.0, 0.45)
	(_landing.material_override as StandardMaterial3D).albedo_color = \
		CLAMPED_COLOUR if clamped else LANDING_COLOUR
	_landing.visible = true


# An arrow on the ground from where the body stands to where it would end up.
# Built every frame rather than scaled, because a scaled arrow stretches its
# head: the head is a fixed length and only the shaft grows.
func show_arrow(from: Vector3, to: Vector3, clamped: bool) -> void:
	if _arrow == null:
		return
	_reach.visible = false
	_landing.visible = false
	_clamped = clamped
	var flat := Vector3(to.x - from.x, 0.0, to.z - from.z)
	var length := flat.length()
	if length < 0.05:
		_arrow.visible = false
		return
	var forward := flat / length
	var side := Vector3(-forward.z, 0.0, forward.x)
	var head: float = minf(ARROW_HEAD, length * 0.5)
	var shaft := length - head
	var mesh := _arrow.mesh as ImmediateMesh
	mesh.clear_surfaces()
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var a := side * ARROW_SHAFT_HALF_WIDTH
	var b := -side * ARROW_SHAFT_HALF_WIDTH
	var c := forward * shaft - side * ARROW_SHAFT_HALF_WIDTH
	var d := forward * shaft + side * ARROW_SHAFT_HALF_WIDTH
	for vertex in [a, b, c, a, c, d]:
		mesh.surface_add_vertex(vertex)
	for vertex in [
			forward * shaft + side * ARROW_HEAD_HALF_WIDTH,
			forward * shaft - side * ARROW_HEAD_HALF_WIDTH,
			forward * length]:
		mesh.surface_add_vertex(vertex)
	mesh.surface_end()
	(_arrow.material_override as StandardMaterial3D).albedo_color = \
		CLAMPED_COLOUR if clamped else LANDING_COLOUR
	_arrow.global_position = Vector3(from.x, from.y - Player.BODY_HALF_HEIGHT + 0.04, from.z)
	_arrow.visible = true


func is_showing() -> bool:
	if _landing != null and _landing.visible:
		return true
	return _arrow != null and _arrow.visible


func arrow_length() -> float:
	if _arrow == null or not _arrow.visible:
		return 0.0
	var mesh := _arrow.mesh as ImmediateMesh
	if mesh.get_surface_count() == 0:
		return 0.0
	# The tip is the last vertex written.
	var box := mesh.get_aabb()
	return maxf(box.size.x, box.size.z)


func landing_is_clamped() -> bool:
	return _clamped
