class_name PhysicsTuning
extends Resource

# Every number a ruling, a trajectory or a cost is built from. Nothing may
# hardcode these: the debug panel edits them live, which is the point of the
# whole exercise. Defaults are the ones written in the work order, section 4.
#
# N-1: this table is the server's. The one live copy on each peer is
# Tuning.server; the server writes its own and pushes it, a client's replica is
# written only by that push. Every setter asks Tuning.may_write, so a client
# that edits its own copy (a slider, a script, a cheat) changes nothing -- the
# slider is a request (Intent.SERVER_TUNING) and the answer comes back pushed.
# The numbers that are a peer's own -- how a press is read, what is drawn --
# live in LocalTuning instead, and nothing judged reads them.

@export_group("Movement")
@export var gravity: float = 22.0:
	set(value):
		if Tuning.may_write(self):
			gravity = value
@export var base_move_speed: float = 6.0:
	set(value):
		if Tuning.may_write(self):
			base_move_speed = value
# T-1b: the steepest ground a body can stand and walk on, degrees from
# flat (CharacterBody3D.floor_max_angle, every body, every tick). Steeper
# is not floor: the body slides down it under gravity. Climbing is the mesh
# walls' (CLIMBABLE layer); terrain is never climbed.
@export var walk_slope_max_deg: float = 40.0:
	set(value):
		if Tuning.may_write(self):
			walk_slope_max_deg = value
# T-1b: ground steeper than walk_slope_max_deg but no steeper than this is
# slid down (State.SLIDING, grounded: no fall is tracked). Steeper than
# this is a face, not ground: a body against it is falling.
@export var slide_max_deg: float = 75.0:
	set(value):
		if Tuning.may_write(self):
			slide_max_deg = value
# The tallest lip a body walks (or rides) straight over, up or down, metres.
# Taller is a wall on the way up and a drop on the way down. 0 turns it off.
@export var step_height: float = 0.3:
	set(value):
		if Tuning.may_write(self):
			step_height = value
# The vertical half of the leap budget: v_cap is built from this and the move
# speed. Since stage C-2 it is not the standing jump's height on its own -- a
# standing jump spends the whole budget upward and goes higher than this.
@export var base_jump_height: float = 1.6:
	set(value):
		if Tuning.may_write(self):
			base_jump_height = value
# Stage C-2: the jump goes to the cursor. Inside this radius the cursor means
# "straight up", which is a hard edge on purpose -- just outside it is the
# lowest hop there is.
@export var jump_inplace_radius: float = 0.8:
	set(value):
		if Tuning.may_write(self):
			jump_inplace_radius = value
# The flattest hop there is: the apex a jump to a cursor right next to the body
# asks for, on level ground.
@export var jump_min_hop_height: float = 0.2:
	set(value):
		if Tuning.may_write(self):
			jump_min_hop_height = value
# How far over a higher landing the arc has to pass. Separate from the hop
# height, which it used to share: lowering the flattest hop was then also
# lowering the clearance over a step, and the two have nothing to do with each
# other.
@export var jump_ledge_margin: float = 0.4:
	set(value):
		if Tuning.may_write(self):
			jump_ledge_margin = value

# 2026-11-17: the jump, the climb and the co-op launch are on hold. Nothing
# was removed: each is behind its switch, and with the switch on it is what
# it was. Off by default.
# The jump: in place, to the cursor, out of a dash, off a ledge (coyote).
@export var jump_enabled: bool = false:
	set(value):
		if Tuning.may_write(self):
			jump_enabled = value
# Taking hold of a wall (from the ground or in the air) and climbing it.
@export var climb_enabled: bool = false:
	set(value):
		if Tuning.may_write(self):
			climb_enabled = value
# The co-op launch: a team mate in the air reached for and sent up at
# shove_ally_launch_angle_deg by a shove or a shield bash. Off, a team mate
# in the air is shoved like anything else, inside the same height band.
@export var coop_launch_enabled: bool = false:
	set(value):
		if Tuning.may_write(self):
			coop_launch_enabled = value
# 2026-11-24 (the user): standing on a monster's back is on hold with them.
# Nothing was removed: the rider table, the stab down and the shake-off all
# ask Wolf.rideable(), which asks this (and wolf_rideable). Off, an enemy is
# not a floor: a body that comes down on one -- the rising cut's leap ends
# over what it cut -- goes off it to a side that is free
# (PlayerMovement._leave_back).
@export var back_ride_enabled: bool = false:
	set(value):
		if Tuning.may_write(self):
			back_ride_enabled = value

@export_group("Strength to weight")
# v4: the ratio a multiplier of 1.0 stands at. A human at training 0, bare, is
# 60 strength over 80 kg = 0.75, so every _base value below is what that human
# gets and every other body is read against it. Before v4 the reference was an
# implicit 1.0, which only made sense while strength was 10 and weight was 10.
@export var ratio_ref: float = 0.75:
	set(value):
		if Tuning.may_write(self):
			ratio_ref = value
@export var ratio_k_jump: float = 0.35:
	set(value):
		if Tuning.may_write(self):
			ratio_k_jump = value
# 2026-11-24 (the user): how high the rising cut's leap takes a body, off the
# same ratio (strength over weight, the weapon's weight in it), on an S curve:
#     height = floor + (ceil - floor) / (1 + e^(-steep x (ratio - centre)))
# The centre is the body the skill is cast by at its plainest -- a human with
# the sword in hand, 60 over 82 = 0.73 (the user, 2026-11-24) -- which lands
# halfway between floor and ceil: 1.99 m, the clip's own leap.
# Tuning.ratio_curve.
@export var rising_cut_lift_floor: float = 1.0:
	set(value):
		if Tuning.may_write(self):
			rising_cut_lift_floor = value
@export var rising_cut_lift_ceil: float = 2.98:
	set(value):
		if Tuning.may_write(self):
			rising_cut_lift_ceil = value
@export var rising_cut_lift_centre: float = 0.73:
	set(value):
		if Tuning.may_write(self):
			rising_cut_lift_centre = value
@export var rising_cut_lift_steep: float = 12.0:
	set(value):
		if Tuning.may_write(self):
			rising_cut_lift_steep = value
@export var ratio_k_speed: float = 0.30:
	set(value):
		if Tuning.may_write(self):
			ratio_k_speed = value
@export var ratio_mult_min: float = 0.7:
	set(value):
		if Tuning.may_write(self):
			ratio_mult_min = value
@export var ratio_mult_max: float = 2.0:
	set(value):
		if Tuning.may_write(self):
			ratio_mult_max = value

@export_group("Dash")
# Stage C-2: the dash is the leap budget spent sideways, and spent fast. Its
# speed is v_cap times this -- strength is already inside v_cap and is not
# applied again -- and it goes as far as the longest jump can, so a dash and a
# running jump cover the same ground at different speeds. The time it takes
# falls out of distance over speed; dash_time_max is gone, because a maximum
# time and a maximum distance cannot both be the limit.
@export var dash_min_distance: float = 1.2:
	set(value):
		if Tuning.may_write(self):
			dash_min_distance = value
@export var dash_speed_mult: float = 2.0:
	set(value):
		if Tuning.may_write(self):
			dash_speed_mult = value
@export var dash_cooldown: float = 1.0:
	set(value):
		if Tuning.may_write(self):
			dash_cooldown = value
# 2026-11-24 (the user): the dash goes out at its full speed and brakes at the
# end: over the last dash_brake_share of its distance the speed falls to
# dash_end_speed of the full one. Never faster than the full speed, so the
# server's dash allowance is unchanged; the dash takes a little longer.
@export var dash_brake_share: float = 0.35:
	set(value):
		if Tuning.may_write(self):
			dash_brake_share = value
@export var dash_end_speed: float = 0.3:
	set(value):
		if Tuning.may_write(self):
			dash_end_speed = value

@export_group("Climb")
@export var climb_speed: float = 2.0:
	set(value):
		if Tuning.may_write(self):
			climb_speed = value
@export var climb_attach_distance: float = 0.6:
	set(value):
		if Tuning.may_write(self):
			climb_attach_distance = value
@export var stamina_climb_drain: float = 15.0:
	set(value):
		if Tuning.may_write(self):
			stamina_climb_drain = value
# 2026-11-24 (the user): a quarter of the 25 it was -- the pool was back
# before a low one could be played or measured.
@export var stamina_regen: float = 6.25:
	set(value):
		if Tuning.may_write(self):
			stamina_regen = value
# 6-chapter stamina costs. Dash is the one stage C spends.
@export var stamina_dash_cost: float = 10.0:
	set(value):
		if Tuning.may_write(self):
			stamina_dash_cost = value

