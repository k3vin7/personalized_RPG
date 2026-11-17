class_name InteriorView
extends Node

# 건물 진입: this screen's view of the building the local body is in. One per
# local player, beside the OcclusionFader.
#
# Everything is decided by what a thing belongs to, and drawing is turned on
# and off a whole thing at a time. There is no test of where a point is.
#
#   where the body is    the storey (BuildingInterior) or stair (BuildingStair)
#                        that what is under its feet belongs to; on the
#                        world's own ground, a ground storey once the body is
#                        wholly through its door.
#   what is drawn        of that building: of the storey the body is on, the
#                        space it is in (the rooms that open into each other
#                        with no door between; BuildingInterior), the stairs
#                        that stand in that space, and a strip beyond each of
#                        its doors. Not drawn: the storey's other spaces, every
#                        other storey, the roof, and everything that is not
#                        this building.
#   what takes a click   what is drawn.
#
# "Everything that is not this building" is not painted over: the camera
# stops drawing it. Every drawn thing that came with the map is put on
# OUTSIDE_LAYER once, at the start; the camera draws that layer except while
# the body is in a building, and the parts of that building that are to be
# seen are moved off it for as long. The background is black then.
#
# Other players are drawn while they stand on something that is drawn.
#
# Drawn here only: nothing is sent, no collider changes, and what is not
# drawn still stops a body.

const OUTSIDE_LAYER := 1 << 9
const SEEN_LAYER := 1
const ACTOR_PERIOD := 0.2
# How far under the feet the ground is looked for.
const FEET_REACH := 0.6

var camera: QuarterCamera
var target: Player
# The storey the picture is built on, or null (outside every building). On
# a stair this is the stair's lower storey; on its landing, the upper one.
var storey: BuildingInterior
# The stair zone the body is in -- on the stair itself or on its landing at
# the top -- or null. On the stair the picture is the lower storey, the
# stair, and the landing as a patch of floor. On the landing it is the upper
# storey as it always is, walls and all, less the stairs that go on up from
# it (see stair_drawn). Off the landing those come back.
var zone: BuildingStair
var on_landing := false

var _tagged := false
# Going into or out of a building, the screen goes black for a moment and
# the picture is changed while it is: Tuning.values.interior_fade_time for
# the whole of it. Between storeys of one building there is no fade.
var _cover := 0.0
var _cover_rect: ColorRect
var _inside_sky: Environment
var _actors_in := 0.0
# The daylight, turned down while inside (this screen only): every sun in the
# scene, with what it was before.
var _suns: Array = []
var _sun_was: Array[float] = []
var _dimmed := false
# The space of the storey the body is in, as the picture was last built.
var _space := -1


func setup(view: QuarterCamera, follow: Player) -> void:
	camera = view
	target = follow
	# Under the status bars and the panel, over the world.
	var layer := CanvasLayer.new()
	layer.name = "InteriorCover"
	layer.layer = -1
	add_child(layer)
	_cover_rect = ColorRect.new()
	_cover_rect.color = Color(0.0, 0.0, 0.0, 0.0)
	_cover_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cover_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_cover_rect)


func _process(delta: float) -> void:
	if not is_instance_valid(camera) or camera.camera == null:
		return
	if not is_instance_valid(target) or not target.is_inside_tree():
		return
	if not _tagged:
		_tag_world()
		_tagged = true
	if storey != null and not is_instance_valid(storey):
		storey = null
	var place := _place_of_body()
	var now := place[0] as BuildingInterior
	var new_zone := place[1] as BuildingStair
	var new_landing: bool = place[2]
	var new_building: Node = now.get_parent() if now != null else null
	var rate := delta / maxf(Tuning.values.interior_fade_time * 0.5, 0.01)
	if new_building != _building():
		# In or out of a building: black first, then the change.
		_cover = minf(1.0, _cover + rate)
		if _cover >= 1.0:
			if now != null:
				now.current_space = -1
				_space = now.update_space(target.global_position, target.radius())
			_change_to(now, new_zone, new_landing)
	else:
		if now != storey and now != null:
			now.current_space = -1
		var space := now.update_space(target.global_position, target.radius()) if now != null else -1
		if now != storey or new_zone != zone or new_landing != on_landing or space != _space:
			_space = space
			_change_to(now, new_zone, new_landing)
		_cover = maxf(0.0, _cover - rate)
	_cover_rect.color.a = _cover
	if storey == null:
		return
	var to_camera := -camera.get_camera_flat_forward()
	for other in storey.storeys():
		other.apply_view(other == storey, to_camera)
	_dim()
	_actors_in -= delta
	if _actors_in <= 0.0:
		_actors_in = ACTOR_PERIOD
		_show_actors()


