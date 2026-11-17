class_name RaceData
extends Resource

# One race's numbers, 2-chapter of the v4 work order. These are judgement
# values, so the server owns them: nothing here is read from a client's word
# for it, and every peer loads the same resource rather than being told.
#
# Training is not in yet, so these are the "training 0" column. Agility and
# intellect are stored and used nowhere, which is what v4 asks for.

@export var id: int = 0
@export var label: String = ""

@export_group("Abilities")
@export var strength: float = 60.0
@export var endurance: float = 70.0
@export var agility: float = 70.0
@export var intellect: float = 70.0
# C-1a: the fifth ability. HP comes out of this, stamina out of endurance.
# Temporary (2026-11-02): equal to endurance for every race, until the table
# says otherwise.
@export var vitality: float = 70.0

@export_group("Body")
# Stored in H-1 and read in H-4, which is where the capsule and the mesh start
# following it. Nothing sizes itself off this yet.
@export var height_cm: float = 180.0
# Bare: gear and whatever is being carried are added on top, by CharacterStats.
@export var body_weight: float = 80.0
# Riding: this race sits a bigger horse (the same model scaled by the
# server's mount_large_scale). The speed is the same for every race.
@export var large_mount: bool = false

@export_group("Weapons")
# Weapon ids (data/weapons) a body of this race may take in hand. The server
# rules a weapon request against this list; empty hands are not on it and are
# everyone's. A weapon only some races hold is a line here, not a branch.
@export var usable_weapons: PackedStringArray = PackedStringArray()


func can_use(weapon_id: String) -> bool:
	return usable_weapons.has(weapon_id)