@export_group("Vitals")
# C-1a: HP = vitality x k_hp, stamina = endurance x (1 + stamina_alpha). H-3
# had HP on endurance and stamina as a base plus a slice; the design split the
# ability (2026-11-02). Temporary numbers chosen to land where H-3 did: a
# human is 105 / 101.5, a dwarf 150 / 145, an orc 120 / 116. These go into the
# server's HP ruling, so the copy that counts is Tuning.server and a slider is
# a request.
@export var k_hp: float = 1.5:
	set(value):
		if Tuning.may_write(self):
			k_hp = value
@export var stamina_alpha: float = 0.45:
	set(value):
		if Tuning.may_write(self):
			stamina_alpha = value
# C-1a: an allocated point is worth this much of an ability. Two points a
# level (C-5); the structure is here, the points are all zero.
@export var stat_point_weight: float = 0.5:
	set(value):
		if Tuning.may_write(self):
			stat_point_weight = value

@export_group("Combat")
# C-1a: the damage formula's numbers. Every one is temporary (the tracker's
# blue cells) and lives here so the feel session can move it.
#   damage = coefficient (the skill's '피해' column) x weapon attack
#          x speed/height bonus (C-1b/c) x crit
#   then   max(0, damage - armour x armor_flat_pct) x 100 / (100 + armour)
# Strength plays no part in damage; intellect is recorded and unused.
@export var weapon_attack_sword: float = 10.0:
	set(value):
		if Tuning.may_write(self):
			weapon_attack_sword = value
@export var weapon_attack_shield: float = 6.0:
	set(value):
		if Tuning.may_write(self):
			weapon_attack_shield = value
# Bare hands: 1, so the bare skills' coefficients are the damage itself.
@export var weapon_attack_bare: float = 1.0:
	set(value):
		if Tuning.may_write(self):
			weapon_attack_bare = value
# Armour is gear's alone in the design; there is no gear yet, so these two
# stand in for it on every character and every scarecrow. 0 is "no gear".
@export var armor_player: float = 0.0:
	set(value):
		if Tuning.may_write(self):
			armor_player = value
@export var armor_dummy: float = 0.0:
	set(value):
		if Tuning.may_write(self):
			armor_dummy = value
# The flat part of the armour formula: how much of the armour is taken off
# the attack before the ratio. The handle on how wide the "0 damage" band is.
@export var armor_flat_pct: float = 0.05:
	set(value):
		if Tuning.may_write(self):
			armor_flat_pct = value
# Crit: base chance plus agility above the race's own, times this per point.
# The server rolls it.
@export var crit_base: float = 0.05:
	set(value):
		if Tuning.may_write(self):
			crit_base = value
@export var crit_mult: float = 1.5:
	set(value):
		if Tuning.may_write(self):
			crit_mult = value
@export var crit_per_agility: float = 0.001:
	set(value):
		if Tuning.may_write(self):
			crit_per_agility = value

@export_group("Force")
@export var shove_power: float = 7.0:
	set(value):
		if Tuning.may_write(self):
			shove_power = value
@export var shove_up_bias: float = 0.25:
	set(value):
		if Tuning.may_write(self):
			shove_up_bias = value
@export var grab_range: float = 1.5:
	set(value):
		if Tuning.may_write(self):
			grab_range = value
# v4: 1.2, down from 2.0. A human (60) lifts 72 kg, which is an elf (60) but
# not another human (80) -- being unable to carry your own team mate until you
# have trained is the intended shape, not a rounding accident.
@export var lift_per_strength: float = 1.2:
	set(value):
		if Tuning.may_write(self):
			lift_per_strength = value
# Stage E. One hand on a weapon halves what the other can lift.
@export var grab_one_hand_strength_mult: float = 2.0:
	set(value):
		if Tuning.may_write(self):
			grab_one_hand_strength_mult = value
@export var one_hand_weapon: bool = false:
	set(value):
		if Tuning.may_write(self):
			one_hand_weapon = value
# A full charge throws an arc this far, or a straight line this fast.
@export var throw_arc_max_range_base: float = 10.0:
	set(value):
		if Tuning.may_write(self):
			throw_arc_max_range_base = value
@export var throw_line_power_base: float = 12.0:
	set(value):
		if Tuning.may_write(self):
			throw_line_power_base = value
# The straight throw's own ratio cap. Its ratio is strength over the rock's
# weight -- a bare human against a 5 kg rock is 12 -- so the shared
# ratio_mult_max (2.0) sent a hand-height flat throw over a 1.8 m head at 3 m.
# Same formula, same min; only the top of the clamp is this.
@export var throw_line_mult_max: float = 1.3:
	set(value):
		if Tuning.may_write(self):
			throw_line_mult_max = value
# 6-chapter stamina costs. C-1b': the hold's own drain is the grab's
# stamina column (grab_stamina, per second while lifting); stamina_hold_per_sec
# was a second copy of the same number and is gone.
@export var stamina_charge_per_sec: float = 8.0:
	set(value):
		if Tuning.may_write(self):
			stamina_charge_per_sec = value
@export var stamina_escape_press: float = 3.0:
	set(value):
		if Tuning.may_write(self):
			stamina_escape_press = value
@export var grabbed_escape_presses: int = 5:
	set(value):
		if Tuning.may_write(self):
			grabbed_escape_presses = value
@export var grabbed_escape_window: float = 2.0:
	set(value):
		if Tuning.may_write(self):
			grabbed_escape_window = value
@export var shove_damage: float = 3.0:
	set(value):
		if Tuning.may_write(self):
			shove_damage = value
@export var shove_stun_time: float = 0.4:
	set(value):
		if Tuning.may_write(self):
			shove_stun_time = value
# Moved out of PlayerMovement in B-c, when the shove ruling became the
# server's: a number the server judges with is a tuning value, not a constant
# in the client's input handler. Values are the measured ones, unchanged.
@export var shove_cooldown: float = 0.6:
	set(value):
		if Tuning.may_write(self):
			shove_cooldown = value
# Stage D: the shove is a rectangle in front of the cursor heading, not a fan.
# shove_half_angle_deg and shove_ally_bonus are gone with the fan.
@export var shove_range: float = 1.5:
	set(value):
		if Tuning.may_write(self):
			shove_range = value
@export var shove_width: float = 1.2:
	set(value):
		if Tuning.may_write(self):
			shove_width = value
# What the pusher takes back, as a share of what it gave out.
@export var shove_recoil: float = 0.3:
	set(value):
		if Tuning.may_write(self):
			shove_recoil = value
# A team mate already in the air is launched rather than shoved: the push tilts
# up by this much, which is what makes one player a step for another.
@export var shove_ally_launch_angle_deg: float = 50.0:
	set(value):
		if Tuning.may_write(self):
			shove_ally_launch_angle_deg = value
# 4-chapter. k_push scales the push by the pusher's strength against the
# target's weight. It used to borrow ratio_k_jump, which is the jump's number
# and had no business here. v4 deleted the term that let the target's own
# strength hold part of the push back: strength buys the tolerance below now,
# not a shorter distance.
@export var k_push: float = 0.35:
	set(value):
		if Tuning.may_write(self):
			k_push = value
# v4's knockback tolerance. The threshold a body's own strength buys it, in
# metres per second of horizontal dv: under it the body slides and holds its
# ground, over it the body is launched. 0.12 is the work order's placeholder --
# a human (60) tolerates 7.2 m/s -- and whether it is the right one is a
# feel-check question, not something to tune here.
@export var tolerance_per_strength: float = 0.12:
	set(value):
		if Tuning.may_write(self):
			tolerance_per_strength = value
# How much upward speed a launch gets at the least, so that being launched is
# always leaving the ground rather than a fast slide that happens to be called
# one.
@export var launch_min_up_speed: float = 2.0:
	set(value):
		if Tuning.may_write(self):
			launch_min_up_speed = value
# A force aimed this steeply upward is a lift, not knockback, and is not put
# through the tolerance at all: a body being thrown or sprung off the ground
# has nothing to hold its ground against. Below it the comparison applies.
@export var knock_lift_angle_deg: float = 60.0:
	set(value):
		if Tuning.may_write(self):
			knock_lift_angle_deg = value
# How long a body may stand on another body's head before sliding off it.
@export var head_stomp_time: float = 0.5:
	set(value):
		if Tuning.may_write(self):
			head_stomp_time = value
