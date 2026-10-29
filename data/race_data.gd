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

@export_group("Body")
# Stored in H-1 and read in H-4, which is where the capsule and the mesh start
# following it. Nothing sizes itself off this yet.
@export var height_cm: float = 180.0
# Bare: gear and whatever is being carried are added on top, by CharacterStats.
@export var body_weight: float = 80.0
