class_name InteriorView
extends Node

# 건물 진입 a: this screen's view of the building the local body is in. One
# per local player, beside the OcclusionFader. Once the body is wholly inside
# a marked building (BuildingInterior) the upstairs and the two camera-side
# walls stop being drawn, everything outside goes black except a lit strip
# outside each door, and a light stands in each doorway; it goes back once
# the body is wholly out. Eased over Tuning.values.interior_fade_time.
#
# Drawn here only: nothing is sent, no collider changes, and the walls that
# are not drawn still stop a body.

const SHROUD_SHADER := preload("res://shaders/interior_shroud.gdshader")

var camera: QuarterCamera
var target: Player
# 0 closed, 1 opened; and the building it is about.
var amount := 0.0
var shown: BuildingInterior

var _shroud: MeshInstance3D
var _material: ShaderMaterial


func setup(view: QuarterCamera, follow: Player) -> void:
	camera = view
	target = follow
	_material = ShaderMaterial.new()
	_material.shader = SHROUD_SHADER
	# Over every other see-through thing: outside is black, whatever is there.
	_material.render_priority = RenderingServer.MATERIAL_RENDER_PRIORITY_MAX
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	quad.flip_faces = true
	_shroud = MeshInstance3D.new()
	_shroud.name = "InteriorShroud"
	_shroud.mesh = quad
	_shroud.material_override = _material
	_shroud.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shroud.extra_cull_margin = 16384.0
	_shroud.visible = false
	view.camera.add_child(_shroud)


func _process(delta: float) -> void:
	if not is_instance_valid(camera) or camera.camera == null:
		return
	if not is_instance_valid(target) or not target.is_inside_tree():
		return
	var entered: BuildingInterior = null
	for node in get_tree().get_nodes_in_group(BuildingInterior.GROUP):
		var interior := node as BuildingInterior
		if interior != null and interior.update_inside(target.global_position, target.radius()) and entered == null:
			entered = interior
	var step := delta / maxf(Tuning.values.interior_fade_time, 0.01)
	if entered != null and (shown == null or shown == entered):
		shown = entered
		amount = minf(1.0, amount + step)
	else:
		amount = maxf(0.0, amount - step)
	if not is_instance_valid(shown):
		shown = null
		amount = 0.0
		_shroud.visible = false
		return
	var to_camera := -camera.get_camera_flat_forward()
	var near := shown.near_sign(to_camera)
	shown.show_amount(amount, to_camera)
	shown.fill(_material, amount, near)
	shown.fill_doors(_material)
	_shroud.visible = amount > 0.0
	if amount <= 0.0:
		shown = null