# 4-chapter says a push on the ground becomes the body's velocity. The ground
# step writes the horizontal back to the move order every frame, so without a
# window of its own a ground push is gone before it is seen: the recoil moved
# a pusher four centimetres and the escape recoil moved nobody at all. For
# this long after a force lands, the push is what the body is doing.
@export var force_slide_time: float = 0.25:
	set(value):
		if Tuning.may_write(self):
			force_slide_time = value
@export var force_slide_friction: float = 6.0:
	set(value):
		if Tuning.may_write(self):
			force_slide_friction = value
# The playground is all field, so there is no party system to ask. This is the
# toggle the work order asks for in the debug panel: with it on, the other
# player counts as a team mate.
@export var same_party: bool = true:
	set(value):
		if Tuning.may_write(self):
			same_party = value
# Was ESCAPE_PUSH in PlayerGrab. 6-chapter calls it escape_recoil_power and
# suggests 3.0; kept at the measured 4.0 so B-c changes no feel it has not
# measured.
@export var escape_recoil_power: float = 4.0:
	set(value):
		if Tuning.may_write(self):
			escape_recoil_power = value
# B-e: how much faster than the strength-based cap a body may be seen moving
# before the server says so in the log. A sanity bound, not a correction: the
# move check warns and nothing is rolled back.
@export var server_speed_tolerance: float = 1.25:
	set(value):
		if Tuning.may_write(self):
			server_speed_tolerance = value
@export var ally_ground_damage: bool = true:
	set(value):
		if Tuning.may_write(self):
			ally_ground_damage = value
@export var ally_ground_stun: bool = true:
	set(value):
		if Tuning.may_write(self):
			ally_ground_stun = value

@export_group("Skills")
# M-1/M-2: the strikes the slots cast. Each SkillDef with tuning_prefix set
# reads its numbers from here (<prefix>_windup, _recovery, _cooldown, _range,
# _width, _damage, _power), so these sliders are the skill. The punch is
# quick and light; the kick is slow, heavier and knocks down.
@export var punch_windup: float = 0.1:
	set(value):
		if Tuning.may_write(self):
			punch_windup = value
@export var punch_recovery: float = 0.2:
	set(value):
		if Tuning.may_write(self):
			punch_recovery = value
@export var punch_cooldown: float = 0.0:
	set(value):
		if Tuning.may_write(self):
			punch_cooldown = value
@export var punch_range: float = 1.3:
	set(value):
		if Tuning.may_write(self):
			punch_range = value
@export var punch_width: float = 0.6:
	set(value):
		if Tuning.may_write(self):
			punch_width = value
@export var punch_damage: float = 2.0:
	set(value):
		if Tuning.may_write(self):
			punch_damage = value
@export var punch_power: float = 2.0:
	set(value):
		if Tuning.may_write(self):
			punch_power = value
# C-1a: the '스태미나' column, temporary. Carried on the SkillDef; nothing
# spends it until C-1d (the bare four) and C-1b (the sword's).
@export var punch_stamina: float = 3.0:
	set(value):
		if Tuning.may_write(self):
			punch_stamina = value
@export var kick_windup: float = 0.25:
	set(value):
		if Tuning.may_write(self):
			kick_windup = value
@export var kick_recovery: float = 0.4:
	set(value):
		if Tuning.may_write(self):
			kick_recovery = value
@export var kick_cooldown: float = 0.8:
	set(value):
		if Tuning.may_write(self):
			kick_cooldown = value
@export var kick_range: float = 1.6:
	set(value):
		if Tuning.may_write(self):
			kick_range = value
@export var kick_width: float = 0.9:
	set(value):
		if Tuning.may_write(self):
			kick_width = value
@export var kick_damage: float = 5.0:
	set(value):
		if Tuning.may_write(self):
			kick_damage = value
@export var kick_power: float = 5.0:
	set(value):
		if Tuning.may_write(self):
			kick_power = value
@export var kick_stamina: float = 7.0:
	set(value):
		if Tuning.may_write(self):
			kick_stamina = value
# The shove's and the grab's (per second while lifting), same column.
@export var shove_stamina: float = 6.0:
	set(value):
		if Tuning.may_write(self):
			shove_stamina = value
@export var grab_stamina: float = 2.0:
	set(value):
		if Tuning.may_write(self):
			grab_stamina = value
# M-7: the catch. How long before an attack lands a grab counts as catching it,
# what the catcher's strength is measured against (attack catch_force times
# this), and how long the caught attacker is held still.
@export var catch_window: float = 0.3:
	set(value):
		if Tuning.may_write(self):
			catch_window = value
@export var catch_power_mult: float = 1.0:
	set(value):
		if Tuning.may_write(self):
			catch_power_mult = value
@export var catch_stun: float = 1.0:
	set(value):
		if Tuning.may_write(self):
			catch_stun = value
# M-7: the scarecrow's attack pattern, a stand-in for a boss swing: every
# period seconds a windup it shows, then a strike in front of it. Off by
# default -- the earlier stages stand bodies beside scarecrows for minutes.
# catch_force is large on purpose: a bare human cannot catch it, a trained
# one can.
# 2026-11-22: the sword scarecrow (SwordDummy): cuts when a person is
# within dummy_sword_approach, rests dummy_sword_rest between cuts.
@export var dummy_sword_enabled: bool = true:
	set(value):
		if Tuning.may_write(self):
			dummy_sword_enabled = value
# 2026-11-23 (the user: they are for trying the guard): a sword scarecrow is
# a post in the ground -- a blow takes its HP and shows, and moves it nowhere.
@export var dummy_sword_anchored: bool = true:
	set(value):
		if Tuning.may_write(self):
			dummy_sword_anchored = value
@export var dummy_sword_approach: float = 2.6:
	set(value):
		if Tuning.may_write(self):
			dummy_sword_approach = value
@export var dummy_sword_rest: float = 1.0:
	set(value):
		if Tuning.may_write(self):
			dummy_sword_rest = value
@export var dummy_sword_windup: float = 0.8:
	set(value):
		if Tuning.may_write(self):
			dummy_sword_windup = value
@export var dummy_sword_recovery: float = 0.6:
	set(value):
		if Tuning.may_write(self):
			dummy_sword_recovery = value
@export var dummy_sword_cooldown: float = 0.0:
	set(value):
		if Tuning.may_write(self):
			dummy_sword_cooldown = value
@export var dummy_sword_range: float = 2.2:
	set(value):
		if Tuning.may_write(self):
			dummy_sword_range = value
@export var dummy_sword_angle: float = 100.0:
	set(value):
		if Tuning.may_write(self):
			dummy_sword_angle = value
@export var dummy_sword_damage: float = 8.0:
	set(value):
		if Tuning.may_write(self):
			dummy_sword_damage = value
@export var dummy_sword_power: float = 4.0:
	set(value):
		if Tuning.may_write(self):
			dummy_sword_power = value
# 2026-11-22: the pitching machines (PitchingMachine): every pitch_period
# at the nearest person in its lane within pitch_range, shown for pitch_windup, thrown at
# pitch_speed on the low arc.
@export var pitch_enabled: bool = true:
	set(value):
		if Tuning.may_write(self):
			pitch_enabled = value
@export var pitch_period: float = 5.0:
	set(value):
		if Tuning.may_write(self):
			pitch_period = value
@export var pitch_windup: float = 0.8:
	set(value):
		if Tuning.may_write(self):
			pitch_windup = value
@export var pitch_range: float = 10.0:
	set(value):
		if Tuning.may_write(self):
			pitch_range = value
# 2026-11-23 (the user): a machine never turns -- it throws straight down its
# own lane, at someone standing in it: ahead of it within pitch_range and no
# further than this to either side of its line (m; the machines stand 3 m
# apart, so 1.5 keeps one lane to one machine).
@export var pitch_lane_half_width: float = 1.5:
	set(value):
		if Tuning.may_write(self):
			pitch_lane_half_width = value
@export var pitch_speed: float = 14.0:
	set(value):
		if Tuning.may_write(self):
			pitch_speed = value
@export var dummy_attack_enabled: bool = false:
	set(value):
		if Tuning.may_write(self):
			dummy_attack_enabled = value
@export var dummy_attack_period: float = 4.0:
	set(value):
		if Tuning.may_write(self):
			dummy_attack_period = value
@export var dummy_attack_windup: float = 0.8:
	set(value):
		if Tuning.may_write(self):
			dummy_attack_windup = value
@export var dummy_attack_recovery: float = 0.5:
	set(value):
		if Tuning.may_write(self):
			dummy_attack_recovery = value
@export var dummy_attack_cooldown: float = 0.0:
	set(value):
		if Tuning.may_write(self):
			dummy_attack_cooldown = value
