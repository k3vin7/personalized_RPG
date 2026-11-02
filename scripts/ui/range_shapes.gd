class_name RangeShapes
extends Object

# C-0: the one builder for a skill's shape on the ground. Two things draw it:
# the aim indicator, for the person whose key is armed, and a scarecrow's
# telegraph, which fills the same shape in red over its windup. Both write
# their vertices through here, so the shape the key shows and the shape the
# monster shows are the same picture of the same SkillDef numbers.
#
# Local frame: the body at the origin, forward along -Z, right along +X, on
# the ground plane y = 0. The caller puts the mesh at the feet and turns it to
# the heading. `scale` shrinks the whole shape toward the origin, which is how
# a telegraph fills: the outline at 1.0, the fill at the windup's progress.

const FAN_SEGMENTS := 24
const CIRCLE_SEGMENTS := 32
# The pointed end of a LINE, beyond its reach.
const LINE_TIP := 0.3


# Rewrites `mesh` as one triangle surface of the def's shape. The reach, the
# width and the angle are read through def.value() so a slider-backed skill
# draws what the server would rule with.
static func write(mesh: ImmediateMesh, def: SkillDef, scale: float = 1.0) -> void:
	mesh.clear_surfaces()
	if def == null or def.range_shape == SkillDef.RangeShape.NONE or scale <= 0.0:
		return
	var reach := def.value("reach") * scale
	var half_width := def.value("width") * 0.5 * scale
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	match def.range_shape:
		SkillDef.RangeShape.RECT:
			_quad(mesh,
				Vector3(-half_width, 0.0, 0.0), Vector3(half_width, 0.0, 0.0),
				Vector3(half_width, 0.0, -reach), Vector3(-half_width, 0.0, -reach))
		SkillDef.RangeShape.LINE:
			_quad(mesh,
				Vector3(-half_width, 0.0, 0.0), Vector3(half_width, 0.0, 0.0),
				Vector3(half_width, 0.0, -reach), Vector3(-half_width, 0.0, -reach))
			for vertex in [
					Vector3(-half_width, 0.0, -reach),
					Vector3(half_width, 0.0, -reach),
					Vector3(0.0, 0.0, -(reach + LINE_TIP * scale))]:
				mesh.surface_add_vertex(vertex)
		SkillDef.RangeShape.FAN:
			var half_angle := deg_to_rad(def.shape_angle_deg * 0.5)
			for index in FAN_SEGMENTS:
				var a := -half_angle + 2.0 * half_angle * float(index) / float(FAN_SEGMENTS)
				var b := -half_angle + 2.0 * half_angle * float(index + 1) / float(FAN_SEGMENTS)
				mesh.surface_add_vertex(Vector3.ZERO)
				mesh.surface_add_vertex(Vector3(sin(a) * reach, 0.0, -cos(a) * reach))
				mesh.surface_add_vertex(Vector3(sin(b) * reach, 0.0, -cos(b) * reach))
		SkillDef.RangeShape.CIRCLE:
			var centre := Vector3(0.0, 0.0, -reach)
			var radius := def.circle_radius * scale
			for index in CIRCLE_SEGMENTS:
				var a := TAU * float(index) / float(CIRCLE_SEGMENTS)
				var b := TAU * float(index + 1) / float(CIRCLE_SEGMENTS)
				mesh.surface_add_vertex(centre)
				mesh.surface_add_vertex(centre + Vector3(sin(a) * radius, 0.0, -cos(a) * radius))
				mesh.surface_add_vertex(centre + Vector3(sin(b) * radius, 0.0, -cos(b) * radius))
	mesh.surface_end()


static func _quad(mesh: ImmediateMesh, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	for vertex in [a, b, c, a, c, d]:
		mesh.surface_add_vertex(vertex)


# A flat, unshaded, see-through mesh on its own render layer, ready to be
# placed on the ground. Both drawers build theirs with this.
static func make_mesh(colour: Color, render_layer: int) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = ImmediateMesh.new()
	node.layers = render_layer
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = colour
	node.material_override = material
	return node


# Turns a flat heading into the yaw a shape mesh needs so its -Z runs along it.
static func yaw_for(heading: Vector3) -> float:
	var flat := Vector3(heading.x, 0.0, heading.z)
	if flat.length_squared() < 0.0004:
		return 0.0
	return atan2(-flat.x, -flat.z)


# The extent of a shape along its heading, for a check to read back.
static func extent_of(def: SkillDef) -> float:
	if def == null:
		return 0.0
	match def.range_shape:
		SkillDef.RangeShape.LINE:
			return def.value("reach") + LINE_TIP
		SkillDef.RangeShape.CIRCLE:
			return def.value("reach") + def.circle_radius
		SkillDef.RangeShape.NONE:
			return 0.0
	return def.value("reach")
