class_name LocalTuning
extends Resource

# N-1: the numbers that stay on each peer. Everything here is about how a press
# is read or what is drawn -- nothing in a ruling, a trajectory or a cost reads
# any of it, which is the test for being in this file rather than in
# PhysicsTuning. Two people can set these differently and nothing they do to
# each other changes.

@export_group("Controls")
# 5-chapter smart key, shared by the jump and the dash (and whatever gets a
# cursor target later). Off: the key shows the range and the landing spot and
# the left button casts. On: the key casts at once.
@export var smart_key_enabled: bool = false
# The jump goes where the cursor points. Turn it off for the documented rule,
# where the jump keeps the heading it was already travelling on.
@export var jump_aims_at_cursor: bool = true
# Cursor within this of the body counts as pointing at yourself, which is how a
# jump straight up is asked for.
@export var jump_aim_deadzone: float = 1.2
@export var move_intent_timeout: float = 1.5
# How near the cursor a thing has to be to count as the thing being aimed at.
# Without it, aiming at a rock that someone else just took picks up whoever is
# standing behind it. The server checks reach with grab_range; this only picks
# which target the intent names.
@export var grab_cursor_radius: float = 1.0
# The one key: let go before the threshold and it is a put-down, hold past it
# and it is a throw whose charge runs to throw_charge_max. The charge itself
# travels in the intent, so these two only map a hold time onto it.
@export var throw_hold_threshold: float = 1.0
@export var throw_charge_max: float = 1.5
