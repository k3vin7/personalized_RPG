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
# the left button casts. On: the key casts at once. On by default
# (2026-11-03, was off).
@export var smart_key_enabled: bool = true
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
# 0.5 / 1.0 (was 1.0 / 1.5, 2026-11-02): half a second decides, the next half
# second fills the charge, and a key held longer stays at full charge in the
# throw pose until it is let go.
@export var throw_hold_threshold: float = 0.5
@export var throw_charge_max: float = 1.0
# The dash key, as a physical keycode. Default Space (2026-11-17, was Shift,
# before that C; Shift is left empty); any key from the debug panel, the way
# the slot keys are. Written into the InputMap's "dash" action by
# PlayerMovement.apply_dash_binding().
@export var dash_key: int = KEY_SPACE
# The jump key, its own value since 2026-11-17 (it was Space in the project's
# input map). Empty while the jump is on hold; any key from the debug panel.
# Written into the InputMap's "jump" action by apply_jump_binding(). Getting
# out of a hold is Space whatever this is (PlayerMovement.ESCAPE_KEY).
@export var jump_key: int = 0
# The horse: one key summons and mounts, the same key gets off. Default Z;
# any key from the debug panel. Written into the InputMap's "mount" action
# by PlayerMovement.apply_mount_binding().
@export var mount_key: int = KEY_Z

@export_group("Slots")
# M-1: the eight slot keys, as physical keycodes, in slot order. Defaults
# Q W E R A S D F; any key can be put on any slot from the debug panel.
@export var slot_keys: PackedInt32Array = PackedInt32Array([81, 87, 69, 82, 65, 83, 68, 70])

@export_group("Camera")
# C-1g-e: the scroll zoom, all drawn, nothing judged. camera_zoom is the
# level (1 = the far quarter view as it was, 0 = nearest); the wheel moves it
# by camera_zoom_step and the view eases after it at camera_zoom_smoothing.
# Distance and tilt interpolate together: at 1, camera_distance at
# camera_pitch_deg (18 m, 55 deg, the values QuarterCamera carried as
# constants until now); at 0, camera_near_mult x the distance at
# camera_near_pitch_deg (9 m lying down at 35 deg). No rotation.
# 2026-11-17: the zoom is set by how much ground shows across the middle of
# the screen. At the camera's 40 degree fov on a 16:9 view that is 1.294 x
# the distance, so 50 m across is 38.64 m away (zoom 1), 20 m across is
# 0.4 of that (zoom 0), and the default 40 m across is zoom 2/3. The tilt
# still runs between the same two angles.
# 2026-11-17 (later): the game starts nine wheel steps in from the far end,
# zoom 0.1 -- 17.77 m away at 37 deg, about 23 m of ground across. The far
# end (zoom 1) is where it was.
# 2026-11-18: the middle button's three stops, on the user's word that the
# near one hardly came closer (16.6 m against the default 17.8) and the far
# one went too far (38.6 m). The nearest the view can go is now 0.2 of the
# distance (7.7 m; it was 0.4, 15.5 m), and the near and far stops are their
# own numbers, in metres from the body: 10.5 and 27. The view the game starts
# at is the same one -- 17.77 m away at 37 degrees -- which on the new scale
# is zoom 0.325 with the near tilt at 28.33 degrees.
@export var camera_zoom: float = 0.325
@export var camera_distance: float = 38.64
@export var camera_pitch_deg: float = 55.0
@export var camera_near_mult: float = 0.2
@export var camera_near_pitch_deg: float = 28.3333
@export var camera_stop_near_m: float = 10.5
@export var camera_stop_far_m: float = 27.0
@export var camera_zoom_step: float = 0.1
@export var camera_zoom_smoothing: float = 10.0
# 2026-11-17: looking around. F2 lets go of the body and the arrow keys slide
# the view over the ground at this many metres a second (Shift: three times
# that); F2 again goes back to the body. Drawn only.
@export var camera_pan_speed: float = 40.0
# 2026-11-17, a trial: degrees the view turns about the body for one notch
# of the wheel. (The wheel no longer zooms; the middle button steps the zoom.)
@export var camera_turn_step_deg: float = 15.0

@export_group("Interior")
# 건물 진입 a: inside a building, on this screen only. How many metres of
# ground stay lit outside each door (the rest of the outside is black), how
# strong the light in each doorway is, and how long the change takes. All
# three are stand-in values.
@export var interior_door_glimpse: float = 3.0
@export var interior_door_light: float = 2.0
@export var interior_fade_time: float = 0.3
# The daylight inside, as a share of what it is outside; and the torches on
# the posts and the candles on the tables: how strong, and how far they reach.
@export var interior_brightness: float = 0.6
@export var interior_torch_energy: float = 1.5
@export var interior_torch_range: float = 5.0
@export var interior_candle_energy: float = 0.6
@export var interior_candle_range: float = 2.5

