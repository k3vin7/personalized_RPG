class_name RacePedestal
extends Node3D

# M-3: four stands, one per race. Standing on one and pressing the interact key
# asks the server for that race (Intent.RACE); the server rules -- empty hands,
# on the ground, not held, not climbing -- and the race travels back on the
# Vitals synchronizer like every other ability (H-1). Grey boxes and a name:
# the shape is the weapon rack's, so the two read the same.

const SPACING := 2.2
const ZONE_SIZE := Vector3(1.6, 2.4, 1.6)

var _zones: Array[Area3D] = []


func _ready() -> void:
	for index in Races.all_kinds().size():
		var kind: int = Races.all_kinds()[index]
		var offset := Vector3((float(index) - 1.5) * SPACING, 0.0, 0.0)
		_build_pedestal(kind, offset)
	add_to_group(WeaponRack.INTERACT_GROUP)

	var sign_label := Label3D.new()
	sign_label.text = "종족 선택대 · 받침대에 서서 잡기 키(슬롯 2, 빈손)"
	sign_label.position = Vector3(0.0, 2.6, 0.0)
	sign_label.font_size = 34
	sign_label.outline_size = 7
	sign_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sign_label.no_depth_test = true
	add_child(sign_label)


# Returns whether this stand had anything to ask for the body that pressed the
# key. The asking is all it does; the answer is the server's.
func interact(player: Player) -> bool:
	for area in _zones:
		if not is_instance_valid(area):
			continue
		if not area.get_overlapping_bodies().has(player):
			continue
		ServerAuthority.submit_intent(player, ServerAuthority.Intent.RACE, {
			"race": int(area.get_meta("race", Races.DEFAULT))})
		return true
	return false


func zone_position(kind: int) -> Vector3:
	for area in _zones:
		if int(area.get_meta("race", -1)) == kind:
			return area.global_position - Vector3(0.0, ZONE_SIZE.y * 0.5, 0.0)
	return global_position


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

	var label := Label3D.new()
	var data := Races.data_for(kind)
	label.text = "%s\n%.0fcm · %.0fkg" % [data.label, data.height_cm, data.body_weight]
	label.position = offset + Vector3(0.0, 1.8, 0.0)
	label.font_size = 30
	label.outline_size = 6
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	add_child(label)

	var area := Area3D.new()
	area.position = offset + Vector3(0.0, ZONE_SIZE.y * 0.5, 0.0)
	area.collision_layer = Layers.PICKUP
	area.collision_mask = Layers.PLAYER
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = ZONE_SIZE
	collision.shape = shape
	area.add_child(collision)
	add_child(area)
	area.set_meta("race", kind)
	_zones.append(area)
