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
# The dash key, as a physical keycode. Default Shift (2026-11-03, was C);
# any key from the debug panel, the way the slot keys are. Written into the
# InputMap's "dash" action by PlayerMovement.apply_dash_binding().
@export var dash_key: int = KEY_SHIFT

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
@export var camera_zoom: float = 1.0
@export var camera_distance: float = 18.0
@export var camera_pitch_deg: float = 55.0
@export var camera_near_mult: float = 0.5
@export var camera_near_pitch_deg: float = 35.0
@export var camera_zoom_step: float = 0.1
@export var camera_zoom_smoothing: float = 10.0

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