@export_group("Model")
# 2026-11-06: which gait the model draws for a moving body. Drawn only; the
# body's speed is the server's. The walk clip is the default picture: the run
# clip shows once the measured pace passes visual_run_speed, and comes back to
# the walk once it drops under visual_walk_back_speed (a band, so a replica's
# eased position does not flicker across one line). 9 / 7 m/s against the
# 6 m/s base move speed: a plain body walks, a boosted one (ratio multiplier
# up to 2.0) runs. Until 2026-11-06 the two were 2.5 / 1.2 in code, so every
# body ran. visual_stride_max caps how fast a gait clip may be played to
# match the body's pace (the walk clip's own pace is about 1 m/s, so at 6 m/s
# it plays at this cap and the feet slide).
# 2026-11-18: the run is the default gait again (the user's call): 2.5 / 1.2,
# so the 6 m/s base pace runs and the walk shows only on a slow body.
@export var visual_run_speed: float = 2.5
@export var visual_walk_back_speed: float = 1.2
@export var visual_stride_max: float = 2.0
# 2026-11-18: how far the model bends forward at the waist through a thrust
# (and the kick that follows it), degrees. The clip itself stands upright
# with the hand at chest height; bent, the blade goes in at the middle of a
# body and a little further out. Drawn only.
@export var visual_thrust_lean_deg: float = 25.0
# 2026-11-18: how much of the overhead cut clip's own forward bend is taken
# back out, 0 (the clip as it is: chest 98 degrees forward at the end) to 1
# (the chest kept upright throughout). Drawn only.
@export var visual_chop_straighten: float = 0.6

@export_group("Swing feel")
# 2026-11-19: what a swing does whether or not it lands. All drawn or heard
# on this screen only. swing_sound_db under -60 is silence; the kick is how
# far the view is pushed the way the blow goes and how long it takes to come
# back.
@export var swing_feel_enabled: bool = true
@export var swing_sound_db: float = -6.0
@export var swing_kick_m: float = 0.08
@export var swing_kick_time: float = 0.14

@export_group("Guard feel")
# 2026-11-22: a perfect guard's picture starts this far into its clip (the
# ruling comes at the touch, so the clip's first frames would be late), and
# holds still this long first (the touch felt).
@export var guard_anim_lead: float = 0.0
@export var guard_hitstop: float = 0.0
# 2026-11-22 (the user): a sword guard pressed with a blow due within its
# perfect window plus this (seconds) shows the deflect at once, at the press.
@export var guard_foresight_slack: float = 0.15
# 2026-11-22 (the user): the blade's glow while a perfect guard's sure crit
# waits (Player._show_crit_glow), added over the blade's own colour.
@export var guard_crit_glow_colour: Color = Color(1.0, 0.75, 0.2, 0.6)
# 2026-11-23 (the user: "너무 조그맣게 빛남"): the glow is a shell grown this
# far out of the blade's surface (m), plus a light of this reach (m, 0 = none)
# and strength around the weapon.
@export_range(0.0, 0.2, 0.005) var guard_crit_glow_grow: float = 0.05
@export_range(0.0, 5.0, 0.1) var guard_crit_glow_light_range: float = 2.0
@export_range(0.0, 8.0, 0.1) var guard_crit_glow_light_energy: float = 2.5

# 2026-11-23 (the user): the body the cursor is on (the one a skill will be
# aimed at, PlayerMovement.hovered_body) is drawn with a rim this colour and
# this wide (m, out of its surface). Off: no rim; the aim is the same.
@export var hover_outline_enabled: bool = true
@export var hover_outline_colour: Color = Color(1.0, 0.25, 0.15, 1.0)
@export_range(0.005, 0.1, 0.005) var hover_outline_width: float = 0.03

@export_group("Terrain")
# T-1b: a client's terrain collision is a patch around its own body
# (Terrain3D DYNAMIC_GAME; the server builds the whole region). Metres of
# radius, and the size of each shape. Drawn/physics-local only: the server
# rules on its own full collision.
@export var terrain_collision_radius: float = 64.0
@export var terrain_collision_shape_size: float = 16.0

@export_group("Hit feedback")
# C-0: the hit feedback set (결정 #79). All drawn, none judged: a peer that
# turns these to zero sees nothing different happen to anyone. Six sliders and
# a master switch, as the work order asks, for the feel session.
@export var hit_feedback_enabled: bool = true
# Render frames the swing (and the body hit) hold still on contact. 2 to 4.
@export var hitstop_frames: int = 3
# Seconds the body that was hit shows white.
@export var hit_flash_time: float = 0.12
# Specks out of the point of contact.
@export var hit_particle_count: int = 12
# The sound hook: a stream dropped into HitFeedback's player plays here.
@export var hit_sound_enabled: bool = true
# Camera shake, big swings and launches only: metres of jitter, and for how long.
@export var camera_shake_amp: float = 0.12
@export var camera_shake_time: float = 0.18
# How long the damage number floats before it is gone.
@export var damage_number_time: float = 0.8
