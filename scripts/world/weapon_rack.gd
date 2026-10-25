class_name WeaponRack
extends Node3D

# Five pedestals. Standing on one and pressing the interact key takes that
# weapon, which is a choice and nothing more: there is no combat here. The
# choice replicates, so the other player sees what you are carrying.

const INTERACT_GROUP := "interactable"

const PICKUP_LAYER := Layers.PICKUP
const SPACING := 2.2

var _zones: Array[Area3D] = []


func _ready() -> void:
	var kinds := [
		WeaponKinds.Kind.SWORD,
		WeaponKinds.Kind.BOW,
		WeaponKinds.Kind.SPEAR,
		WeaponKinds.Kind.SHIELD,
		WeaponKinds.Kind.STAFF,
	]
	for index in kinds.size():
		var kind: int = kinds[index]
		var offset := Vector3((float(index) - 2.0) * SPACING, 0.0, 0.0)
		_build_pedestal(kind, offset)

	add_to_group(INTERACT_GROUP)

	var sign_label := Label3D.new()
	sign_label.text = "무기 선택대 · 받침대에 서서 G"
	sign_label.position = Vector3(0.0, 2.6, 0.0)
	sign_label.font_size = 34
	sign_label.outline_size = 7
	sign_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sign_label.no_depth_test = true
	add_child(sign_label)

	# Middle of the rack drops the weapon again.
	_build_zone(WeaponKinds.Kind.NONE, Vector3(0.0, 0.0, 1.8), Vector3(2.0, 2.0, 1.4))


# Returns whether this rack had anything to offer the body that pressed the key.
func interact(player: Player) -> bool:
	for area in _zones:
		if not is_instance_valid(area):
			continue
		if not area.get_overlapping_bodies().has(player):
			continue
		player.set_weapon(int(area.get_meta("kind", WeaponKinds.Kind.NONE)))
		return true
	return false


func _build_pedestal(kind: int, offset: Vector3) -> void:
	var stand := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.4, 0.5, 1.4)
	stand.mesh = box
	stand.position = offset + Vector3(0.0, 0.25, 0.0)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("6d747b")
	stand.material_override = material
	add_child(stand)

	var display := WeaponKinds.build_mesh(kind)
	display.position = offset + Vector3(0.0, 1.3, 0.0)
	display.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	add_child(display)

	var label := Label3D.new()
	label.text = WeaponKinds.LABELS[kind]
	label.position = offset + Vector3(0.0, 2.0, 0.0)
	label.font_size = 30
	label.outline_size = 6
	label.modulate = Color(WeaponKinds.COLORS[kind])
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	add_child(label)

	_build_zone(kind, offset, Vector3(1.6, 2.4, 1.6))


func _build_zone(kind: int, offset: Vector3, size: Vector3) -> void:
	var area := Area3D.new()
	area.position = offset + Vector3(0.0, size.y * 0.5, 0.0)
	# Watches the player layer; it is not something anything collides with.
	area.collision_layer = PICKUP_LAYER
	area.collision_mask = Layers.PLAYER
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	area.add_child(collision)
	add_child(area)
	# Entering no longer equips anything: the area only records who is standing
	# where, and the interact key decides when that matters.
	area.set_meta("kind", kind)
	_zones.append(area)