@export var dummy_attack_range: float = 1.8:
	set(value):
		if Tuning.may_write(self):
			dummy_attack_range = value
@export var dummy_attack_width: float = 1.4:
	set(value):
		if Tuning.may_write(self):
			dummy_attack_width = value
@export var dummy_attack_damage: float = 10.0:
	set(value):
		if Tuning.may_write(self):
			dummy_attack_damage = value
@export var dummy_attack_power: float = 8.0:
	set(value):
		if Tuning.may_write(self):
			dummy_attack_power = value
@export var dummy_attack_catch_force: float = 120.0:
	set(value):
		if Tuning.may_write(self):
			dummy_attack_catch_force = value
# C-1b: a scarecrow's HP. Was a constant 60; 300 so a stage can measure a
# run of sword blows (the thrust's speed bonus) before the mark refills.
@export var dummy_max_hp: float = 300.0:
	set(value):
		if Tuning.may_write(self):
			dummy_max_hp = value
# M-2: how long a knocked-down body lies, and how long standing up takes.
# No input through either; pushes still land.
@export var down_time: float = 1.0:
	set(value):
		if Tuning.may_write(self):
			down_time = value
@export var getup_time: float = 0.3:
	set(value):
		if Tuning.may_write(self):
			getup_time = value

@export_group("Sword")
# C-1b: the sword's four, the tracker's '기술 표' rows as sliders (every
# number there is a temporary blue cell). A SkillDef with tuning_prefix
# "thrust" reads thrust_windup, _recovery, _cooldown, _range, _width,
# _damage (the coefficient on weapon_attack_sword), _power, _stamina,
# _angle (the range shape's fan, until C-1g-c) and _arc_deg (C-1g-a: the
# swing's arc, which the ruling, the picture and the trail share).
# The thrust: 2026-11-21: its windup, swing and recovery and the body's path are the
# clip's own (SkillDef "Motion", baked); these two are how fast the clip runs
# (1 = its own speed) and how far its path goes across the ground (1 = the
# clip's).
@export var thrust_motion_speed: float = 1.0:
	set(value):
		if Tuning.may_write(self):
			thrust_motion_speed = value
@export var thrust_motion_reach: float = 1.0:
	set(value):
		if Tuning.may_write(self):
			thrust_motion_reach = value
# 2026-11-21: the thrust's clip ends in a pause, not the stance: after it the
# body steps back into the stance over this long, the front foot kept.
@export var thrust_motion_return: float = 0.3:
	set(value):
		if Tuning.may_write(self):
			thrust_motion_return = value
@export var thrust_cooldown: float = 0.0:
	set(value):
		if Tuning.may_write(self):
			thrust_cooldown = value
@export var thrust_range: float = 2.86:
	set(value):
		if Tuning.may_write(self):
			thrust_range = value
@export var thrust_width: float = 0.5:
	set(value):
		if Tuning.may_write(self):
			thrust_width = value
@export var thrust_damage: float = 1.0:
	set(value):
		if Tuning.may_write(self):
			thrust_damage = value
# 2026-11-23 (the user): the blade goes in, so the one hit barely moves: 3.0 -> 0.5.
@export var thrust_power: float = 0.5:
	set(value):
		if Tuning.may_write(self):
			thrust_power = value
@export var thrust_stamina: float = 8.0:
	set(value):
		if Tuning.may_write(self):
			thrust_stamina = value
# The thrust's speed bonus: damage x (1 + this x horizontal speed at the
# intent / base_move_speed), the speed as the server saw it.
@export var thrust_speed_bonus: float = 0.3:
	set(value):
		if Tuning.may_write(self):
			thrust_speed_bonus = value
# 2026-11-23 (the user): a thrust that lands stays in. For this long after
# the blade is through (seconds) another sword key cuts straight out of it
# (SkillDef.combo_branches); the thrust's own key, or nothing by the end of
# it, pulls the blade out (thrust_pull), which cuts again on the way.
@export var thrust_combo_auto_after: float = 0.45:
	set(value):
		if Tuning.may_write(self):
			thrust_combo_auto_after = value
# The pull is the thrust's own way back into the stance (the front foot
# kept, over thrust_pull_motion_return) with a blow at its start: its own
# damage (x attack power, as the thrust's), push and cost; reach and width
# are the thrust's.
@export var thrust_pull_motion_return: float = 0.3:
	set(value):
		if Tuning.may_write(self):
			thrust_pull_motion_return = value
@export var thrust_pull_damage: float = 0.5:
	set(value):
		if Tuning.may_write(self):
			thrust_pull_damage = value
@export var thrust_pull_power: float = 0.0:
	set(value):
		if Tuning.may_write(self):
			thrust_pull_power = value
@export var thrust_pull_stamina: float = 0.0:
	set(value):
		if Tuning.may_write(self):
			thrust_pull_stamina = value
@export var thrust_pull_cooldown: float = 0.0:
	set(value):
		if Tuning.may_write(self):
			thrust_pull_cooldown = value
@export var thrust_pull_speed_bonus: float = 0.0:
	set(value):
		if Tuning.may_write(self):
			thrust_pull_speed_bonus = value
# 2026-11-23 (the user): the stab down, the thrust's key while standing on a
# monster's back (data/skills/back_stab.tres): it lands on that monster only
# and is always a crit. _damage is x attack power, as the thrust's.
@export var back_stab_windup: float = 0.35:
	set(value):
		if Tuning.may_write(self):
			back_stab_windup = value
@export var back_stab_recovery: float = 0.6:
	set(value):
		if Tuning.may_write(self):
			back_stab_recovery = value
@export var back_stab_damage: float = 1.5:
	set(value):
		if Tuning.may_write(self):
			back_stab_damage = value
@export var back_stab_power: float = 0.0:
	set(value):
		if Tuning.may_write(self):
			back_stab_power = value
@export var back_stab_stamina: float = 8.0:
	set(value):
		if Tuning.may_write(self):
			back_stab_stamina = value
@export var back_stab_cooldown: float = 0.0:
	set(value):
		if Tuning.may_write(self):
			back_stab_cooldown = value
# 2026-11-18: the thrust's second step (the push kick): its own windup and
# recovery; every other number is the kick's.
@export var thrust_2_windup: float = 0.45:
	set(value):
		if Tuning.may_write(self):
			thrust_2_windup = value
@export var thrust_2_recovery: float = 0.4:
	set(value):
		if Tuning.may_write(self):
			thrust_2_recovery = value
# The side cut, both steps (the second falls back on these): 2026-11-21: its windup, swing and recovery and the body's path are the
# clip's own (SkillDef "Motion", baked); these two are how fast the clip runs
# (1 = its own speed) and how far its path goes across the ground (1 = the
# clip's).
@export var side_cut_motion_speed: float = 1.0:
	set(value):
		if Tuning.may_write(self):
			side_cut_motion_speed = value
@export var side_cut_motion_reach: float = 1.0:
	set(value):
		if Tuning.may_write(self):
			side_cut_motion_reach = value
# 2026-11-21 (the user: the last step's after-swing is too long): the second
# step's way back runs this many times faster (its clip's is 1.52 s -> 0.61).
# 2026-11-21 (the user: the first step's is too long as well): 1.37 s -> 0.55.
@export var side_cut_motion_recovery_speed: float = 2.5:
	set(value):
		if Tuning.may_write(self):
			side_cut_motion_recovery_speed = value
@export var side_cut_2_motion_recovery_speed: float = 2.5:
	set(value):
		if Tuning.may_write(self):
			side_cut_2_motion_recovery_speed = value
@export var side_cut_cooldown: float = 0.0:
	set(value):
		if Tuning.may_write(self):
			side_cut_cooldown = value
@export var side_cut_range: float = 2.34:
	set(value):
		if Tuning.may_write(self):
			side_cut_range = value
# The '폭' column: a horizontal fan this wide, in degrees. Since C-1g-a only
# the range shape on the ground reads it (RangeShapes, via shape_angle_deg);
# the ruling is the sweep below. C-1g-c points the shape at the arc too.
@export var side_cut_angle: float = 120.0:
	set(value):
		if Tuning.may_write(self):
			side_cut_angle = value
# C-1g-a: the side cut's swing, degrees of horizontal arc centred on the
# heading (240 = 120 to each side). The server sweeps the blade through it
# over arc_duration and a body is hit when the blade reaches its bearing;
# the swing drawn on every screen and its trail turn through the same arc.
@export var side_cut_arc_deg: float = 240.0:
	set(value):
		if Tuning.may_write(self):
			side_cut_arc_deg = value
@export var side_cut_damage: float = 1.2:
	set(value):
		if Tuning.may_write(self):
			side_cut_damage = value
