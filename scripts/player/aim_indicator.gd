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


func _ready() -> void:
	_reach = _ring(0.06)
	_landing = _ring(0.1)
	hide_all()


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


# from: where the body stands. reach: how far the action can go. landing: where
# this one would end up. clamped: the cursor was past the reach.
func show_aim(from: Vector3, reach: float, landing: Vector3, clamped: bool) -> void:
	if _reach == null or _landing == null:
		return
	# A ring sitting exactly on the floor z-fights with it.
	_reach.global_position = Vector3(from.x, from.y - Player.BODY_HALF_HEIGHT + 0.03, from.z)
	_reach.scale = Vector3(maxf(reach, 0.1), 1.0, maxf(reach, 0.1))
	_reach.visible = true
	_landing.global_position = Vector3(landing.x, landing.y - Player.BODY_HALF_HEIGHT + 0.04, landing.z)
	_landing.scale = Vector3(0.45, 1.0, 0.45)
	(_landing.material_override as StandardMaterial3D).albedo_color = \
		CLAMPED_COLOUR if clamped else LANDING_COLOUR
	_landing.visible = true


func is_showing() -> bool:
	return _landing != null and _landing.visible


func landing_is_clamped() -> bool:
	if _landing == null:
		return false
	return (_landing.material_override as StandardMaterial3D).albedo_color.is_equal_approx(CLAMPED_COLOUR)
