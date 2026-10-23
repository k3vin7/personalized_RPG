class_name PhysicsTuning
extends Resource

# Every tunable number in the playground. Nothing may hardcode these: the debug
# panel edits this resource live, which is the point of the whole exercise.
# Defaults are the ones written in the work order, section 4.

@export_group("Movement")
@export var gravity: float = 22.0
@export var base_move_speed: float = 6.0
@export var base_jump_height: float = 1.6
@export var move_intent_timeout: float = 1.5
# Off by default, which is the documented rule: a jump keeps the heading it was
# already travelling on. Turned on, the jump goes where the cursor points at the
# same speed, so the two can be compared without anything else changing.
@export var jump_aims_at_cursor: bool = false

@export_group("Strength to weight")
@export var ratio_k_jump: float = 0.35
@export var ratio_k_speed: float = 0.30
@export var ratio_mult_min: float = 0.7
@export var ratio_mult_max: float = 1.3

@export_group("Dash")
@export var dash_distance: float = 4.0
@export var dash_duration: float = 0.18
@export var dash_cooldown: float = 1.0
@export var allow_dash_jump: bool = false

@export_group("Climb")
@export var climb_speed: float = 2.0
@export var climb_attach_distance: float = 0.6
@export var stamina_max: float = 100.0
@export var stamina_climb_drain: float = 15.0
@export var stamina_regen: float = 25.0
@export var wall_jump_enabled: bool = false

@export_group("Force")
@export var shove_power: float = 7.0
@export var shove_up_bias: float = 0.25
@export var throw_power: float = 11.0
@export var throw_up_angle_deg: float = 35.0
@export var grab_range: float = 1.5
@export var grabbed_escape_presses: int = 5
@export var grabbed_escape_window: float = 2.0
@export var shove_damage: float = 3.0
@export var shove_stun_time: float = 0.4
@export var ally_ground_damage: bool = true
@export var ally_ground_stun: bool = true

@export_group("Survival")
@export var fall_damage_min_height: float = 4.0
@export var fall_damage_per_meter: float = 8.0
@export var fall_damage_enabled: bool = true
@export var kill_plane_y: float = -20.0
@export var respawn_delay: float = 2.0