@export var side_cut_power: float = 4.0:
	set(value):
		if Tuning.may_write(self):
			side_cut_power = value
@export var side_cut_stamina: float = 10.0:
	set(value):
		if Tuning.may_write(self):
			side_cut_stamina = value
# 2026-11-18 (the user's rule): the next step is asked for while the step
# before it is still going -- any time from its press to the end of its
# recovery -- and then follows the moment its blade is through, with no
# recovery and no return to standing in between. combo_window is how long
# AFTER a step has ended a press still counts: 0, so a press that comes late
# starts over at the first step. combo_grace is what the server adds to the
# late side on its own clock (the press's trip over the wire) and
# combo_early_slack to the early side (a step may arrive this much before the
# server's own clock says the blade is through).
@export var combo_window: float = 0.0:
	set(value):
		if Tuning.may_write(self):
			combo_window = value
# 2026-11-21 (the user's rule, replacing "to the end of its recovery"): the
# next step is taken only from a press up to this long after the step's
# blade is through; a press later in the recovery does nothing.
@export var combo_press_after_swing: float = 0.2:
	set(value):
		if Tuning.may_write(self):
			combo_press_after_swing = value
@export var combo_grace: float = 0.3:
	set(value):
		if Tuning.may_write(self):
			combo_grace = value
@export var combo_early_slack: float = 0.06:
	set(value):
		if Tuning.may_write(self):
			combo_early_slack = value
# 2026-11-19: 0.25 -> 0.18, the light overhead cut (the user: a one-handed
# sword should cut lightly): the sword is drawn back beside the shoulder in
# this, not lifted over the head.
@export var overhead_cut_windup: float = 0.18:
	set(value):
		if Tuning.may_write(self):
			overhead_cut_windup = value
@export var overhead_cut_recovery: float = 0.4:
	set(value):
		if Tuning.may_write(self):
			overhead_cut_recovery = value
@export var overhead_cut_cooldown: float = 0.0:
	set(value):
		if Tuning.may_write(self):
			overhead_cut_cooldown = value
@export var overhead_cut_range: float = 2.34:
	set(value):
		if Tuning.may_write(self):
			overhead_cut_range = value
# The blade's thickness across the heading, for the narrow rectangle on the
# ground and the sideways tolerance of the hit. Not in the table (its '폭' is
# the vertical angle below); 0.4 chosen here.
@export var overhead_cut_width: float = 0.4:
	set(value):
		if Tuning.may_write(self):
			overhead_cut_width = value
# C-1g-a: the overhead cut's swing, degrees of vertical arc from straight
# up (arc_start_deg 90) down and forward: 120 ends 30 below horizontal. The
# server sweeps the blade through it and a body whose vertical span the
# blade crosses, inside overhead_cut_width across, is hit. Replaces the C-1b
# vertical fan (overhead_cut_vertical_angle 40).
@export var overhead_cut_arc_deg: float = 120.0:
	set(value):
		if Tuning.may_write(self):
			overhead_cut_arc_deg = value
# C-1g-a: how much wider the ruling's arc may be than the arc the model
# actually draws (C-1g-b measures the clips). ruling >= drawn - margin, and
# ruling <= drawn + margin. A check reads it; nothing is clamped by it.
@export var swing_arc_margin_deg: float = 20.0:
	set(value):
		if Tuning.may_write(self):
			swing_arc_margin_deg = value
@export var overhead_cut_damage: float = 1.4:
	set(value):
		if Tuning.may_write(self):
			overhead_cut_damage = value
@export var overhead_cut_power: float = 3.0:
	set(value):
		if Tuning.may_write(self):
			overhead_cut_power = value
@export var overhead_cut_stamina: float = 10.0:
	set(value):
		if Tuning.may_write(self):
			overhead_cut_stamina = value
# 2026-11-19: the dash cut, in the sword's third slot. The windup is the
# crouch with the hand at the hip; the body then covers the skill's
# step_distance (3 m) in its swing (0.12 s). The ruling is one rectangle at the
# end of the windup, from where the body crouched: the 3 m it is about to
# cross and a blade's length past them.
@export var dash_cut_windup: float = 0.35:
	set(value):
		if Tuning.may_write(self):
			dash_cut_windup = value
@export var dash_cut_recovery: float = 0.45:
	set(value):
		if Tuning.may_write(self):
			dash_cut_recovery = value
@export var dash_cut_cooldown: float = 1.5:
	set(value):
		if Tuning.may_write(self):
			dash_cut_cooldown = value
@export var dash_cut_range: float = 4.0:
	set(value):
		if Tuning.may_write(self):
			dash_cut_range = value
@export var dash_cut_width: float = 1.0:
	set(value):
		if Tuning.may_write(self):
			dash_cut_width = value
@export var dash_cut_damage: float = 1.4:
	set(value):
		if Tuning.may_write(self):
			dash_cut_damage = value
@export var dash_cut_power: float = 3.0:
	set(value):
		if Tuning.may_write(self):
			dash_cut_power = value
@export var dash_cut_stamina: float = 12.0:
	set(value):
		if Tuning.may_write(self):
			dash_cut_stamina = value
# The parry: no windup, the recovery is what a failed one costs, the window
# is how long after the press an attack landing on this body is turned. The
# attacker is stunned until its own recovery would have ended. Agility is
# not connected to the window yet (the design says so).
@export var parry_windup: float = 0.0:
	set(value):
		if Tuning.may_write(self):
			parry_windup = value
@export var parry_recovery: float = 0.4:
	set(value):
		if Tuning.may_write(self):
			parry_recovery = value
@export var parry_cooldown: float = 1.0:
	set(value):
		if Tuning.may_write(self):
			parry_cooldown = value
# No parry_range: the parry has no distance condition (C-1b', the user's
# call); the resource's reach is a note, not a rule.
@export var parry_angle: float = 90.0:
	set(value):
		if Tuning.may_write(self):
			parry_angle = value
@export var parry_stamina: float = 6.0:
	set(value):
		if Tuning.may_write(self):
			parry_stamina = value
@export var parry_window: float = 0.25:
	set(value):
		if Tuning.may_write(self):
			parry_window = value
# 2026-11-22: the sword's held block (sword_guard). Front angle; the share of
# a blocked blow's damage that still lands (the rest is stamina,
# block_stamina_mult); the perfect window after the press (mastery 1: no
# damage, no push, the attacker held; mastery 2: thrown things sent back).
@export var sword_guard_angle: float = 60.0:
	set(value):
		if Tuning.may_write(self):
			sword_guard_angle = value
@export var sword_guard_damage_taken: float = 0.15:
	set(value):
		if Tuning.may_write(self):
			sword_guard_damage_taken = value
# 2026-11-22: walking with a guard up, times the walk (the sword's: still).
@export var sword_guard_move_mult: float = 0.0:
	set(value):
		if Tuning.may_write(self):
			sword_guard_move_mult = value
@export var shield_raise_move_mult: float = 0.6:
	set(value):
		if Tuning.may_write(self):
			shield_raise_move_mult = value
# 2026-11-22 (the user: too hard): 0.2 -> 0.4.
@export var sword_guard_perfect_window: float = 0.4:
	set(value):
		if Tuning.may_write(self):
			sword_guard_perfect_window = value
# A perfect guard's stamina: this share of what a plain block of the same
# blow costs (the user, 2026-11-22: it blocks everything, at a small price).
@export var guard_perfect_stamina_share: float = 0.3:
	set(value):
		if Tuning.may_write(self):
			guard_perfect_stamina_share = value
# The heaviest thrown thing a guard sends back; heavier ones are blocked.
# 2026-11-23 (the user: sending a ball back was too easy on the perfect
# guard's 0.4): a thrown thing is sent back only inside this long after the
# press (the blow's perfect guard keeps its own window).
@export var sword_guard_reflect_window: float = 0.3:
	set(value):
		if Tuning.may_write(self):
			sword_guard_reflect_window = value
# 2026-11-24 (the user): the heaviest thing sent back goes by strength, off
# the lift formula: lift_limit x this share (a human's 60 x 1.2 x 0.14 = 10 kg).
@export var guard_reflect_lift_share: float = 0.14:
	set(value):
		if Tuning.may_write(self):
			guard_reflect_lift_share = value
# The sword's guard cannot be raised again for this long after it comes
# down (the shield's is shield_raise_recovery): a perfect window per raise
# is not a window per key press.
# 2026-11-23 (the user): once raised, the sword's guard stays up at least
# this long: a key let go sooner brings it down then, and no other skill is
# cast out of it before (a guard is a commitment, not a tap). A perfect guard
# frees it at once -- its counter and its sure crit follow straight away.
@export var sword_guard_min_hold: float = 0.6:
	set(value):
		if Tuning.may_write(self):
			sword_guard_min_hold = value