# ------------------------------------------------------------ where a body is

# Where the local body is: [storey the picture is built on, stair zone or
# null, whether it is on that stair's landing]. Decided by what is under its
# feet: a stair's own body is the stair; a storey's floor is that storey --
# unless the spot is a stair's landing, which is that stair's zone. On the
# world's own ground it is a ground storey, once wholly through the door.
func _place_of_body() -> Array:
	var at := target.global_position
	var hit := _ground_under(at, target.half_height() + FEET_REACH, target.half_height() + FEET_REACH)
	if hit.is_empty():
		# In the air: what it was.
		return [storey, zone, on_landing]
	var under := hit["collider"] as Node
	var stair := BuildingStair.of(under)
	if stair != null:
		return [stair.lower_storey(), stair, false]
	var standing_on := BuildingInterior.storey_of(under)
	if standing_on == null:
		for node in get_tree().get_nodes_in_group(BuildingInterior.GROUP):
			var ground := node as BuildingInterior
			if ground == null or not ground.is_ground():
				continue
			if not ground.update_inside(at, target.radius(), target.half_height()):
				continue
			if ground == storey or (zone != null and ground == zone.upper_storey()):
				standing_on = ground
				break
			if standing_on == null:
				standing_on = ground
	if standing_on == null:
		return [null, null, false]
	for sibling in standing_on.get_parent().get_children():
		var above := sibling as BuildingStair
		if above != null and above.upper_storey() == standing_on and above.in_landing(at):
			return [standing_on, above, true]
	return [standing_on, null, false]


# What is under a point, down to `reach`. The ray straight down is the
# answer when it finds something within `near` -- something the body can be
# standing on. It is not always to be had: a ray can slip through the seam
# between two triangles of a floor (measured: a body standing exactly on
# such a seam had "nothing" under it, or with a longer reach the floor of
# the storey below). Only then is a small ring of rays tried, and the highest
# thing any of them finds taken.
#
# The ring is not asked first: at the head of a stair it reaches the floor
# beyond while the body is still on the stair, and the picture flipped to
# the upper storey for a moment before the body was on the landing.
const UNDER_OFFSET := 0.15


func _ground_under(from: Vector3, reach: float, near: float) -> Dictionary:
	var space := target.get_world_3d().direct_space_state
	var best := {}
	for offset: Vector3 in [Vector3.ZERO, Vector3(UNDER_OFFSET, 0.0, 0.07), Vector3(-UNDER_OFFSET, 0.0, -0.07),
			Vector3(0.07, 0.0, -UNDER_OFFSET), Vector3(-0.07, 0.0, UNDER_OFFSET)]:
		var query := PhysicsRayQueryParameters3D.create(from + offset, from + offset + Vector3.DOWN * reach, Layers.TERRAIN)
		query.collide_with_areas = false
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			continue
		if offset == Vector3.ZERO and from.y - (hit["position"] as Vector3).y <= near:
			return hit
		if best.is_empty() or (hit["position"] as Vector3).y > (best["position"] as Vector3).y:
			best = hit
	return best


func _building() -> Node:
	return storey.get_parent() if is_instance_valid(storey) else null


# Whether a storey of the building the body is in is drawn: only the one
# the body is on. The storeys above are over its head; the ones below would
# show as the building's outside under the cut-down walls, which is not what
# is being looked at. (They were drawn for a while, to be seen down the
# stairwell; what showed was mostly their outer walls.)
func is_drawn(other: BuildingInterior) -> bool:
	return other != null and is_instance_valid(storey) and other == storey


# A stair is drawn when it touches the storey the body is on -- going up from
# it or coming up to it -- so the way down shows in its opening although the
# storey below does not. From a landing, a stair that goes up from that
# storey and stands over the stair that comes up to the landing is not
# drawn: it is the stair down that has to be seen from there.
func stair_drawn(stair: BuildingStair) -> bool:
	if stair == zone:
		return true
	if on_landing and zone != null and stair.lower_storey() == storey and stair.footprint().intersects(zone.footprint()):
		return false
	# Of the storey the body is on, the stairs that stand in the space it is
	# in: one that starts there, one that comes up there.
	var to_world := stair.global_transform
	if is_drawn(stair.lower_storey()) and storey.space_of_world(to_world * stair.foot) == storey.current_space:
		return true
	return is_drawn(stair.upper_storey()) and storey.space_of_world(to_world * stair.landing_centre) == storey.current_space


