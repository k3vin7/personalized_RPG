class_name VillageTerrain
extends Node

# V-1: the village ground, a Terrain3D of 4 x 4 regions (64 m each, x and z
# -128..128) filled from VillageLayout.height_at() on every peer, the way
# TestTerrain fills the test region (T-1b). Nothing is painted by hand:
# roads and the plaza get the dirt / stone textures from the layout's
# roads, everything else is the grass-rock auto shader.
#
# Collision follows T-1b: the judge builds FULL_GAME at start, a client a
# DYNAMIC_GAME patch around its own body (radius and shape size from
# LocalTuning). Both read the same heights.

const TEX_GRASS := 0
const TEX_ROCK := 1
const TEX_DIRT := 2
const TEX_STONE := 3

var layout: VillageLayout
var terrain: Node3D
var built := false
var _configured := false
var configured_as := ""


static func build(parent: Node, village_layout: VillageLayout) -> VillageTerrain:
	var holder := VillageTerrain.new()
	holder.name = "VillageTerrain"
	holder.layout = village_layout
	parent.add_child(holder)
	holder._build()
	return holder


func _build() -> void:
	if not ClassDB.class_exists("Terrain3D"):
		push_error("VillageTerrain: Terrain3D is not loaded")
		return
	terrain = ClassDB.instantiate("Terrain3D")
	terrain.name = "Terrain3D"
	if get_parent() is Node3D:
		terrain.set("clipmap_target", get_parent())
	add_child(terrain)
	terrain.set("region_size", 64)
	if int(terrain.get("region_size")) != 64:
		terrain.change_region_size(64)
	var material: Object = terrain.get("material")
	if material != null:
		material.set("world_background", 0)
		material.set("auto_shader_enabled", true)
		# Measured on screen (V-1 shots): with grass as the base the flats
		# came out grey and only the steep rims green, so the two are the
		# other way round from what the names suggest. Rock base, grass
		# overlay gives green flats and grey walls.
		material.set_shader_param("auto_base_texture", TEX_ROCK)
		material.set_shader_param("auto_overlay_texture", TEX_GRASS)
	var assets: Object = terrain.get("assets")
	if assets != null:
		assets.set_texture_asset(TEX_GRASS, _texture_asset("Grass", Color(0.33, 0.52, 0.27)))
		assets.set_texture_asset(TEX_ROCK, _texture_asset("Rock", Color(0.48, 0.47, 0.45)))
		assets.set_texture_asset(TEX_DIRT, _texture_asset("Dirt", Color(0.45, 0.33, 0.22)))
		assets.set_texture_asset(TEX_STONE, _texture_asset("Stone", Color(0.58, 0.57, 0.54)))
	var data: Object = terrain.get("data")
	var size := layout.terrain_size
	var image := Image.create_empty(size, size, false, Image.FORMAT_RF)
	var ox := layout.terrain_origin.x
	var oz := layout.terrain_origin.y
	var started := Time.get_ticks_msec()
	# One pass: the height, and which cells are road (dirt) or plaza (stone).
	var paint: Array[Vector3i] = []
	for ix in size:
		for iz in size:
			var x := ox + ix
			var z := oz + iz
			image.set_pixel(ix, iz, Color(layout.height_at(x, z), 0.0, 0.0, 1.0))
			if Vector2(x, z).length() <= layout.plaza_radius + 0.5:
				paint.append(Vector3i(ix, TEX_STONE, iz))
			else:
				for road in layout.roads:
					if float(layout.road_at(road, Vector2(x, z))["distance"]) <= float(road["width"]) * 0.5:
						paint.append(Vector3i(ix, TEX_DIRT, iz))
						break
	var shaped := Time.get_ticks_msec()
	data.import_images([image, null, null], Vector3(ox, 0.0, oz), 0.0, 1.0)
	# The auto shader is off on painted cells.
	for cell in paint:
		var at := Vector3(ox + cell.x, 0.0, oz + cell.z)
		if data.has_method("set_control_auto"):
			data.set_control_auto(at, false)
		data.set_control_base_id(at, cell.y)
	data.update_maps()
	terrain.set("collision_layer", Layers.WORLD)
	terrain.set("collision_mask", 0)
	built = true
	print("VILLAGE_TERRAIN built regions=%d origin=%s size=%d painted=%d shape_ms=%d total_ms=%d" % [
		data.get_region_count(), layout.terrain_origin, size, paint.size(),
		shaped - started, Time.get_ticks_msec() - started])


static func _texture_asset(label: String, colour: Color) -> Resource:
	var albedo := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	albedo.fill(colour)
	var normal := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	normal.fill(Color(0.5, 0.5, 1.0, 0.9))
	var asset: Resource = ClassDB.instantiate("Terrain3DTextureAsset")
	asset.set("name", label)
	asset.set("albedo_texture", ImageTexture.create_from_image(albedo))
	asset.set("normal_texture", ImageTexture.create_from_image(normal))
	asset.set("uv_scale", 0.1)
	return asset


func _physics_process(_delta: float) -> void:
	if terrain == null or not multiplayer.has_multiplayer_peer():
		return
	var mine: Node3D = null
	if Net.spawn_root != null:
		mine = Net.spawn_root.get_node_or_null(str(multiplayer.get_unique_id())) as Node3D
	if not _configured:
		if multiplayer.is_server():
			terrain.set("collision_mode", 3)  # Terrain3DCollision.FULL_GAME
			configured_as = "FULL_GAME"
		else:
			terrain.set("collision_mode", 1)  # DYNAMIC_GAME
			configured_as = "DYNAMIC_GAME"
		_configured = true
		print("VILLAGE_TERRAIN collision=%s peer=%d" % [configured_as, multiplayer.get_unique_id()])
	if mine != null:
		if terrain.get("clipmap_target") != mine:
			terrain.set("clipmap_target", mine)
		if not multiplayer.is_server():
			if terrain.get("collision_target") != mine:
				terrain.set("collision_target", mine)
			var radius := int(Tuning.values.terrain_collision_radius)
			var shape := int(Tuning.values.terrain_collision_shape_size)
			if int(terrain.get("collision_radius")) != radius:
				terrain.set("collision_radius", radius)
			if int(terrain.get("collision_shape_size")) != shape:
				terrain.set("collision_shape_size", shape)


func collision_mode() -> int:
	return int(terrain.get("collision_mode")) if terrain != null else -1


func data() -> Object:
	return terrain.get("data") if terrain != null else null


# Terrain3D's own height at a point (NAN outside the regions).
func height_of(at: Vector3) -> float:
	var d := data()
	return d.get_height(at) if d != null else NAN


func nav_faces() -> PackedVector3Array:
	if terrain == null:
		return PackedVector3Array()
	return terrain.generate_nav_mesh_source_geometry(AABB(), false)
