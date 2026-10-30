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
@export var ratio_k_speed: float = 0.30:
	set(value):
		if Tuning.may_write(self):
			ratio_k_speed = value
@export var ratio_mult_min: float = 0.7:
	set(value):
		if Tuning.may_write(self):
			ratio_mult_min = value
@export var ratio_mult_max: float = 1.3:
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
@export var stamina_regen: float = 25.0:
	set(value):
		if Tuning.may_write(self):
			stamina_regen = value
# 6-chapter stamina costs. Dash is the one stage C spends.
@export var stamina_dash_cost: float = 10.0:
	set(value):
		if Tuning.may_write(self):
			stamina_dash_cost = value

@export_group("Vitals")
# H-3: HP and stamina come out of endurance, not out of a stored maximum. HP is
# proportional, so the difference between races lands on how much they take;
# stamina is a base plus a small slice of it, so the same difference barely
# touches how far they move. These three go into the server's HP ruling, so the
# copy that counts is the server's table (Tuning.server, like everything in this
# file since N-1) and the slider is a request, like the abilities. 1.5 puts a human (70) at 105, a
# dwarf (100) at 150, an orc (80) at 120 -- 100 was a placeholder, not a value.
@export var hp_per_endurance: float = 1.5:
	set(value):
		if Tuning.may_write(self):
			hp_per_endurance = value
@export var stamina_base: float = 80.0:
	set(value):
		if Tuning.may_write(self):
			stamina_base = value
@export var stamina_per_endurance: float = 0.3:
	set(value):
		if Tuning.may_write(self):
			stamina_per_endurance = value

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
# 6-chapter stamina costs.
@export var stamina_hold_per_sec: float = 5.0:
	set(value):
		if Tuning.may_write(self):
			stamina_hold_per_sec = value
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
