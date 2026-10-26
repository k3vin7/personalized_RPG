extends Node3D

# Render-only markers. No collision objects, navigation geometry or fade groups.
const BOUNDARIES = preload("res://data/world_boundaries.tres")
const RENDER_LAYER := 1 << 19


func _ready() -> void:
	if not OS.is_debug_build():
		visible = false
		return
	var boundaries: Array = BOUNDARIES.get("boundaries")
	for boundary: Dictionary in boundaries:
		var marker := MeshInstance3D.new()
		marker.name = String(boundary["id"])
		var base: Vector3 = boundary["base"]
		var height := float(boundary["height"])
		marker.position = base + Vector3.UP * height * 0.5
		marker.rotation.y = deg_to_rad(float(boundary["yaw_degrees"]))
		var quad := QuadMesh.new()
		quad.size = Vector2(float(boundary["width"]), height)
		marker.mesh = quad
		marker.layers = RENDER_LAYER
		marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var material := ShaderMaterial.new()
		material.shader = preload("res://shaders/debug_boundary.gdshader")
		marker.material_override = material
		add_child(marker)
	Tuning.debug_boundaries_changed.connect(_update_visibility)
	_update_visibility()


func _update_visibility() -> void:
	visible = OS.is_debug_build() and Tuning.debug_boundaries_visible