# ------------------------------------------------------------ what takes a click

# Whether a click that hit `collider` at `point` lands. Outside every
# building, anything does. Inside one: what is drawn and is for walking on.
func takes_click(collider: Node, point: Vector3) -> bool:
	if not is_instance_valid(storey):
		return true
	var stair := BuildingStair.of(collider)
	if stair != null:
		# A stair is ground: all of it takes a click while it is drawn. (A
		# stair that passes overhead can so take a click meant for the floor
		# behind it, from some camera headings; taking clicks only at its
		# foot was tried and was worse to use.)
		return stair_drawn(stair)
	var owner_storey := BuildingInterior.storey_of(collider)
	if owner_storey != null:
		# Of a storey, only its floor: what is walked on. Walls, posts, rails
		# and furniture let the click through whether they are drawn whole,
		# cut down or not at all -- the top of a cut-down wall is as high as the
		# floor above, and a click that landed there sent the body upstairs.
		if is_drawn(owner_storey):
			return owner_storey.floor_takes_click(collider, point)
		# From on a stair, the landing it goes up to (drawn as a patch of
		# floor while the storey it is part of is not).
		return zone != null and owner_storey == zone.upper_storey() and owner_storey.is_floor(collider) and zone.in_landing(point)
	# The world's own ground: the floor of a drawn ground storey, the lit
	# strip outside a door of the storey the body is on, or -- from on a
	# stair that goes up to a ground storey -- its landing, as above.
	for other in storey.storeys():
		if not other.is_ground():
			continue
		if is_drawn(other):
			if other.over_floor(point):
				return true
		elif zone != null and other == zone.upper_storey() and other.over_floor(point, true) and zone.in_landing(point):
			return true
	return storey.on_door_strip(point)


# ------------------------------------------------------------ what is drawn

# Once: everything drawn that came with the map (saved in a scene, so it has
# an owner) goes on OUTSIDE_LAYER. What the game makes as it runs -- the
# players, the aim marks, the effects -- stays where it is and is always
# drawn. Lights are not things to draw and are left alone.
func _tag_world() -> void:
	var root := get_tree().current_scene
	if root == null:
		return
	var players := target.get_parent()
	for node in root.find_children("*", "VisualInstance3D", true, false):
		var drawn := node as VisualInstance3D
		if drawn is Light3D or drawn.owner == null or drawn.layers != SEEN_LAYER:
			continue
		if (players != null and players.is_ancestor_of(drawn)) or _is_actor(drawn):
			continue
		drawn.layers = OUTSIDE_LAYER


# Sorts the world again: for map pieces put in after the game began.
func retag() -> void:
	_tag_world()


static func _put_on(node: Node, layer: int) -> void:
	var all := node.find_children("*", "VisualInstance3D", true, false)
	if node is VisualInstance3D:
		all.append(node)
	for found in all:
		var drawn := found as VisualInstance3D
		if not (drawn is Light3D):
			drawn.layers = layer


func _change_to(now: BuildingInterior, new_zone: BuildingStair, new_landing: bool) -> void:
	var old_building := _building()
	var new_building: Node = now.get_parent() if now != null else null
	if old_building != null and old_building != new_building:
		_give_back(old_building)
	storey = now
	zone = new_zone if now != null else null
	on_landing = new_landing and zone != null
	if now == null:
		camera.camera.cull_mask = 0xFFFFF
		camera.camera.environment = null
		_undim()
		for actor in _actors():
			_put_on(actor, SEEN_LAYER)
		return
	camera.camera.cull_mask = 0xFFFFF & ~OUTSIDE_LAYER
	camera.camera.environment = _black_sky()
	for child in new_building.get_children():
		var part := child as Node3D
		if part == null:
			continue
		var seen := false
		var stair := part as BuildingStair
		var owner_storey := BuildingInterior.storey_of(part)
		if stair != null:
			seen = stair_drawn(stair)
			# The landing's own patch of floor: drawn with the stair while the
			# storey it belongs to is not.
			stair.show_landing(stair == zone and not on_landing)
		elif owner_storey != null:
			seen = is_drawn(owner_storey)
		# Anything else under the building is its roof: never seen from inside.
		part.visible = seen
		_put_on(part, SEEN_LAYER if seen else OUTSIDE_LAYER)
	_actors_in = 0.0


