class_name PhysicsTuning
extends Resource

# Every tunable number in the playground. Nothing may hardcode these: the debug
# panel edits this resource live, which is the point of the whole exercise.
# Defaults are the ones written in the work order, section 4.

@export_group("Movement")
@export var gravity: float = 22.0
@export var base_move_speed: float = 6.0
# The vertical half of the leap budget: v_cap is built from this and the move
# speed. Since stage C-2 it is not the standing jump's height on its own -- a
# standing jump spends the whole budget upward and goes higher than this.
@export var base_jump_height: float = 1.6
@export var move_intent_timeout: float = 1.5
# Stage C-2: the jump goes to the cursor. Inside this radius the cursor means
# "straight up", which is a hard edge on purpose -- just outside it is the
# lowest hop there is.
@export var jump_inplace_radius: float = 0.8
@export var jump_min_hop_height: float = 0.4
# The jump goes where the cursor points. Turn it off for the documented rule,
# where the jump keeps the heading it was already travelling on.
@export var jump_aims_at_cursor: bool = true
# Cursor within this of the body counts as pointing at yourself, which is how a
# jump straight up is asked for.
@export var jump_aim_deadzone: float = 1.2

@export_group("Strength to weight")
@export var ratio_k_jump: float = 0.35
@export var ratio_k_speed: float = 0.30
@export var ratio_mult_min: float = 0.7
@export var ratio_mult_max: float = 1.3

@export_group("Dash")
# Stage C-2: the dash is the leap budget spent entirely sideways. Its speed is
# v_cap times this, so strength is already in it and is not applied again; the
# far end is that speed held for dash_time_max, and the time a dash takes comes
# out of distance divided by speed rather than being fixed.
@export var dash_min_distance: float = 1.2
@export var dash_time_max: float = 0.4
@export var dash_speed_mult: float = 1.0
@export var dash_cooldown: float = 1.0

@export_group("Climb")
@export var climb_speed: float = 2.0
@export var climb_attach_distance: float = 0.6
@export var stamina_max: float = 100.0
@export var stamina_climb_drain: float = 15.0
@export var stamina_regen: float = 25.0
# 6-chapter stamina costs. Dash is the one stage C spends.
@export var stamina_dash_cost: float = 10.0

@export_group("Force")
@export var shove_power: float = 7.0
@export var shove_up_bias: float = 0.25
@export var throw_power: float = 11.0
@export var throw_up_angle_deg: float = 35.0
@export var grab_range: float = 1.5
@export var lift_per_strength: float = 2.0
@export var grabbed_escape_presses: int = 5
@export var grabbed_escape_window: float = 2.0
@export var shove_damage: float = 3.0
@export var shove_stun_time: float = 0.4
# Moved out of PlayerMovement in B-c, when the shove ruling became the
# server's: a number the server judges with is a tuning value, not a constant
# in the client's input handler. Values are the measured ones, unchanged.
@export var shove_cooldown: float = 0.6
@export var shove_range: float = 1.5
@export var shove_half_angle_deg: float = 45.0
# A jumping team mate is reached a little further than a stranger.
@export var shove_ally_bonus: float = 0.3
# Was ESCAPE_PUSH in PlayerGrab. 6-chapter calls it escape_recoil_power and
# suggests 3.0; kept at the measured 4.0 so B-c changes no feel it has not
# measured.
@export var escape_recoil_power: float = 4.0
# B-e: how much faster than the strength-based cap a body may be seen moving
# before the server says so in the log. A sanity bound, not a correction: the
# move check warns and nothing is rolled back.
@export var server_speed_tolerance: float = 1.25
@export var ally_ground_damage: bool = true
@export var ally_ground_stun: bool = true

@export_group("Controls")
# 5-chapter smart key, shared by the jump and the dash (and whatever gets a
# cursor target later). Off: the key shows the range and the landing spot and
# the left button casts. On: the key casts at once.
@export var smart_key_enabled: bool = false

@export_group("Survival")
@export var fall_damage_min_height: float = 4.0
@export var fall_damage_per_meter: float = 8.0
@export var fall_damage_enabled: bool = true
@export var kill_plane_y: float = -20.0
@export var respawn_delay: float = 2.0