@export var sword_guard_recovery: float = 0.4:
	set(value):
		if Tuning.may_write(self):
			sword_guard_recovery = value
# 2026-11-22 (the user): a blow perfectly guarded is deflected past the
# guard's left side: the attacker is drawn on that way at guard_deflect_pull
# (and held guard_perfect_stun). A thrown thing sent back is knocked away.
# 2026-11-22 (the user): 0 by default -- held only, not drawn (no deflect
# motion for now, so a pull would not read).
@export var guard_deflect_pull: float = 0.0:
	set(value):
		if Tuning.may_write(self):
			guard_deflect_pull = value
# 2026-11-22 (the user): the counter after a perfect guard of a blow (SkillDef
# guard_counter_skill; a thrown thing perfectly guarded does not open it): open this long from the ruling (+ combo_grace on the
# server, for the press's trip). The counter cut itself reads side_cut_* for
# what it does not set here. 2026-11-22 (the user): its damage back to the
# side cut's 1.2 -- a perfect guard's sure crit (guard_crit_window) is the
# reward now, for any attack.
@export var guard_counter_window: float = 0.6:
	set(value):
		if Tuning.may_write(self):
			guard_counter_window = value
@export var counter_cut_damage: float = 1.2:
	set(value):
		if Tuning.may_write(self):
			counter_cut_damage = value
@export var counter_cut_power: float = 5.0:
	set(value):
		if Tuning.may_write(self):
			counter_cut_power = value
@export var counter_cut_motion_recovery_speed: float = 2.5:
	set(value):
		if Tuning.may_write(self):
			counter_cut_motion_recovery_speed = value
# 2026-11-22 (the user): after a perfect guard, the guard's next attack cast
# within this many seconds (+ combo_grace) is a sure crit on the attacker it
# guarded -- on that one body only; spent at the cast, hit or miss.
@export var guard_crit_window: float = 1.0:
	set(value):
		if Tuning.may_write(self):
			guard_crit_window = value
# How long a perfect guard holds the attacker still, whatever its blow was
# (the user, 2026-11-22: one time for all).
@export var guard_perfect_stun: float = 0.8:
	set(value):
		if Tuning.may_write(self):
			guard_perfect_stun = value
# 2026-11-20: the rising cut, in the dash cut's slot (the user's call).
# 2026-11-21: its first blow is the first pass of Attack_Combo_03_03; a
# horizontal sweep (temporary: the sweep is level; the blade's own rise is
# the clip's).
@export var rising_cut_cooldown: float = 0.0:
	set(value):
		if Tuning.may_write(self):
			rising_cut_cooldown = value
@export var rising_cut_range: float = 2.34:
	set(value):
		if Tuning.may_write(self):
			rising_cut_range = value
@export var rising_cut_angle: float = 120.0:
	set(value):
		if Tuning.may_write(self):
			rising_cut_angle = value
@export var rising_cut_arc_deg: float = 180.0:
	set(value):
		if Tuning.may_write(self):
			rising_cut_arc_deg = value
@export var rising_cut_damage: float = 1.5:
	set(value):
		if Tuning.may_write(self):
			rising_cut_damage = value
@export var rising_cut_power: float = 5.0:
	set(value):
		if Tuning.may_write(self):
			rising_cut_power = value
@export var rising_cut_stamina: float = 12.0:
	set(value):
		if Tuning.may_write(self):
			rising_cut_stamina = value
# The rising cut (2026-11-22: Attack_Rising; m2 = the dive from the top of
# the leap at mastery 2, which falls back on these where it has none of its
# own): its windup, swing and recovery and the body's path are the clip's own
# (SkillDef "Motion", baked); these two are how fast the clip runs (1 = its
# own speed) and how far its path goes across the ground (1 = the clip's).
@export var rising_cut_motion_speed: float = 1.0:
	set(value):
		if Tuning.may_write(self):
			rising_cut_motion_speed = value
@export var rising_cut_motion_reach: float = 1.0:
	set(value):
		if Tuning.may_write(self):
			rising_cut_motion_reach = value
# 2026-11-22: the dive (rising_cut_m2) lands in a disc: its radius, and how
# far ahead of the body its centre is (0 = round the body).
@export var rising_cut_m2_radius: float = 2.0:
	set(value):
		if Tuning.may_write(self):
			rising_cut_m2_radius = value
@export var rising_cut_m2_range: float = 0.0:
	set(value):
		if Tuning.may_write(self):
			rising_cut_m2_range = value
# 2026-11-24 (the user): from the dive's mastered_level (2) its disc is this
# wide instead, and a body it hits is held still this long (the stun a
# perfect guard uses; not through a guard, not on a party member).
@export var rising_cut_m2_radius_mastered: float = 3.0:
	set(value):
		if Tuning.may_write(self):
			rising_cut_m2_radius_mastered = value
@export var rising_cut_m2_stun: float = 1.0:
	set(value):
		if Tuning.may_write(self):
			rising_cut_m2_stun = value
# 2026-11-20: every body's mastery of every skill, until mastery is earned
# (Mastery.level_of). The server's number: which form a skill is cast in is a
# ruling. 0 = every skill in its first form. Ships at the top (5) since
# 2026-11-21, the user's call: every form open while the skills are tried.
@export var mastery_debug_level: int = 5:
	set(value):
		if Tuning.may_write(self):
			mastery_debug_level = value

@export_group("Dash combo")
# C-1d: a combo skill (dash_combo on the SkillDef: the punch, the thrust,
# the shield bash) pressed within dash_combo_window of the owner's dash
# start is stronger, linearly: x dash_combo_mult_max at a gap of 0, x1 at
# the window. The gap is the owner's own input interval, sent with the
# intent (the work order: no latency compensation). The server also times
# the arrival of the dash notice and the skill intent and refuses a claimed
# gap shorter than that arrival gap minus combo_jitter_allow: a cheat check,
# not a correction.
@export var dash_combo_window: float = 0.15:
	set(value):
		if Tuning.may_write(self):
			dash_combo_window = value
@export var dash_combo_mult_max: float = 1.3:
	set(value):
		if Tuning.may_write(self):
			dash_combo_mult_max = value
@export var combo_jitter_allow: float = 0.05:
	set(value):
		if Tuning.may_write(self):
			combo_jitter_allow = value

@export_group("Shield")
# C-1c: the shield's four, the tracker's rows as sliders. The raise is a
# window, not a strike: up after raise_time, posture 0 -> 100% from then to
# posture_time; a blow from the front costs no HP and (blocked damage x
# block_stamina_mult) stamina; the push is judged against a tolerance raised
# by the posture (block_tolerance_mult, temporary); at 0 stamina the shield
# drops and cannot be raised until the pool is back to block_recover_fraction
# of its maximum (temporary).
@export var shield_raise_time: float = 0.2:
	set(value):
		if Tuning.may_write(self):
			shield_raise_time = value
@export var shield_posture_time: float = 0.6:
	set(value):
		if Tuning.may_write(self):
			shield_posture_time = value
@export var shield_raise_recovery: float = 0.1:
	set(value):
		if Tuning.may_write(self):
			shield_raise_recovery = value
@export var shield_raise_angle: float = 180.0:
	set(value):
		if Tuning.may_write(self):
			shield_raise_angle = value
# 2026-11-24 (the user): 3, from 0.5 -- at 0.5 a thrust guarded cost 4 of a
# pool of 100 and a guard never ran out of it.
@export var block_stamina_mult: float = 3.0:
	set(value):
		if Tuning.may_write(self):
			block_stamina_mult = value
# 2026-11-24 (the user), for trying a guard the pool cannot pay for: every
# body's stamina held at debug_stamina_pin_value (no regen above it, a cost
# is back the next step), and a broken guard's lockout lifted at once.
@export var debug_stamina_pin: bool = false:
	set(value):
		if Tuning.may_write(self):
			debug_stamina_pin = value
@export var debug_stamina_pin_value: float = 3.0:
	set(value):
		if Tuning.may_write(self):
			debug_stamina_pin_value = value
@export var block_tolerance_mult: float = 1.0:
	set(value):
		if Tuning.may_write(self):
			block_tolerance_mult = value
@export var block_recover_fraction: float = 0.25:
	set(value):
		if Tuning.may_write(self):
			block_recover_fraction = value
@export var shield_bash_windup: float = 0.15:
	set(value):
		if Tuning.may_write(self):
			shield_bash_windup = value