# A building the body has left: all of it drawn again, as part of the world.
func _give_back(building: Node) -> void:
	for child in building.get_children():
		var part := child as Node3D
		if part == null:
			continue
		part.visible = true
		_put_on(part, OUTSIDE_LAYER)
		var other := part as BuildingInterior
		if other != null:
			other.reset_view()
		var stair := part as BuildingStair
		if stair != null:
			stair.show_landing(false)


# Black behind everything, and the sky's light at the share the slider gives.
func _black_sky() -> Environment:
	if _inside_sky == null:
		_inside_sky = Environment.new()
		_inside_sky.background_mode = Environment.BG_COLOR
		_inside_sky.background_color = Color.BLACK
		_inside_sky.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	var world := camera.camera.get_world_3d().environment
	if world == null:
		world = camera.camera.get_world_3d().fallback_environment
	_inside_sky.ambient_light_color = world.ambient_light_color if world != null else Color.WHITE
	_inside_sky.ambient_light_energy = (world.ambient_light_energy if world != null else 1.0) * Tuning.values.interior_brightness
	return _inside_sky


# Everything that moves -- other players, monsters, rocks, bodies -- is drawn
# while what it stands on is drawn, and not otherwise.
func _actors() -> Array[Node3D]:
	var out: Array[Node3D] = []
	for node in target.get_parent().get_children():
		if node != target and node is Node3D:
			out.append(node as Node3D)
	for node in get_tree().get_nodes_in_group(ServerAuthority.HOLDABLE_GROUP):
		if node != target and node is Node3D and not out.has(node):
			out.append(node as Node3D)
	return out


func _show_actors() -> void:
	# Another body is drawn when it stands on the storey the local one is on,
	# in the same space.
	for actor in _actors():
		var seen := is_drawn(_storey_under(actor.global_position)) \
			and storey.space_of_world(actor.global_position) == storey.current_space
		_put_on(actor, SEEN_LAYER if seen else OUTSIDE_LAYER)


# The storey of whatever is under a point (no memory, no size): for bodies
# other than the local one.
const UNDER_REACH := 4.0
# A body's middle is this far over what it stands on, at most (with the 0.3 the ray starts above it).
const UNDER_NEAR := 1.8


func _storey_under(at: Vector3) -> BuildingInterior:
	var hit := _ground_under(at + Vector3.UP * 0.3, UNDER_REACH + 0.3, UNDER_NEAR)
	if hit.is_empty():
		return null
	var under := hit["collider"] as Node
	var stair := BuildingStair.of(under)
	if stair != null:
		return stair.lower_storey()
	var standing_on := BuildingInterior.storey_of(under)
	if standing_on != null:
		return standing_on
	for node in get_tree().get_nodes_in_group(BuildingInterior.GROUP):
		var ground := node as BuildingInterior
		if ground != null and ground.is_ground() and ground.over_floor(hit["position"] as Vector3, true):
			return ground
	return null


static func _is_actor(node: Node) -> bool:
	var at := node
	while at != null:
		if at.is_in_group(ServerAuthority.HOLDABLE_GROUP):
			return true
		at = at.get_parent()
	return false


# Inside, the daylight is Tuning.values.interior_brightness of what it is
# outside. Nothing outside is drawn by then, so only the room shows it.
func _dim() -> void:
	if not _dimmed:
		_suns = get_tree().root.find_children("*", "DirectionalLight3D", true, false)
		_sun_was.clear()
		for sun in _suns:
			_sun_was.append((sun as DirectionalLight3D).light_energy)
		_dimmed = true
	_black_sky()
	for i in _suns.size():
		if is_instance_valid(_suns[i]):
			(_suns[i] as DirectionalLight3D).light_energy = _sun_was[i] * Tuning.values.interior_brightness


func _undim() -> void:
	if not _dimmed:
		return
	for i in _suns.size():
		if is_instance_valid(_suns[i]):
			(_suns[i] as DirectionalLight3D).light_energy = _sun_was[i]
	_dimmed = false
