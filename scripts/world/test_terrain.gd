class_name TestTerrain
extends Node

# T-1b: the one test region, built from code on every peer so the server and
# the clients hold the same heights without a data file. One 64 x 64 m
# Terrain3D region east of the arena (Regions.TERRAIN): flat ground, a gentle
# hill (max slope 30 deg, walkable), a steep bank (51 deg, slides), a plateau
# with a near-vertical edge (79 deg, the drop for the fall check) and a flat
# "forest floor" painted dirt. Three textures tell grass, dirt and rock
# apart; nothing more (no art).
#
# height_at() is the shape. The height map is filled from it, and the checks
# compare Terrain3D's get_height() against it on both peers.
#
# Collision: the server (the judge) builds FULL_GAME, one shape per region,
# at start -- it has no camera and many bodies. A client builds DYNAMIC_GAME
# around its own body (collision_target), radius and shape size from
# LocalTuning. Both read the same heights, so the ruling and the picture
# stand on the same ground.

const SIZE := 64
const HILL_CENTRE := Vector2(150.0, 40.0)
const HILL_RADIUS := 16.0
const HILL_HEIGHT := 6.0
# The bank: a ramp up along x from BANK_X0 to BANK_X1, a flat top to
# BANK_X2, and a gentle ramp down to BANK_X3; between BANK_Z0 and BANK_Z1,
# with soft edges on z.
const BANK_X0 := 136.0
const BANK_X1 := 140.0
const BANK_X2 := 146.0
const BANK_X3 := 158.0
const BANK_HEIGHT := 5.0
const BANK_Z0 := 8.0
const BANK_Z1 := 24.0
const BANK_SOFT := 2.0
const PLATEAU_CENTRE := Vector2(176.0, 16.0)
const PLATEAU_RADIUS := 8.0
const PLATEAU_EDGE := 1.5
const PLATEAU_HEIGHT := 8.0
# Painted dirt (texture 2): the forest floor.
const FOREST_X0 := 128.0
const FOREST_X1 := 144.0
const FOREST_Z0 := 40.0
const FOREST_Z1 := 64.0
# Texture ids.
const TEX_GRASS := 0
const TEX_ROCK := 1
const TEX_DIRT := 2

var terrain: Node3D
var _configured := false
var configured_as := ""
var built := false


# The ground's height at a world x, z. Flat 0 outside the features.
static func height_at(x: float, z: float) -> float:
	var h := 0.0
	# The hill: a cosine bump, max slope pi * H / (2 R) = 30.5 deg.
	var hill_r := Vector2(x, z).distance_to(HILL_CENTRE)
	if hill_r < HILL_RADIUS:
		h = maxf(h, HILL_HEIGHT * 0.5 * (1.0 + cos(PI * hill_r / HILL_RADIUS)))
	# The bank.
	var bank := 0.0
	if x >= BANK_X0 and x <= BANK_X3:
		if x < BANK_X1:
			bank = BANK_HEIGHT * (x - BANK_X0) / (BANK_X1 - BANK_X0)
		elif x <= BANK_X2:
			bank = BANK_HEIGHT
		else:
			bank = BANK_HEIGHT * (1.0 - (x - BANK_X2) / (BANK_X3 - BANK_X2))
		var zf := 1.0
		if z < BANK_Z0 + BANK_SOFT:
			zf = clampf((z - BANK_Z0) / BANK_SOFT, 0.0, 1.0)
		elif z > BANK_Z1 - BANK_SOFT:
			zf = clampf((BANK_Z1 - z) / BANK_SOFT, 0.0, 1.0)
		bank *= smoothstep(0.0, 1.0, zf)
	h = maxf(h, bank)
	# The plateau: flat top, a steep rim PLATEAU_EDGE wide.
	var plat_r := Vector2(x, z).distance_to(PLATEAU_CENTRE)
	if plat_r < PLATEAU_RADIUS + PLATEAU_EDGE:
		var t := clampf((plat_r - PLATEAU_RADIUS) / PLATEAU_EDGE, 0.0, 1.0)
		h = maxf(h, PLATEAU_HEIGHT * (1.0 - t))
	return h


static func origin() -> Vector3:
	return Regions.TERRAIN


static func in_forest(x: float, z: float) -> bool:
	return x >= FOREST_X0 and x < FOREST_X1 and z >= FOREST_Z0 and z < FOREST_Z1