@export var shield_bash_recovery: float = 0.4:
	set(value):
		if Tuning.may_write(self):
			shield_bash_recovery = value
@export var shield_bash_cooldown: float = 1.0:
	set(value):
		if Tuning.may_write(self):
			shield_bash_cooldown = value
@export var shield_bash_range: float = 1.5:
	set(value):
		if Tuning.may_write(self):
			shield_bash_range = value
@export var shield_bash_width: float = 1.4:
	set(value):
		if Tuning.may_write(self):
			shield_bash_width = value
@export var shield_bash_damage: float = 0.5:
	set(value):
		if Tuning.may_write(self):
			shield_bash_damage = value
@export var shield_bash_power: float = 9.0:
	set(value):
		if Tuning.may_write(self):
			shield_bash_power = value
@export var shield_bash_stamina: float = 12.0:
	set(value):
		if Tuning.may_write(self):
			shield_bash_stamina = value
@export var shield_throw_windup: float = 0.3:
	set(value):
		if Tuning.may_write(self):
			shield_throw_windup = value
@export var shield_throw_recovery: float = 0.5:
	set(value):
		if Tuning.may_write(self):
			shield_throw_recovery = value
@export var shield_throw_cooldown: float = 0.0:
	set(value):
		if Tuning.may_write(self):
			shield_throw_cooldown = value
# The '사거리' column: how far the flat throw lands from the hand. The speed
# is derived from it and the hand's height under gravity, not a number of its own.
@export var shield_throw_range: float = 8.0:
	set(value):
		if Tuning.may_write(self):
			shield_throw_range = value
@export var shield_throw_width: float = 0.5:
	set(value):
		if Tuning.may_write(self):
			shield_throw_width = value
@export var shield_throw_damage: float = 0.8:
	set(value):
		if Tuning.may_write(self):
			shield_throw_damage = value
@export var shield_throw_power: float = 6.0:
	set(value):
		if Tuning.may_write(self):
			shield_throw_power = value
@export var shield_throw_stamina: float = 10.0:
	set(value):
		if Tuning.may_write(self):
			shield_throw_stamina = value
# The thrown shield as a body: its weight (not in the table; temporary).
@export var shield_weight: float = 5.0:
	set(value):
		if Tuning.may_write(self):
			shield_weight = value
@export var shield_slam_windup: float = 0.3:
	set(value):
		if Tuning.may_write(self):
			shield_slam_windup = value
@export var shield_slam_recovery: float = 0.5:
	set(value):
		if Tuning.may_write(self):
			shield_slam_recovery = value
@export var shield_slam_cooldown: float = 1.5:
	set(value):
		if Tuning.may_write(self):
			shield_slam_cooldown = value
@export var shield_slam_range: float = 1.3:
	set(value):
		if Tuning.may_write(self):
			shield_slam_range = value
@export var shield_slam_radius: float = 1.0:
	set(value):
		if Tuning.may_write(self):
			shield_slam_radius = value
@export var shield_slam_damage: float = 1.5:
	set(value):
		if Tuning.may_write(self):
			shield_slam_damage = value
@export var shield_slam_power: float = 5.0:
	set(value):
		if Tuning.may_write(self):
			shield_slam_power = value
@export var shield_slam_stamina: float = 14.0:
	set(value):
		if Tuning.may_write(self):
			shield_slam_stamina = value
# +20% damage per metre fallen by the time it lands (the server's own record
# of the caster's peak), temporary.
@export var shield_slam_height_bonus: float = 0.2:
	set(value):
		if Tuning.may_write(self):
			shield_slam_height_bonus = value

@export_group("Weapon variants")
# Weapons as bodies in the hand, and the family members' multipliers
# (WeaponDef.tuning_prefix names these; data/weapons/*.tres holds the same
# defaults). All temporary. A weapon's weight rides the body while it is in a
# hand (CharacterStats.weapon_weight); the shield's is shield_weight above.
# 2026-11-19: what a body has in its main hand when it arrives, as a
# WeaponKinds.Kind number (0 nothing, 1 the sword). The server writes it at
# the spawn, where the race may hold it; a body is no longer bare-handed
# until it finds a rack. An automated run starts bare whatever this says
# (Player._ready): the checks were written from empty hands.
@export var start_weapon: int = 1:
	set(value):
		if Tuning.may_write(self):
			start_weapon = value
@export var sword_weight: float = 2.0:
	set(value):
		if Tuning.may_write(self):
			sword_weight = value
# The great sword: the sword's four with the blade and every reach x this,
# every windup x that.
@export var great_sword_reach_mult: float = 1.25:
	set(value):
		if Tuning.may_write(self):
			great_sword_reach_mult = value
@export var great_sword_windup_mult: float = 1.15:
	set(value):
		if Tuning.may_write(self):
			great_sword_windup_mult = value
@export var great_sword_weight: float = 4.0:
	set(value):
		if Tuning.may_write(self):
			great_sword_weight = value
# The great shield: the shield's four with the raise's angle x block_mult
# (capped at a full turn) and the bash's width x width_mult.
@export var great_shield_block_mult: float = 1.25:
	set(value):
		if Tuning.may_write(self):
			great_shield_block_mult = value
@export var great_shield_width_mult: float = 1.25:
	set(value):
		if Tuning.may_write(self):
			great_shield_width_mult = value
@export var great_shield_weight: float = 8.0:
	set(value):
		if Tuning.may_write(self):
			great_shield_weight = value

@export_group("Survival")
@export var fall_damage_min_height: float = 4.0:
	set(value):
		if Tuning.may_write(self):
			fall_damage_min_height = value
@export var fall_damage_per_meter: float = 8.0:
	set(value):
		if Tuning.may_write(self):
			fall_damage_per_meter = value
@export var fall_damage_enabled: bool = true:
	set(value):
		if Tuning.may_write(self):
			fall_damage_enabled = value
# Stage G: whether the landing damage from a fall a party member caused -- a
# throw or a shove -- is allowed to be the death of you. The damage is taken
# either way (the co-op launch is a finisher with a price); this only decides
# whether it may reach zero, and off it leaves 1 HP. Nothing to do with the
# cliff: going out of the world kills whoever put you there.
@export var ally_fall_death: bool = false:
	set(value):
		if Tuning.may_write(self):
			ally_fall_death = value
@export var kill_plane_y: float = -20.0:
	set(value):
		if Tuning.may_write(self):
			kill_plane_y = value
@export var respawn_delay: float = 2.0:
	set(value):
		if Tuning.may_write(self):
			respawn_delay = value

@export_group("Mount")
# Riding, first pass (movement only). The summon and the linger are the
# server's clocks; the horse's size is the collider every peer judges with.
# Seconds from the key to sitting on the horse.
@export var mount_summon_time: float = 1.0:
	set(value):
		if Tuning.may_write(self):
			mount_summon_time = value
# Seconds the horse stands where the rider got off before it is gone.
@export var mount_linger_time: float = 3.0:
	set(value):
		if Tuning.may_write(self):
			mount_linger_time = value
# The horse, nose to tail, and the height of its back, in metres.
@export var mount_length: float = 2.2:
	set(value):
		if Tuning.may_write(self):
			mount_length = value
@export var mount_back_height: float = 1.5:
	set(value):
		if Tuning.may_write(self):
			mount_back_height = value
@export var mount_width: float = 0.7:
	set(value):
		if Tuning.may_write(self):
			mount_width = value
# The mounted collider: an upright capsule this wide (radius), from the
# ground to the rider's head. The horse's length is not in the collision.
@export var mount_radius: float = 0.6:
	set(value):
		if Tuning.may_write(self):
			mount_radius = value
# How far above the horse's back the rider's body centre sits, per unit of
# the rider's own scale. Sets the picture and the top of the collider.
@export var mount_seat_above: float = 0.25:
	set(value):
		if Tuning.may_write(self):
			mount_seat_above = value
# The horse's top speed: this times the walk of a bare level-1 human
# (Player.get_mount_speed). Nothing about the rider changes it.
@export var mount_speed_mult: float = 2.31:
	set(value):
		if Tuning.may_write(self):
			mount_speed_mult = value
# Seconds from standing to the top speed, and from the top speed to a stop.
@export var mount_accel_time: float = 0.8:
	set(value):
		if Tuning.may_write(self):
			mount_accel_time = value
# Seconds from the top speed to a stop.
@export var mount_decel_time: float = 0.5:
	set(value):
		if Tuning.may_write(self):
			mount_decel_time = value
# How fast the horse turns, degrees a second. It moves where it faces.
@export var mount_turn_deg: float = 180.0:
	set(value):
		if Tuning.may_write(self):
			mount_turn_deg = value
# The horse slows while it is not facing where it was sent. Up to this many
# degrees off it keeps its full speed; from here to a quarter turn the speed
# eases down (a cosine), to mount_turn_min_ratio of the top at 90 and beyond.
@export var mount_turn_slow_deg: float = 0.0:
	set(value):
		if Tuning.may_write(self):
			mount_turn_slow_deg = value
# The least the misalignment may cut the speed to, as a share of the top
# speed. 0 turns on the spot past a quarter turn. The arc limit (no faster
# than a turn at mount_turn_deg can still reach the next path point) stays.
@export var mount_turn_min_ratio: float = 0.0:
	set(value):
		if Tuning.may_write(self):
			mount_turn_min_ratio = value
# Floor snap while riding, metres: keeps the body on a downhill at speed.
@export var mount_floor_snap: float = 0.5:
	set(value):
		if Tuning.may_write(self):
			mount_floor_snap = value
# The same horse scaled for a race whose data says large_mount (the orc).
@export var mount_large_scale: float = 1.3:
	set(value):
		if Tuning.may_write(self):
			mount_large_scale = value

@export_group("Wolf")
# 늑대 a: one wolf. Every number is temporary (the work order's table) and
# the server's. Metres from the wolf at which it notices a living player.
@export var wolf_aggro_range: float = 12.0:
	set(value):
		if Tuning.may_write(self):
			wolf_aggro_range = value
# Metres from where it started at which it gives up and walks back.
@export var wolf_leash_range: float = 25.0:
	set(value):
		if Tuning.may_write(self):
			wolf_leash_range = value
# Metres to the target at which it stops and winds up the bite.
@export var wolf_bite_start_range: float = 2.7:
	set(value):
		if Tuning.may_write(self):
			wolf_bite_start_range = value
# The bite (data/skills/wolf_bite.tres, tuning_prefix wolf_bite): _range is
# how far it leaps, and with _width the path the telegraph shows and the
# judge rules; _damage is the HP itself (bare, coefficient x 1).
@export var wolf_bite_range: float = 3.2:
	set(value):
		if Tuning.may_write(self):
			wolf_bite_range = value
@export var wolf_bite_width: float = 1.4:
	set(value):
		if Tuning.may_write(self):
			wolf_bite_width = value
@export var wolf_bite_windup: float = 0.5:
	set(value):
		if Tuning.may_write(self):
			wolf_bite_windup = value
@export var wolf_bite_recovery: float = 0.8:
	set(value):
		if Tuning.may_write(self):
			wolf_bite_recovery = value
# A blow in the windup breaks the bite when its power (the force event's) is
# at least this: 0 is every blow. Per species -- a bear's will be high.
@export var wolf_interrupt_power: float = 0.0:
	set(value):
		if Tuning.may_write(self):
			wolf_interrupt_power = value
# How long it stands after a broken bite before it may wind up again.
@export var wolf_interrupt_pause: float = 0.8:
	set(value):
		if Tuning.may_write(self):
			wolf_interrupt_pause = value
# 2026-11-23 (the user): the flinch. Every blow that does not throw the body
# (a knockback skill's held slide included) stops its legs for flinch_time and,
# when the blow itself moved nothing, the body steps back flinch_slide metres
# along the blow on its own legs -- the same for every weight (a hit
# reaction's root motion, not a push: the force door is not touched).
@export var flinch_time: float = 0.25:
	set(value):
		if Tuning.may_write(self):
			flinch_time = value
@export var flinch_slide: float = 0.2:
	set(value):
		if Tuning.may_write(self):
			flinch_slide = value
@export var wolf_bite_damage: float = 8.0:
	set(value):
		if Tuning.may_write(self):
			wolf_bite_damage = value
# Seconds the leap itself takes (the path's length over this is its speed).
@export var wolf_lunge_time: float = 0.2:
	set(value):
		if Tuning.may_write(self):
			wolf_lunge_time = value
# Its run, times the walk of a bare level-1 human; its stroll while idle.
@export var wolf_run_speed_mult: float = 1.2:
	set(value):
		if Tuning.may_write(self):
			wolf_run_speed_mult = value
# Walking home after giving up: this times its run.
@export var wolf_return_speed_mult: float = 1.5:
	set(value):
		if Tuning.may_write(self):
			wolf_return_speed_mult = value
@export var wolf_walk_speed_mult: float = 0.3:
	set(value):
		if Tuning.may_write(self):
			wolf_walk_speed_mult = value
# Idle: how far from its mark it strolls, and how long it stands between.
@export var wolf_wander_radius: float = 3.0:
	set(value):
		if Tuning.may_write(self):
			wolf_wander_radius = value
@export var wolf_wander_pause: float = 2.0:
	set(value):
		if Tuning.may_write(self):
			wolf_wander_pause = value
# The body: what a push divides by and the lift limit weighs; the strength
# that buys its knockback tolerance (x tolerance_per_strength); its HP.
# 2026-11-23 (the user: twice the size, an early zone's monster): 40 kg / 45
# / 35 HP -> 100 kg (between a human's 80 and an orc's 140), 65 (a human's
# 60), 50 HP. The bite's damage stays (strength is not in it).
@export var wolf_weight: float = 100.0:
	set(value):
		if Tuning.may_write(self):
			wolf_weight = value
@export var wolf_strength: float = 65.0:
	set(value):
		if Tuning.may_write(self):
			wolf_strength = value
# 2026-11-23: the body's size, which was three constants in wolf.gd (0.35 /
# 1.3 / 0.5), now twice that. A capsule on its side: _body_radius is its
# radius (the height of its back is twice that), _body_length its length
# nose to tail; _hit_radius is what the judge's shapes add for this body
# (between its half width and its half length). The collider, the picture,
# the carcass and the height it is put down at all read these; a body
# already in the world keeps the size it was built with until the game is
# started again. The bite's distances above went up with it (2.0 / 2.5 /
# 1.0 -> 2.7 / 3.2 / 1.4: the same gap from the nose to the target).
@export var wolf_body_radius: float = 0.7:
	set(value):
		if Tuning.may_write(self):
			wolf_body_radius = value
@export var wolf_body_length: float = 2.6:
	set(value):
		if Tuning.may_write(self):
			wolf_body_length = value
@export var wolf_hit_radius: float = 1.0:
	set(value):
		if Tuning.may_write(self):
			wolf_hit_radius = value
@export var wolf_max_hp: float = 50.0:
	set(value):
		if Tuning.may_write(self):
			wolf_max_hp = value
# Seconds a carcass lies before it is gone.
@export var wolf_corpse_time: float = 30.0:
	set(value):
		if Tuning.may_write(self):
			wolf_corpse_time = value
# 2026-11-23 (the user: standing on a big wolf's back is worth keeping): a
# species whose back can be stood on. The server keeps who is on whose back
# (ServerAuthority.rider_mount); what hangs off that -- the stab down, the
# shake-off, its own bite passing its rider by -- reads the same table.
@export var wolf_rideable: bool = true:
	set(value):
		if Tuning.may_write(self):
			wolf_rideable = value
# 2026-11-23 (the user): the shake-off, a monster's answer to a body on its
# back. Once someone has been on it _after seconds it stands and shakes for
# _windup (shown on every screen), then everyone on its back is thrown off:
# a force event like any other, _power strong, aimed _angle degrees up and
# out to the side (past knock_lift_angle_deg, so it is a lift: it always
# throws). It then stands _recovery before it does anything else.
@export var wolf_shake_after: float = 3.0:
	set(value):
		if Tuning.may_write(self):
			wolf_shake_after = value
@export var wolf_shake_windup: float = 0.5:
	set(value):
		if Tuning.may_write(self):
			wolf_shake_windup = value
# (Measured 2026-11-23 at 6 / 70 deg: an 80 kg body went 0.31 m up and 1.7 m
# aside, still over the back 0.6 s later. 10 / 65 deg throws it clear.)
@export var wolf_shake_power: float = 10.0:
	set(value):
		if Tuning.may_write(self):
			wolf_shake_power = value
@export var wolf_shake_angle: float = 65.0:
	set(value):
		if Tuning.may_write(self):
			wolf_shake_angle = value
@export var wolf_shake_recovery: float = 0.5:
	set(value):
		if Tuning.may_write(self):
			wolf_shake_recovery = value
# Seconds after its death until it is back on its mark.
@export var wolf_respawn_time: float = 60.0:
	set(value):
		if Tuning.may_write(self):
			wolf_respawn_time = value