# Builds the Terrain3D node under `parent` and fills it. Returns it.
static func build(parent: Node) -> TestTerrain:
	var holder := TestTerrain.new()
	holder.name = "TestTerrain"
	parent.add_child(holder)
	holder._build()
	return holder


func _build() -> void:
	if not ClassDB.class_exists("Terrain3D"):
		push_error("TestTerrain: Terrain3D is not loaded")
		return
	terrain = ClassDB.instantiate("Terrain3D")
	terrain.name = "Terrain3D"
	# Until a body exists the clipmap follows the world root (headless has no
	# camera, and Terrain3D complains every frame without a target).
	if get_parent() is Node3D:
		terrain.set("clipmap_target", get_parent())
	add_child(terrain)
	# After it is in the tree: set before, the region size stayed at the
	# default 256 and the import landed inside region (0, 0), x 0..256 -- a
	# 256 m slab of ground under everything east of the hub (T-1b, 1st run).
	terrain.set("region_size", 64)
	if int(terrain.get("region_size")) != 64:
		terrain.change_region_size(64)
	var material: Object = terrain.get("material")
	if material != null:
		material.set("world_background", 0)
		material.set("auto_shader_enabled", true)
		material.set_shader_param("auto_base_texture", TEX_GRASS)
		material.set_shader_param("auto_overlay_texture", TEX_ROCK)
	var assets: Object = terrain.get("assets")
	if assets != null:
		assets.set_texture_asset(TEX_GRASS, _texture_asset("Grass", Color(0.33, 0.52, 0.27)))
		assets.set_texture_asset(TEX_ROCK, _texture_asset("Rock", Color(0.48, 0.47, 0.45)))
		assets.set_texture_asset(TEX_DIRT, _texture_asset("Dirt", Color(0.45, 0.33, 0.22)))
	var data: Object = terrain.get("data")
	var image := Image.create_empty(SIZE, SIZE, false, Image.FORMAT_RF)
	var o := origin()
	for ix in SIZE:
		for iz in SIZE:
			image.set_pixel(ix, iz, Color(height_at(o.x + ix, o.z + iz), 0.0, 0.0, 1.0))
	data.import_images([image, null, null], o, 0.0, 1.0)
	# The forest floor: dirt as the base texture, the auto shader off there.
	for ix in SIZE:
		for iz in SIZE:
			var x := o.x + ix
			var z := o.z + iz
			if in_forest(x, z):
				var at := Vector3(x, 0.0, z)
				if data.has_method("set_control_auto"):
					data.set_control_auto(at, false)
				data.set_control_base_id(at, TEX_DIRT)
	data.update_maps()
	terrain.set("collision_layer", Layers.WORLD)
	terrain.set("collision_mask", 0)
	built = true
	print("PLAYGROUND_TERRAIN built regions=%d at %s origin=%s region_size=%d" % [
		data.get_region_count(), data.get("region_locations"), o, int(terrain.get("region_size"))])


static func _texture_asset(label: String, colour: Color) -> Resource:
	var albedo := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	albedo.fill(colour)
	var normal := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	# A flat normal, roughness 0.9 in alpha.
	normal.fill(Color(0.5, 0.5, 1.0, 0.9))
	var asset: Resource = ClassDB.instantiate("Terrain3DTextureAsset")
	asset.set("name", label)
	asset.set("albedo_texture", ImageTexture.create_from_image(albedo))
	asset.set("normal_texture", ImageTexture.create_from_image(normal))
	asset.set("uv_scale", 0.1)
	return asset


# Once the peer is known: the judge builds full collision, a client a dynamic
# patch around its own body. Rechecked every tick for the client's targets
# (its body arrives after the scene) and its sliders.
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
		print("PLAYGROUND_TERRAIN collision=%s peer=%d" % [configured_as, multiplayer.get_unique_id()])
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


# Terrain3D's own height at a point (NAN outside the region).
func height_of(at: Vector3) -> float:
	var d := data()
	return d.get_height(at) if d != null else NAN


# Faces for the navigation bake, the whole terrain.
func nav_faces() -> PackedVector3Array:
	if terrain == null:
		return PackedVector3Array()
	return terrain.generate_nav_mesh_source_geometry(AABB(), false)
