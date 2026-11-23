class_name CharacterVisual
extends Node3D

# C-1f-2: the one layer between a body and whatever model is drawn for it.
# The capsule, the collider, the race scale the judge reads, the swing pivot,
# the trail and every ruling stay in Player; this node only draws. A model
# swap (KayKit now, the real art later) happens here and nowhere else.
#
# The glTF files are read at run time through GLTFDocument rather than the
# editor's import pipeline, so a headless harness on a machine that never
# opened the editor sees the same skeleton, clips and clip lengths the player
# does. Each file is parsed once per process and shared.
#
# Animation is a picture: a clip is chosen from the body's state every frame,
# and an attack clip is sped up to fit the skill's windup + active time
# (never the other way round). Nothing here is read by a ruling.
#
# Model profiles (2026-11-06): everything that belongs to one pack -- its
# files, its height, the clip for each picture, the stride paces -- is one
# entry of PROFILES. DEFAULT_PROFILE is the model every peer draws;
# `--model=<name>` on the command line picks another for one process, and a
# test can call use_profile(). Rolling back to KayKit is DEFAULT_PROFILE.

const PACK := "res://assets/placeholder/kaykit_adventurers/KayKit_Adventurers_2.0_FREE/"
const TRIPO := "res://assets/characters/tripo_human/"
const FBX := "res://assets/characters_fbx/"
const DRAW := FBX + "Pro Sword and Shield Pack/"
const SS := DRAW + "sword and shield "
# The user's own one-handed sword (2026-11-19), in place of the KayKit one.
const SWORD_PATH := FBX + "one hand sword/tripo_convert_8c06890a-718d-415e-b5ec-41cfaa3a632b.fbx"
const SHIELD_PATH := PACK + "Assets/gltf/shield_round.gltf"
# 2026-11-20: the one-handed sword pack's own mannequin, played on its own
# bone names with no retarget, exactly as the preview plays it
# (scenes/tests/sword_animset_preview.tscn). Read through the editor's import
# (tools/sword_animset/setup_import.gd), not at run time: the import is what
# turns the clip files' bones into bones and reads them at their 60 fps.
const MANNEQUIN := FBX + "onehandedsword_asset/"

# Both rigs carry these two slot bones (the Tripo rig gets them in
# tools/blender/tripo_human_build.py): the slot's +Y is where a held prop
# points, so a weapon hangs the same way off either model.
const HAND_BONE := "handslot.r"
const OFFHAND_BONE := "handslot.l"

# "height": the model's own units from the floor to the top of the head
# (KayKit: the helmet, ignoring the visor spike; Tripo: measured 0.9995 in
# Blender and 1.000 in Godot's AABB). The model is scaled so that height is
# the capsule's height, so a race's height shows as model scale.
# "walk_speed"/"run_speed": the pace the clip's planted foot slides at, in
# m/s at the human capsule (1.8 m). KayKit's were set by eye in C-1f-2;
# Tripo's were measured by the build script in model units (walk 0.582,
# run_looped 1.942 per second) and multiplied by the human scale 1.8.
# "clips": the clip for each picture, "" when the pack has none -- then the
# picture before it stays on screen (nothing is substituted).
const PROFILES := {
	# 임시 캐릭터 a (2026-11-17): no model. The body is Player's capsule and
	# the floating hands (PlayerHands); nothing is loaded and every call into
	# this node does nothing. `--model=tripo` (or kaykit) draws a model again.
	"none": {
		"model": "",
		"clip_files": [],
		"height": 1.0,
		"yaw": 0.0,
		"bones": 0,
		"walk_speed": 1.0,
		"run_speed": 1.0,
		"dash_speed": 1.0,
		"clips": {},
		"looping": [],
	},
	# 2026-11-20: the sword pack's mannequin (the user's call: the default,
	# the others still a button away on the debug panel). Everything that
	# would be a measurement is read off the model and the clips when they
	# load instead of written here:
	#   "height" 0: floor to the top of the meshes, in the model's units.
	#   "yaw_from": the heel and the ball of one foot in the rest pose; the
	#     model is turned so that line points the way the body faces.
	#   walk/run pace: the clip's own root travel per second.
	"mannequin": {
		"model": MANNEQUIN + "Armature.fbx",
		# Through load(), the editor's import (see MANNEQUIN).
		"imported": true,
		"library": MANNEQUIN + "onehandedsword_library.res",
		"height": 0.0,
		"yaw": 0.0,
		"yaw_from": ["foot_r", "ball_r"],
		"bones": 74,
		# Where the sword hangs: the pack's own weapon bone. Its +X runs along
		# the blade and its Y across the guard (the pack's sword measured
		# 2026-11-20: 1.54 long along +X from just behind the grip, the guard
		# 0.25 along Z of its file, which sits on Weapon_R's Y). A prop's -Z is
		# its blade and its X its guard, so: X -> +Y, Y -> -Z, Z -> -X.
		"hand_bone": "Weapon_R",
		"offhand_bone": "weapon_L",
		"grip_basis": Basis(Vector3(0.0, 1.0, 0.0), Vector3(0.0, 0.0, -1.0), Vector3(-1.0, 0.0, 0.0)),
		# The bone the pack moves the whole body by (root motion).
		"root_bone": "root",
		# 2026-11-21: the legs the feet are held by (foot_lock_modifier.gd):
		# hip, knee, foot. A profile without them holds no feet.
		# The fourth, the ball of the foot, says when the foot is down.
		"leg_bones": {"l": ["thigh_l", "calf_l", "foot_l", "ball_l"], "r": ["thigh_r", "calf_r", "foot_r", "ball_r"]},
		# For the debug recorder.
		"named_bones": {"hand": "hand_r", "hips": "pelvis"},
		"walk_speed": 1.0,
		"run_speed": 3.0,
		"dash_speed": 1.0,
		# Clips out of the library, by the name used here. "source" is the
		# library's "<Folder>.<File>". "travel" as for the Mixamo clips, on
		# the root bone: the body does the walking. "renames": bone names put
		# right on the way in (Attack_Sprint calls its weapon bone "Weapom_R",
		# so the sword did not follow it; the user's call: fix the name only).
		"library_clips": {
			"m_idle": {"source": "InPlace.Idle"},
			"m_walk": {"source": "RootPlace.Walk_F", "travel": "ramp"},
			"m_run": {"source": "RootPlace.Run_F", "travel": "ramp"},
			"m_sprint": {"source": "RootPlace.Sprint", "travel": "ramp"},
			"m_jump": {"source": "RootPlace.Jump_In", "travel": "pin"},
			"m_fall": {"source": "InPlace.Jump_Loop"},
			"m_hit": {"source": "RootPlace.Hit_01_F", "travel": "pin"},
			"m_dead": {"source": "RootPlace.Dead", "travel": "pin"},
			"m_weak": {"source": "InPlace.Weak_01_loop_01"},
			"m_block_in": {"source": "InPlace.Block_In"},
			"m_block": {"source": "InPlace.Block_Hold"},
			# 2026-11-22 (the user's picks off renders): the perfect guard is
			# Block_CounterAttacks up to where the blade has knocked the blow
			# up and aside (0.5 s; its counter-cut after that is left out); a
			# blow on the guard Block_Hit; a guard broken (the pool at 0)
			# Block_Breach.
			"m_guard_perfect": {"source": "InPlace.Block_CounterAttacks", "to": 0.5},
			"m_guard_hit": {"source": "InPlace.Block_Hit"},
			# 2026-11-22 (the user): the deflect -- from Block_Hold (left foot
			# 0.3 m ahead, right foot 0.3 m behind, the blade to the left) the
			# whole body turns counter-clockwise from above about the right
			# foot, so the left foot goes back past the right one and the body
			# faces left-forward, the blade swinging round to the left-back
			# (_twist_pose "pivot"). 55 deg puts the left foot ~0.3 m behind.
			# 2026-11-22 (the user): the left foot steps first, at once, back and
			# to the right -- 0.5 m behind the right foot, the leg out behind to
			# brace -- over 0.15 s (a backward walk's left step, Walk_B); 0.1 s
			# in, the body turns about the right foot and the blade sweeps to
			# the left-back over 0.25 s, the planted foot staying put; held,
			# then all back over the last 0.2 s.
			"m_guard_deflect": {"compose": [
				{"clip": "InPlace.Block_Hold", "to": 0.6,
					"twist": {"pivot": 65.0, "pivot_foot": "foot_r", "delay": 0.05, "in": 0.25, "out": 0.2,
						"sink": 0.07, "yaw": 15.0, "head": -45.0,
						"arm_r": {"at": [0.05, 0.6, 0.35], "blade": [-0.75, -0.6, -0.15]},
						"arm_l": {"at": [-0.15, 0.35, 0.3]},
						"step": "l", "foot_in": 0.15, "step_target": [0.2, 0.4],
						"step_clip": "RootPlace.Walk_B", "step_from": 0.9, "step_to": 2.0}},
			]},
			"m_guard_break": {"source": "RootPlace.Block_Breach", "travel": "pin"},
			# 2026-11-21: "travel": "body" -- the skills these play have their
			# path baked off them (SkillDef "Motion", tools/sword_animset/
			# bake.tscn), so the body carries the root's whole travel, the
			# height too, and the model stays on it. Re-bake after changing one.
			# The side cut's two steps (2026-11-20). "strike": "auto": timed off
			# the clip's own blade (_time_blade): played up to the end of the
			# pass over windup + swing, the rest as its way back. Step 1 is to
			# go right to left, step 2 left to right; which way each goes is
			# printed (PLAYGROUND_CLIP_BLADE) when the game loads.
			"m_cut_1": {"source": "RootPlace.Attack_Combo_01_01", "travel": "body", "strike": "auto"},
			"m_cut_2": {"source": "RootPlace.Attack_Combo_01_02", "travel": "body", "strike": "auto"},
			# The rising cut (2026-11-22, the user: the old three-step chain
			# went, too close to the side cut): Attack_Rising, a leap with the
			# blade going up. "then_clip": it ends still landing (hips 1.10 m
			# up at its last frame), so the pack's landing (Jump_Out, which
			# starts at 1.09 m and ends in the stance) follows its own way back.
			# 2026-11-22 (the user: the way back is too long): the landing is
			# cut at 0.4 s of its 0.87 (back up out of the crouch; the rest is
			# the blend into the stance).
			"m_rise": {"source": "RootPlace.Attack_Rising", "travel": "body", "strike": "auto",
				"then_clip": {"source": "InPlace.Jump_Out", "to": 0.4}},
			# Its second step at mastery 2 (the user, 2026-11-22): from the top
			# of the leap the sword is driven down into the ground. Only ever
			# played after m_rise, from the top of its leap (rising_cut's
			# combo_next_at = 0.567 less its blade's end), so it begins on that
			# frame of Attack_Rising. Put together here ("compose",
			# _composed). Measured 2026-11-22: Attack_Rising tops out at 0.567 s
			# (root 2.00 up, hips at -134 deg, the stance's -125);
			# Air_Attack_06_In at 0.233 s has its hips at -130 with the sword
			# going up overhead; it is held at the top ("hold", its own hop
			# taken out) while the sword turns to point down. 06_Loop is a pose
			# with no height (root 0): "dive" drives it from the top to the
			# ground at one speed from its first frame (the user: straight down
			# fast, not speeding up like a fall; hang 0.37 s, drop 0.08 s);
			# 06_Out lands, the sword in the ground, and stands. Short blends
			# between. "strike" on a part: the blow is that part's first
			# `strike` seconds (the landing), the rest is the way back.
			"m_plunge": {"compose": [
				{"clip": "RootPlace.Attack_Rising", "from": 0.567, "to": 0.6},
				{"blend": 0.05},
				{"clip": "RootPlace.Air_Attack_06_In", "from": 0.233, "hold": true},
				{"blend": 0.03},
				{"clip": "RootPlace.Air_Attack_06_Loop", "to": 0.08, "dive": true},
				{"blend": 0.03},
				# 2026-11-22 (the user: too long): up to where the body has
				# stood up with the sword still down (1.0 s of 1.9; the twirl
				# after it is left out), 1.2 times as fast.
				{"clip": "RootPlace.Air_Attack_06_Out", "strike": 0.05, "to": 1.0, "speed": 1.2},
			]},
			# 2026-11-22 (the user): the sword guard's counter (mastery 2, right
			# after a perfect guard): Attack_Combo_03_03's first pass, from low
			# left up to the right with a step in. From the block pose (the
			# deflect pose is off). Measured: the clip first hops back 1.09 m
			# (0-0.2 s), then the pass (0.32-0.42) steps 0.8 m in; it is cut
			# from the hop's far end ("from" 0.2), so the counter is the step
			# in and the cut. Its own split leaves no way back, so the way
			# back is the clip on from the pass's end to 0.6 s ("back_clip").
			"m_counter": {"source": "RootPlace.Attack_Combo_03_03", "travel": "body", "strike": "auto", "pass": 0,
				"from": 0.2, "back_clip": {"source": "RootPlace.Attack_Combo_03_03", "from": 0.42, "to": 0.6}},
			# The thrust: Attack_Combo_02_02 (the user's pick; the step after
			# this one rewires the thrust itself).
			"m_thrust": {"source": "RootPlace.Attack_Combo_02_02", "travel": "body", "strike": "auto", "return": true},
			# 2026-11-23 (the user): the stab down from a monster's back: the
			# dive's own pieces without the fall -- the sword raised and turned
			# to point down (Air_Attack_06_In from 0.233 s, held where it is),
			# then driven in and the body standing up over it (06_Out, as the
			# dive ends). Not seen yet.
			"m_back_stab": {"compose": [
				{"clip": "RootPlace.Air_Attack_06_In", "from": 0.233, "hold": true},
				{"blend": 0.05},
				{"clip": "RootPlace.Air_Attack_06_Out", "strike": 0.05, "to": 1.0, "speed": 1.2},
			]},
			# Stand-ins for a skill with no clip of its own.
			"m_slash_h": {"source": "RootPlace.Attack_Combo_01_01", "travel": "pin", "strike": "auto"},
			"m_slash_v": {"source": "RootPlace.Attack_Rising", "travel": "pin", "strike": "auto"},
		},
		# Bones below the waist, by the start of their names (the upper body of
		# one clip over the legs of another). Without it: LOWER_BONES (Mixamo).
		"lower_bones": ["root", "pelvis", "thigh_", "calf_", "foot_", "ball_", "ik_foot"],
		# The clips that follow one another, end against start
		# (PLAYGROUND_CLIP_GAP on load).
		"pose_gaps": [
			["m_cut_1", "m_cut_2"],
		],
		# Every attack clip of the pack, timed and printed on load (which way
		# the blade goes, when), to pick the skills' clips by.
		"blade_report": [
			"RootPlace.Attack_Combo_01_01", "RootPlace.Attack_Combo_01_02", "RootPlace.Attack_Combo_01_03",
			"RootPlace.Attack_Combo_01_04", "RootPlace.Attack_Combo_02_01", "RootPlace.Attack_Combo_02_02",
			"RootPlace.Attack_Combo_02_03", "RootPlace.Attack_Combo_02_04", "RootPlace.Attack_Combo_03_01",
			"RootPlace.Attack_Combo_03_02", "RootPlace.Attack_Combo_03_03", "RootPlace.Attack_Combo_03_04",
			"RootPlace.Attack_Rising", "RootPlace.Attack_Sprint", "InPlace.Block_CounterAttacks",
			"RootPlace.Block_Breach",
		],
		# Per weapon (its family id), ahead of "clips": the skills' own.
		"armed_by": {
			"sword": {
				"side_cut": "m_cut_1",
				"side_cut_2": "m_cut_2",
				"rising_cut": "m_rise",
				"rising_cut_m2": "m_plunge",
				"counter_cut": "m_counter",
				"thrust": "m_thrust",
				"back_stab": "m_back_stab",
			},
		},
		"renames": {"Weapom_R": "Weapon_R"},
		# The pack is a sword pack: the same clips with or without a weapon.
		# A bare skill (punch, kick, shove) has no clip of its own here and
		# shows the nearest (slash_h / thrust) or none.
		"clips": {
			"idle": "m_idle",
			"walk": "m_walk",
			"run": "m_run",
			"dash": "m_sprint",
			"jump": "m_jump",
			"fall": "m_fall",
			"slash_h": "m_slash_h",
			"slash_v": "m_slash_v",
			"thrust": "m_thrust",
			"block": "m_block",
			"block_raise": "m_block_in",
			"hit": "m_hit",
			"death": "m_dead",
			"down": "m_idle",
			"carry": "",
			"carried": "",
			"climb": "",
			"stunned": "m_weak",
			"guard_perfect": "m_guard_perfect",
			"guard_hit": "m_guard_hit",
			# 2026-11-22 (the user): off -- the made-up deflect pose did not look
			# like a person; a perfect guard stays in the block (a spark shows
			# the touch, HitFeedback.guard_spark) till a real clip is found.
			# m_guard_deflect and _twist_pose stay for then.
			"guard_break": "m_guard_break",
		},
		"looping": ["idle", "walk", "run", "dash", "fall", "block", "stunned"],
		"holds": {"down": 0.0},
	},
	"kaykit": {
		"model": PACK + "Characters/gltf/Knight.glb",
		"clip_files": [
			PACK + "Animations/gltf/Rig_Medium/Rig_Medium_General.glb",
			PACK + "Animations/gltf/Rig_Medium/Rig_Medium_MovementBasic.glb",
		],
		"height": 2.4,
		"yaw": PI,
		"bones": 23,
		"walk_speed": 1.6,
		"run_speed": 4.5,
		"dash_speed": 2.0,
		# The FREE pack has no attack, block, climb or carry clips: the nearest
		# is used, and the list is in reports/C-1f-2.md.
		"clips": {
			"idle": "Idle_A",
			"walk": "Walking_A",
			"run": "Running_A",
			"dash": "Running_B",
			"jump": "Jump_Start",
			"fall": "Jump_Idle",
			"slash_h": "Interact",
			"slash_v": "Throw",
			"thrust": "Interact",
			"block": "Interact",
			"hit": "Hit_A",
			"death": "Death_B",
			"down": "Idle_A",
			"carry": "PickUp",
			"carried": "Jump_Idle",
			"climb": "Jump_Idle",
			"stunned": "Hit_B",
		},
		"looping": ["idle", "walk", "run", "dash", "fall", "carried", "climb"],
		# Pictures held at one frame: the fraction of the clip it is put at.
		"holds": {"block": 0.35, "down": 0.0},
	},
	"tripo": {
		"model": TRIPO + "tripo_human.glb",
		"clip_files": [TRIPO + "tripo_human_anims.glb"],
		"height": 1.0,
		"yaw": PI,
		"bones": 67,
		"walk_speed": 1.05,
		"run_speed": 3.5,
		"dash_speed": 2.0,
		# Mixamo clips (2026-11-18), one FBX each. The Mixamo rig is this rig
		# with a "mixamorig_" prefix on every bone (same offsets, measured), so
		# a clip is carried over by renaming its tracks. Per clip:
		#   "skeleton_path" below is where this model's own clips aim.
		#   "file": the FBX; "then": a second FBX played straight after it.
		#   "travel": the hips' walk across the floor inside the file, which
		#     the body does itself here -- "ramp" takes the steady drift out
		#     and keeps the sway (gaits), "pin" holds the hips over the feet.
		#   "from"/"to": the part of the file that is kept, in seconds. An
		#     attack ends where its blow lands: the cast stretches the clip
		#     over windup + swing and holds the last frame for the recovery.
		"skeleton_path": "Rig_Tripo/Skeleton3D",
		"fbx_clips": {
			"ss_idle": {"file": SS + "idle (4).fbx"},
			"ss_walk": {"file": SS + "walk.fbx", "travel": "ramp"},
			# "Run With Sword" (no shield pose), the user's pick on 2026-11-18:
			# the head is 0.30 m ahead of the hips, against 0.41 m in the
			# pack's "run", so less of the body leaves the capsule.
			"ss_run": {"file": FBX + "Run With Sword.fbx", "travel": "ramp"},
			# Upper right to lower left; the blow is over at 0.67 s.
			"ss_slash": {"file": SS + "slash.fbx", "travel": "pin", "to": 0.70},
			# The side cut, two level cuts (2026-11-19, the user's call: two
			# steps, flatter than the diagonal pair it replaces). Step 1 is
			# "Stable Sword Outward Slash": the hand is drawn back to the
			# right by 0.72 s and through to the left by 0.95 s, staying
			# 1.06-1.15 m off the floor. Step 2 is the second half of "Stable
			# Sword Inward Slash", the backhand from left to right (1.07 to
			# 1.33 s), which starts in the pose step 1 ends in (hand 0.24 to
			# the left, hips at -60 degrees in both). Each file's own way back
			# to the stance is that step's recovery ("recoveries" below).
			"ss_cut_1": {"file": FBX + "Stable Sword Outward Slash.fbx", "travel": "pin", "from": 0.35, "to": 0.98},
			"ss_cut_1_end": {"file": FBX + "Stable Sword Outward Slash.fbx", "travel": "pin", "from": 0.98},
			# From 1.02 s: the hand is out to the left there, where the first
			# cut leaves it. The blade is not -- the first cut ends with it
			# pointing left, this file has it hanging down across the body
			# (measured: the tips 1.7 to 1.9 m apart wherever the cut is made)
			# -- so the step opens with a turn of the wrist, which is its
			# windup, and the blade goes round behind and through.
			"ss_cut_2": {"file": FBX + "Stable Sword Inward Slash.fbx", "travel": "pin", "from": 1.02, "to": 1.38},
			"ss_cut_2_end": {"file": FBX + "Stable Sword Inward Slash.fbx", "travel": "pin", "from": 1.38},
			# The dash cut (2026-11-19; the overhead cut it replaces was tried
			# five ways, four worked out joint by joint here and one cut from
			# a bout, and none looked right). The user's picture: the body does
			# not turn -- it goes low with the sword hand down at the left hip,
			# then only the arm opens, out to the right, as the body goes
			# through. The stance is the body; what is put on it (_made) is the
			# hips let down with the feet where they are, the waist bent
			# forward, and the two arms. The clip is the cast's length: the
			# crouch is reached by 0.5 and held to 0.745, where the swing
			# starts ("strikes": 0.35 s, the skill's windup); the rest is the
			# arm opening, which is not seen (the skill's vanish_streak hides
			# the model for the swing) -- the last frame is what the body is
			# found in at the far end.
			"ss_dash_cut": {"file": SS + "idle (4).fbx", "to": 0.47, "made": {
				"step_to_stance": true, "foot_lift": 0.0,
				"sink": [[0.0, 0.0], [0.5, 0.24], [0.745, 0.26], [1.0, 0.20]],
				"waist": [[0.0, 0.0], [0.5, -32.0], [0.745, -35.0], [1.0, -24.0]],
				# Round the left side and back, not over the head.
				"sword_arm": [
					[0.00, Vector3(0.26, 1.08, 0.20), Vector3(0.0, 0.85, 0.53)],
					[0.25, Vector3(0.02, 0.95, 0.26), Vector3(-0.7, 0.5, -0.3)],
					[0.50, Vector3(-0.22, 0.80, 0.12), Vector3(-0.25, -0.2, -0.94)],
					[0.745, Vector3(-0.24, 0.78, 0.10), Vector3(-0.25, -0.2, -0.94)],
					[1.00, Vector3(0.70, 1.08, 0.45), Vector3(0.80, 0.10, 0.59)]],
				"sword_pole": Vector3(0.75, -0.55, 0.15),
				# The other hand at the same hip, where a scabbard would be held.
				"off_arm": [
					[0.00, Vector3(-0.30, 1.15, 0.25)],
					[0.50, Vector3(-0.30, 0.86, 0.10)],
					[0.745, Vector3(-0.30, 0.84, 0.08)],
					[1.00, Vector3(-0.32, 0.86, -0.06)]],
			}},
			# "Stabbing" (the user's pick on 2026-11-18): the hand is all the
			# way out at 0.5 s and stays there until 0.9 s. Nothing moves in
			# its first 0.2 s, so the clip starts there: the cast plays it
			# over windup + swing (0.27 s), and the whole 0.52 s ran at 2x.
			"ss_thrust": {"file": FBX + "Stabbing.fbx", "travel": "pin", "from": 0.2, "to": 0.52},
			# The thrust's second step: the legs and hips of "Kicking" (the foot
			# is furthest out at 1.0 s) under the arms and chest of "Stabbing"
			# drawing the blade back out (0.9-1.2 s), fitted to the same length.
			# The chest keeps the heading it has in "Stabbing": the waist takes
			# up the turn and the lean the kick puts in the hips (_with_upper).
			# The user's picture (2026-11-18, seen and accepted with these
			# numbers): the upper body stays where the thrust left it while the
			# right foot comes up and pushes, and the blade comes out.
			"ss_thrust_kick": {"file": FBX + "Kicking.fbx", "travel": "pin", "from": 0.5, "to": 1.02,
				"upper": {"file": FBX + "Stabbing.fbx", "from": 0.80, "to": 1.15}},
			# The parry: "Inward Block" (the user's pick), whose arm crosses
			# the body at 0.43-0.60 s.
			# The file blocks with the left arm; the sword is in the right, so
			# the clip is mirrored (the user, 2026-11-18: "the other hand").
			"ss_parry": {"file": FBX + "Inward Block.fbx", "travel": "pin", "to": 0.62, "mirror": true},
			# The right foot is furthest out at 0.5-0.6 s.
			"ss_kick": {"file": SS + "kick.fbx", "travel": "pin", "to": 0.60},
			"ss_block_raise": {"file": SS + "block.fbx", "travel": "pin"},
			"ss_block": {"file": SS + "block idle.fbx"},
			"ss_hit": {"file": SS + "impact (2).fbx", "travel": "pin"},
			"ss_stunned": {"file": SS + "impact (3).fbx", "travel": "pin"},
			# Falls backward and stays down (the last frame holds).
			"ss_death": {"file": SS + "death.fbx", "travel": "pin"},
			"ss_jump": {"file": SS + "jump (2).fbx", "travel": "pin"},
			# The hand goes to the hip (0.5 s), then the blade comes out.
			"ss_draw": {"file": DRAW + "draw sword 1.fbx", "then": DRAW + "draw sword 2.fbx", "travel": "pin"},
			"ss_sheathe": {"file": DRAW + "sheath sword 1.fbx", "then": DRAW + "sheath sword 2.fbx", "travel": "pin"},
			# The dash: off a crouch, and the braking at the far end.
			"dash_start": {"file": FBX + "Crouched To Sprinting.fbx", "travel": "pin"},
			"dash_stop": {"file": FBX + "Run To Stop.fbx", "travel": "pin"},
		},
		# front_kick_02's foot goes through at 0.8-0.93 s (measured 11-08).
		"cuts": {"front_kick_02": [0.0, 0.95]},
		# The pace a gait clip's planted foot slides at (m/s at 1.8 m), where
		# it is not the profile's walk_speed / run_speed.
		"paces": {"ss_walk": 1.44, "ss_run": 3.57},
		# Empty-handed: Tripo's own clips (walk, run, wait, standing_relax,
		# chop, box x3, front_kick x2, dive, swim; run_looped and chop_single
		# are cut by the build script). "" keeps the picture before it.
		"clips": {
			# standing_relax (17.6 s, seam 0.026), not wait (hands on hips):
			# the user's pick on 2026-11-06.
			"idle": "standing_relax",
			"walk": "walk",
			"run": "run_looped",
			"dash": "dash_start",
			"dash_stop": "dash_stop",
			"jump": "ss_jump",
			"fall": "",
			"slash_h": "",
			"slash_v": "chop_single",
			"thrust": "",
			"punch": "box_01",
			"kick": "front_kick_02",
			"block": "",
			"hit": "ss_hit",
			"death": "ss_death",
			"down": "standing_relax",
			"carry": "",
			"carried": "",
			"climb": "",
			"stunned": "ss_stunned",
		},
		# With a weapon or a shield in hand these take the place of the above.
		"armed": {
			"idle": "ss_idle",
			"walk": "ss_walk",
			"run": "ss_run",
			"slash_h": "ss_slash",
			"side_cut": "ss_cut_1",
			"side_cut_2": "ss_cut_2",
			"dash_cut": "ss_dash_cut",
			"thrust": "ss_thrust",
			"thrust_2": "ss_thrust_kick",
			"parry": "ss_parry",
			"kick": "ss_kick",
			"block": "ss_block",
			"block_raise": "ss_block_raise",
			"down": "ss_idle",
			"draw": "ss_draw",
			"sheathe": "ss_sheathe",
		},
		"looping": ["idle", "walk", "run", "block"],
		"holds": {"down": 0.0},
		# While one of these clips is the attack on screen the weapon is turned
		# in the hand until its blade lies along the forearm (a thrust points
		# the blade where the arm points); it turns back when the attack ends.
		"aim_along_arm": ["ss_thrust", "ss_thrust_kick"],
		# While one of these is the attack on screen the body bends forward
		# at the waist (Tuning.values.visual_thrust_lean_deg, eased in and
		# out): the thrust goes in at the middle of a body, and the kick that
		# follows keeps the upper body where the thrust left it.
		"lean_clips": ["ss_thrust", "ss_thrust_kick"],
		"lean_bones": ["Spine", "Spine1"],
		# While one of these is the attack on screen, part of the clip's own
		# forward bend is taken back out (Tuning.values.visual_chop_straighten).
		# chop_single is a wood-chopping swing: the chest starts 61 degrees
		# forward and ends 98 (nearly flat, head down to 1.0 m), measured.
		"straighten_clips": ["chop_single"],
		# While one of these is the attack on screen the head is kept facing
		# the way the body faces (the dash cut bends the waist well forward;
		# the eyes stay on the line).
		"look_ahead_clips": ["ss_dash_cut"],
		# An attack clip whose blow leaves the body somewhere it has to get
		# back from: when the clip ends this one plays through what is left
		# of the recovery, in place of the last frame held still.
		"recoveries": {"ss_cut_1": "ss_cut_1_end", "ss_cut_2": "ss_cut_2_end"},
		# Where in an attack clip the blade starts its pass, seconds. The
		# part before it is played over the skill's windup and the part from
		# it over the swing, each at its own speed: the blade is then moving
		# exactly while the server sweeps and the trail is drawn, and a short
		# swing after a longer windup is a slow draw and a fast cut.
		# (ss_cut_2: its file's pass starts at 1.07 s, 0.05 into the clip.
		# ss_dash_cut: the crouch is the windup; from 0.35 s the arm opens.)
		"strikes": {"ss_cut_1": 0.37, "ss_cut_2": 0.05, "ss_dash_cut": 0.35},
		"forearm_bones": ["RightForeArm", "RightHand"],
		# The dash: the model is not drawn from this long after it starts
		# until the body is out of DASH (the body itself still runs the
		# path; nothing but the picture changes).
		"dash_hide_after": 0.10,
	},
}
# 2026-11-19: the game draws the Tripo model (the user's call). An automated
# run still draws none unless it names one with --model= (CHECK_PROFILE): the
# checks were written against the capsule and the floating hands.
# 2026-11-20: the sword pack's mannequin (the user's call), Tripo before.
const DEFAULT_PROFILE := "mannequin"
const CHECK_PROFILE := "none"
# Bones a draw or a sheathe moves while the legs keep their own clip.
const LOWER_BONES := ["Hips", "UpLeg", "Leg", "Foot", "ToeBase", "Toe_End"]
const MIXAMO_PREFIX := "mixamorig_"

# The sword is drawn 1.2 m pommel to tip (the order's 1.0 m blade and 0.2 m
# grip). The model (measured 2026-11-19) is 1.0 unit long along +Y and stands
# on its tip: the tip at y 0, the guard at 0.7-0.8, the grip and pommel above
# it to 1.0. It is held at SWORD_GRIP_AT, the middle of the grip, and turned
# over so the blade runs up from the hand.
const SWORD_LENGTH := 1.2
const SWORD_MODEL_LENGTH := 1.0
const SWORD_GRIP_AT := 0.87
# From the hand to the tip, metres: what a trail off the blade spans.
const BLADE_LENGTH := SWORD_LENGTH * SWORD_GRIP_AT
const SHIELD_SCALE := 1.0
const BLEND := 0.12
# Out of an attack and back to the body's own clip: slower than BLEND, so a
# pose that was held does not snap to standing.
const ATTACK_OUT_BLEND := 0.3
# A blow is held this long at its end before the body starts back.
const FOLLOW_HOLD := 0.05
const RECOVERY_SPEED_MAX := 1.6
const HIT_SPEED := 1.6
# The braking after a dash, played this fast.
const STOP_SPEED := 1.5
# How fast the weapon turns in the hand toward the forearm and back (1/s).
const AIM_RATE := 8.0
# How fast the body bends into a lean clip and straightens out of it (1/s):
# all the way in 0.2 s, which is most of the thrust's windup + swing.
const LEAN_RATE := 5.0
const SPINE_LEAN := preload("res://scripts/player/spine_lean_modifier.gd")
const FOOT_LOCK := preload("res://scripts/player/foot_lock_modifier.gd")

static var _profile_name := ""
static var _scene_cache := {}
static var _library: AnimationLibrary
# Draw and sheathe with the leg tracks left out, for the second player.
static var _upper_library: AnimationLibrary
static var _clip_lengths := {}
# For a clip made of two files: how long the first one is.
static var _first_part := {}
# Read off the model when it loads, for a profile that leaves them to be
# measured ("height" 0, "yaw_from"): the height in the model's units, the
# skeleton's place in the model (an FBX may carry a unit scale on it) and the
# turn that faces the model the body's way.
static var _measured_height := 0.0
static var _skeleton_in_model := Transform3D()
static var _measured_yaw := 0.0
# The gait clips' own root travel, m/s at the human capsule, by clip.
static var _measured_paces := {}
# The way the model faces in its own space, before the yaw (the foot's line).
static var _measured_forward := Vector3.ZERO
# A library clip marked "strike": "auto": where its blade's pass starts
# (seconds, as the profile's "strikes"), and the clip made of what comes
# after the pass (its way back, as the profile's "recoveries").
static var _auto_strikes := {}
static var _auto_recoveries := {}
# 2026-11-21: for the motion bake (baked_motion): a timed clip's parts
# ({"part_from", "pass_from", "pass_to", "back_to"}, seconds of the source)
# and the source itself before its root travel was taken out.
static var _blade_parts := {}
static var _raw_sources := {}
# 2026-11-21: for the feet (foot_lock_modifier.gd): per clip as it is played
# (an attack clip and its "_end"), which feet are on the ground, one entry
# per MOTION_SAMPLE of its own time ({"l": PackedByteArray, "r": ...}); and
# per timed clip, the moment (seconds of the source) both feet first leave
# the ground after its blade starts to move, or -1.
static var _foot_contacts := {}
static var _leaves_ground := {}
# A timed clip whose way back is another clip ("back_clip"): that clip, as
# played (its time 0 is the blow's end).
static var _raw_backs := {}
# A "pivot" way back: per MOTION_SAMPLE of it, where the body goes so the
# pivot foot stays put ((right, 0, forward) metres off the blow's place);
# and which foot is the pivot.
static var _pivot_paths := {}
static var _pivot_feet := {}
# 2026-11-22: every timed clip as it was before it was cut (travel taken
# out, source time), for a "lead" spin out of it into another clip.
static var _timed_full := {}
# 2026-11-22: a composed clip's blow ("strike" on a part): Vector2(from, to),
# seconds of the composed clip.
static var _compose_strikes := {}

var player: Player
var _model: Node3D
var _skeleton: Skeleton3D
var _anim: AnimationPlayer
# Runs after _anim and writes only the upper body: a draw or a sheathe over
# whatever the legs are doing.
var _upper: AnimationPlayer
# A preview has no body to ask: the test says whether a weapon is in hand.
var preview_armed := false
var _armed_shown := false
var _stop_until_msec := 0
var _dash_shown_for := 0.0
var _aim_weight := 0.0
# The blend the next clip is started with, when it is not BLEND (-1).
# Where in the attack clip the strike phase picks it up (-1: played evenly).
var _strike_at := -1.0
# What is left of the hold after a blow before its way back starts.
var _follow_hold := 0.0
# The return-only step (SkillDef.motion_return_only) whose return is showing.
var _attack_phase_of_return := ""
# 2026-11-21: the attack showing is a skill whose motion was baked off this
# very clip (SkillDef "Motion"): it runs at the clip's own pace start to end,
# the body under it moving by the same numbers, so the blow is not held
# (FOLLOW_HOLD) and the way back is not hurried.
var _attack_baked := false
# The step back into the stance after it (SkillDef motion_return_*): how
# long, the foot kept, and whether it has been shown for this cast.
var _return_seconds := 0.0
var _return_foot := ""
var _returned := false
var _lean: SkeletonModifier3D
# 2026-11-21: the feet held to the ground (foot_lock_modifier.gd), and the
# engine's two-bone IK that bends the legs to it. Null without "leg_bones".
var _feet: SkeletonModifier3D
var _lean_weight := 0.0
var _straight_weight := 0.0
var _look_weight := 0.0
var _blend_once := -1.0
var _recovery_seconds := 0.0
var _hand: BoneAttachment3D
var _offhand: BoneAttachment3D
# Under each slot: the node a prop is parented to. It undoes the model's
# scale, so a prop is drawn at the size the order names (the sword 1.2 m) on
# a 2.4-unit KayKit and a 1.0-unit Tripo alike; Player's own writes to the
# prop's scale (weapon_length_mult, the raised shield) sit on the prop.
var _grip: Node3D
var _offgrip: Node3D
var _loaded := false
var _last_position := Vector3.ZERO
var _h_speed := 0.0
var _v_speed := 0.0
var _have_last := false
# The picture currently chosen (a CLIPS key), and the clip playing for it.
var picture := ""
var _attack_clip := ""
var _attack_phase := ""
var _attack_done := false
var _hit_until_msec := 0
var _block_raised := false
# For the checks: when the last attack clip started and when it finished.
var attack_started_msec := 0
var attack_finished_msec := 0
var attack_expected_seconds := 0.0
var attacks_shown := 0
var model_scale := 1.0


func setup(owner_player: Player) -> void:
	player = owner_player
	_load_model()


# A model with no body behind it, for a test scene: the clips are driven by
# hand (_play / _start_attack) and _process does nothing without a player.
func setup_preview() -> void:
	player = null
	_load_model()


func model_loaded() -> bool:
	return _loaded


func skeleton() -> Skeleton3D:
	return _skeleton


# The clip being shown: still the last one played once it has finished or is
# paused (current_animation empties then; assigned_animation does not).
func current_clip() -> String:
	return _anim.assigned_animation if _anim != null else ""


func clip_speed() -> float:
	return _anim.speed_scale if _anim != null else 0.0


func is_clip_playing() -> bool:
	return _anim != null and _anim.is_playing()


static func clip_length(clip: String) -> float:
	return float(_clip_lengths.get(clip, 0.0))


static func clip_for(key: String) -> String:
	return String(profile()["clips"].get(key, ""))


# With something in hand the profile's "armed" clips stand in.
func is_armed() -> bool:
	if player == null:
		return preview_armed
	return player.weapon != WeaponKinds.Kind.NONE or player.offhand != WeaponKinds.Kind.NONE


# The clip for a picture on this body now. 2026-11-20: a weapon's own table
# first ("armed_by", by the weapon's family id: "sword", later "bow", "staff",
# "shield"), then the shared "armed" one, then the bare one.
func clip_now(key: String) -> String:
	if is_armed():
		var by_weapon: Dictionary = profile().get("armed_by", {})
		if player != null and not by_weapon.is_empty():
			for kind: int in [player.weapon, player.offhand]:
				var weapon := Weapons.def_for_kind(kind)
				if weapon == null:
					continue
				var own: Dictionary = by_weapon.get(weapon.family_id(), {})
				if own.has(key):
					return String(own[key])
		var armed: Dictionary = profile().get("armed", {})
		if armed.has(key):
			return String(armed[key])
	return clip_for(key)


# ------------------------------------------------------------------ profile

static func profile_name() -> String:
	if _profile_name == "":
		_profile_name = CHECK_PROFILE if Player.is_check_run() else DEFAULT_PROFILE
		for argument in OS.get_cmdline_user_args():
			if argument.begins_with("--model="):
				var want := argument.trim_prefix("--model=")
				if PROFILES.has(want):
					_profile_name = want
				else:
					push_warning("CharacterVisual: no model profile %s; drawing %s" % [want, DEFAULT_PROFILE])
	return _profile_name


static func profile() -> Dictionary:
	return PROFILES[profile_name()]


# Switches the pack for this process (a test scene). Must run before any
# model is loaded in it: the parsed files and the clip library are dropped.
static func use_profile(name_text: String) -> void:
	if not PROFILES.has(name_text):
		push_error("CharacterVisual: no model profile %s" % name_text)
		return
	_profile_name = name_text
	_scene_cache.clear()
	_library = null
	_upper_library = null
	_clip_lengths.clear()
	_first_part.clear()
	_measured_height = 0.0
	_skeleton_in_model = Transform3D()
	_measured_yaw = 0.0
	_measured_paces.clear()
	_measured_forward = Vector3.ZERO
	_auto_strikes.clear()
	_auto_recoveries.clear()
	_blade_parts.clear()
	_raw_sources.clear()
	_foot_contacts.clear()
	_leaves_ground.clear()
	_raw_backs.clear()
	_pivot_paths.clear()
	_pivot_feet.clear()
	_timed_full.clear()


static func model_height() -> float:
	var height := float(profile()["height"])
	if height <= 0.0:
		return maxf(_measured_height, 0.01)
	return height


# The bone the main-hand prop hangs off, and the off hand's.
static func hand_bone() -> String:
	return String(profile().get("hand_bone", HAND_BONE))


static func offhand_bone() -> String:
	return String(profile().get("offhand_bone", OFFHAND_BONE))


# A bone by what it is (the hand, the hips), for the debug tools. The Mixamo
# names unless the profile names its own.
static func named_bone(role: String) -> String:
	var named: Dictionary = profile().get("named_bones", {})
	return String(named.get(role, {"hand": "RightHand", "hips": "Hips"}.get(role, "")))


# ------------------------------------------------------------------ loading

static func _generate(path: String) -> PackedScene:
	if _scene_cache.has(path):
		return _scene_cache[path]
	# An FBX is read by its own document (the same reader, the same result).
	var fbx := path.to_lower().ends_with(".fbx")
	var doc: GLTFDocument = FBXDocument.new() if fbx else GLTFDocument.new()
	var state: GLTFState = FBXState.new() if fbx else GLTFState.new()
	var err := doc.append_from_file(path, state)
	if err != OK:
		push_error("CharacterVisual: %s would not load (%d)" % [path, err])
		_scene_cache[path] = null
		return null
	var root := doc.generate_scene(state)
	var packed := PackedScene.new()
	if packed.pack(root) != OK:
		push_error("CharacterVisual: %s would not pack" % path)
		_scene_cache[path] = null
		root.free()
		return null
	root.free()
	_scene_cache[path] = packed
	return packed


static func _build_library() -> AnimationLibrary:
	if _library != null:
		return _library
	var library := AnimationLibrary.new()
	_add_library_clips(library)
	for path in profile().get("clip_files", []):
		var packed := _generate(path)
		if packed == null:
			continue
		var root := packed.instantiate()
		for node in root.find_children("*", "AnimationPlayer", true, false):
			var source := node as AnimationPlayer
			for clip in source.get_animation_list():
				var animation := source.get_animation(clip).duplicate(true) as Animation
				library.add_animation(clip, animation)
				_clip_lengths[clip] = animation.length
		root.free()
	var cuts: Dictionary = profile().get("cuts", {})
	for clip in cuts:
		if library.has_animation(clip):
			var kept := _cut(library.get_animation(clip), float(cuts[clip][0]), float(cuts[clip][1]))
			library.remove_animation(clip)
			library.add_animation(clip, kept)
			_clip_lengths[clip] = kept.length
	var fbx_clips: Dictionary = profile().get("fbx_clips", {})
	# The model's own skeleton, for a clip that has to be mirrored: its rest
	# pose and which bone hangs off which.
	var rig_root: Node = null
	var rig: Skeleton3D = null
	if not fbx_clips.is_empty():
		var model := _generate(String(profile()["model"]))
		if model != null:
			rig_root = model.instantiate()
			var found := rig_root.find_children("*", "Skeleton3D", true, false)
			if not found.is_empty():
				rig = found[0] as Skeleton3D
	# The clips made so far, by name: one made clip can follow another.
	var built := {}
	for clip in fbx_clips:
		var animation := _fbx_clip(clip, fbx_clips[clip], String(profile().get("skeleton_path", "")), rig, built)
		if animation == null:
			continue
		built[clip] = animation
		library.add_animation(clip, animation)
		_clip_lengths[clip] = animation.length
	if rig_root != null:
		rig_root.free()
	var armed: Dictionary = profile().get("armed", {})
	for key in profile()["looping"]:
		for clip in [clip_for(key), String(armed.get(key, ""))]:
			if library.has_animation(clip):
				library.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
	_upper_library = AnimationLibrary.new()
	for key in ["draw", "sheathe"]:
		var clip := String(armed.get(key, ""))
		if library.has_animation(clip):
			_upper_library.add_animation(clip, _upper_only(library.get_animation(clip)))
	_library = library
	return library


# ------------------------------------------------------------------ library clips

# A profile with a prebuilt library ("library", the sword pack's): each of
# its "library_clips" copied out of it under the name used here, its bone
# names put right ("renames"), its root travel measured and taken out.
static func _add_library_clips(library: AnimationLibrary) -> void:
	var path := String(profile().get("library", ""))
	if path == "":
		return
	var source := load(path) as AnimationLibrary
	if source == null:
		push_error("CharacterVisual: %s would not load" % path)
		return
	var root_bone := String(profile().get("root_bone", "Hips"))
	var renames: Dictionary = profile().get("renames", {})
	var specs: Dictionary = profile().get("library_clips", {})
	# The model's skeleton, for the clips whose blade is timed here.
	var rig_root: Node = null
	var rig: Skeleton3D = null
	var model := load(String(profile()["model"])) as PackedScene
	if model != null:
		rig_root = model.instantiate()
		var found := rig_root.find_children("*", "Skeleton3D", true, false)
		if not found.is_empty():
			rig = found[0] as Skeleton3D
	for clip in specs:
		var spec: Dictionary = specs[clip]
		if spec.has("compose"):
			if rig != null:
				var made := _composed(String(clip), source, spec["compose"], rig, root_bone)
				if made != null and _compose_strikes.has(clip):
					# Timed by its "strike" part: travel off the root (the body
					# carries it, SkillDef "Motion"), the model on the root's rest.
					_raw_sources[clip] = made.duplicate(true)
					_strip_travel(made, "body", root_bone)
					_rest_root(made, rig, root_bone)
					var marks: Vector2 = _compose_strikes[clip]
					made = _time_given(library, String(clip), made, marks.x, marks.y)
					_study_feet(String(clip), rig)
				if made != null:
					library.add_animation(clip, made)
					_clip_lengths[clip] = made.length
			continue
		var from_name := StringName(String(spec["source"]))
		if not source.has_animation(from_name):
			push_error("CharacterVisual: no clip %s in %s" % [from_name, path])
			continue
		var animation := source.get_animation(from_name).duplicate(true) as Animation
		for track in animation.get_track_count():
			var track_path := animation.track_get_path(track)
			if track_path.get_subname_count() == 0:
				continue
			var bone := String(track_path.get_subname(0))
			if renames.has(bone):
				animation.track_set_path(track, NodePath("%s:%s" % [track_path.get_concatenated_names(), renames[bone]]))
		var travel := String(spec.get("travel", ""))
		if travel == "ramp":
			_measured_paces[clip] = _root_pace(animation, root_bone)
		if String(spec.get("strike", "")) == "auto":
			_raw_sources[clip] = animation.duplicate(true)
			# 2026-11-22: cut where the clip is ("from"/"to"), so the blade's
			# times (_blade_parts) and the baked motion read the same seconds.
			if spec.has("from") or spec.has("to"):
				_raw_sources[clip] = _cut(_raw_sources[clip] as Animation, float(spec.get("from", 0.0)),
					float(spec.get("to", animation.length)))
		_strip_travel(animation, travel, root_bone)
		if spec.has("from") or spec.has("to"):
			animation = _cut(animation, float(spec.get("from", 0.0)), float(spec.get("to", animation.length)))
		if String(spec.get("strike", "")) == "auto" and rig != null:
			animation = _time_blade(library, String(clip), String(spec["source"]), animation, rig,
				int(spec.get("pass", -1)), _back_clip(source, spec.get("back_clip", {}), renames, root_bone),
				_back_clip(source, spec.get("then_clip", {}), renames, root_bone), spec.get("pivot", {}))
			if _blade_parts.has(clip):
				_study_feet(String(clip), rig)
		library.add_animation(clip, animation)
		_clip_lengths[clip] = animation.length
	if rig != null:
		# Candidates studied and printed only (PLAYGROUND_CLIP_BLADE), to pick
		# a clip by its blade. Nothing is kept of them.
		for name_text in profile().get("blade_report", []):
			var from_name := StringName(String(name_text))
			if not source.has_animation(from_name):
				continue
			var candidate := source.get_animation(from_name).duplicate(true) as Animation
			_strip_travel(candidate, "pin", root_bone)
			_print_study("(후보)", String(name_text), candidate, _blade_study(candidate, rig))
		# How far apart the end of one clip and the start of the next are, for
		# the clips that follow one another (PLAYGROUND_CLIP_GAP).
		for pair in profile().get("pose_gaps", []):
			if library.has_animation(String(pair[0])) and library.has_animation(String(pair[1])):
				_print_gap(String(pair[0]), library.get_animation(String(pair[0])),
					String(pair[1]), library.get_animation(String(pair[1])), rig)
	if rig_root != null:
		rig_root.free()


# ------------------------------------------------------------------ the blade

# An attack clip of the pack, timed off its own blade. A pass is a run of
# frames where the blade (halfway along it) moves at least BLADE_PASS_SHARE
# of its fastest; gaps under BLADE_PASS_GAP are one pass; a run whose own
# fastest is under BLADE_PASS_MIN of the clip's is no pass. The clip is cut
# where its pass ends -- the cast plays up to there over windup + swing, the
# pass itself over the swing -- and what follows, up to where the next pass
# begins to wind up (the slowest frame between the two) or the clip's end, is
# its way back, played through the recovery. `pass_index` picks a pass (0 the
# first); -1 the fastest. A part past the first starts at that slowest frame.
const BLADE_PASS_SHARE := 0.35
const BLADE_PASS_MIN := 0.5
const BLADE_PASS_GAP := 0.05
const BLADE_SAMPLE := 1.0 / 60.0


static func _track_map(animation: Animation) -> Dictionary:
	var tracks := {}
	for track in animation.get_track_count():
		var kind := animation.track_get_type(track)
		var track_path := animation.track_get_path(track)
		if track_path.get_subname_count() == 0:
			continue
		if kind == Animation.TYPE_ROTATION_3D:
			tracks[String(track_path.get_subname(0)) + "/r"] = track
		elif kind == Animation.TYPE_POSITION_3D:
			tracks[String(track_path.get_subname(0)) + "/p"] = track
	return tracks


# The skeleton's up and the body's right, in the skeleton's own space.
static func _body_axes() -> Array[Vector3]:
	var to_skeleton := _skeleton_in_model.basis.inverse()
	var up := (to_skeleton * Vector3.UP).normalized()
	var forward := (to_skeleton * _measured_forward).normalized()
	return [up, forward.cross(up).normalized()]


# Which way the hips face at a moment, as a bearing about the up axis
# (degrees): the line from the left thigh to the right one.
static func _hips_bearing(globals: Array[Transform3D], rig: Skeleton3D, up: Vector3, right: Vector3) -> float:
	var left := rig.find_bone("thigh_l")
	var right_thigh := rig.find_bone("thigh_r")
	if left < 0 or right_thigh < 0:
		return 0.0
	var line := globals[right_thigh].origin - globals[left].origin
	line -= up * line.dot(up)
	var ahead := up.cross(right)
	return rad_to_deg(atan2(line.dot(ahead), line.dot(right)))


static func _blade_study(animation: Animation, rig: Skeleton3D) -> Dictionary:
	var hand := rig.find_bone(hand_bone())
	if hand < 0 or animation.length < BLADE_SAMPLE * 4.0:
		return {}
	var tracks := _track_map(animation)
	# Halfway along the blade, in the skeleton's units; the blade runs along
	# the weapon bone's +X (see the profile's grip_basis).
	var inner := maxf(_skeleton_in_model.basis.get_scale().x, 0.0001)
	var reach := SWORD_LENGTH * 0.5 * model_height() / (Player.BODY_HALF_HEIGHT * 2.0) / inner
	var axes := _body_axes()
	var times: Array[float] = []
	var tips: Array[Vector3] = []
	var bearings: Array[float] = []
	var time := 0.0
	while time <= animation.length + 0.0001:
		var globals := _globals_of(rig, _locals_at(animation, rig, minf(time, animation.length), tracks))
		var weapon := globals[hand]
		tips.append(weapon.origin + weapon.basis.x.normalized() * reach - globals[0].origin)
		bearings.append(_hips_bearing(globals, rig, axes[0], axes[1]))
		times.append(minf(time, animation.length))
		time += BLADE_SAMPLE
	var speeds: Array[float] = []
	var top := 0.0
	for index in tips.size() - 1:
		speeds.append(tips[index].distance_to(tips[index + 1]))
		top = maxf(top, speeds[index])
	# The runs over the share, joined across short gaps, kept if fast enough.
	var runs: Array = []
	var gap_frames := int(ceil(BLADE_PASS_GAP / BLADE_SAMPLE))
	var index := 0
	while index < speeds.size():
		if speeds[index] < top * BLADE_PASS_SHARE:
			index += 1
			continue
		var first := index
		while index < speeds.size() and speeds[index] >= top * BLADE_PASS_SHARE:
			index += 1
		if not runs.is_empty() and first - int(runs[-1][1]) <= gap_frames:
			runs[-1][1] = index
		else:
			runs.append([first, index])
	var passes: Array = []
	var fastest := -1
	for run in runs:
		var peak := 0.0
		for at in range(int(run[0]), int(run[1])):
			peak = maxf(peak, speeds[at])
		if peak < top * BLADE_PASS_MIN:
			continue
		if peak >= top - 0.000001:
			fastest = passes.size()
		passes.append(run)
	# Between two passes: the slowest frame, where the one ends and the next
	# begins.
	var splits: Array[int] = []
	for at in passes.size() - 1:
		var slowest := int(passes[at][1])
		for frame in range(int(passes[at][1]), int(passes[at + 1][0]) + 1):
			if speeds[mini(frame, speeds.size() - 1)] < speeds[mini(slowest, speeds.size() - 1)]:
				slowest = frame
		splits.append(slowest)
	return {
		"times": times, "tips": tips, "bearings": bearings, "passes": passes, "splits": splits,
		"fastest": maxi(fastest, 0), "up": axes[0], "right": axes[1],
		"metre": (SWORD_LENGTH * 0.5) / maxf(reach, 0.0001),
	}


static func _print_study(clip: String, source: String, animation: Animation, study: Dictionary) -> void:
	if study.is_empty():
		return
	var times: Array[float] = study["times"]
	var tips: Array[Vector3] = study["tips"]
	var bearings: Array[float] = study["bearings"]
	var up: Vector3 = study["up"]
	var right: Vector3 = study["right"]
	var metre := float(study["metre"])
	var parts := PackedStringArray()
	var number := 0
	for run in study["passes"]:
		number += 1
		var start := tips[int(run[0])]
		var end := tips[int(run[1])]
		parts.append("%d) %.2f-%.2f s %s 좌우 %.2f->%.2f m 높이 %.2f->%.2f m" % [number, times[int(run[0])], times[int(run[1])],
			"오른쪽→왼쪽" if start.dot(right) > end.dot(right) else "왼쪽→오른쪽",
			start.dot(right) * metre, end.dot(right) * metre, start.dot(up) * metre, end.dot(up) * metre])
	var turn := wrapf(bearings[-1] - bearings[0], -180.0, 180.0)
	print("PLAYGROUND_CLIP_BLADE clip=%s source=%s 길이 %.2f s  몸 회전 %+.0f°  칼 지나감 %d번: %s" % [
		clip, source, animation.length, turn, parts.size(), "  |  ".join(parts)])


# 2026-11-21: a "back_clip" spec ({"source", "to"}) out of the pack's
# library: the clip up to "to", its bone names put right, its root's travel
# across the ground taken out like the attack's ("body"; its turn is kept:
# the turn is the clip). Null for no spec.
static func _back_clip(source: AnimationLibrary, spec: Dictionary, renames: Dictionary, root_bone: String) -> Animation:
	if spec.is_empty() or not source.has_animation(StringName(String(spec["source"]))):
		return null
	var back := source.get_animation(StringName(String(spec["source"]))).duplicate(true) as Animation
	for track in back.get_track_count():
		var track_path := back.track_get_path(track)
		if track_path.get_subname_count() > 0 and renames.has(String(track_path.get_subname(0))):
			back.track_set_path(track, NodePath("%s:%s" % [track_path.get_concatenated_names(), renames[String(track_path.get_subname(0))]]))
	_strip_travel(back, "body", root_bone)
	# 2026-11-22: "from" as well (the counter's way back is the middle of a
	# combo clip).
	if spec.has("to") or spec.has("from"):
		back = _cut(back, float(spec.get("from", 0.0)), float(spec.get("to", back.length)))
	return back


# 2026-11-22 TEST ("compose"): parts end to end, each made into a pose for
# every bone 30 times a second so they join cleanly. A part is
#   {"clip": <library name>, "travel": ...}  a library clip as it is;
#   {"upper": <name>, "legs": <name>, "legs_mix": <name>, "mix": 0..1,
#    "seconds": s}  the upper body of one clip over the legs of another
#    (_is_lower; the legs optionally part way to a third), `seconds` long
#    (default the upper clip's length; it holds its last frame after);
#   {"spin": <pivot spec>}  a spin made here (_pivot_clip, linked) from the
#    part before's last frame into the part after's first.
#   {"blend": s}  `s` seconds from the part before's last frame into the
#    part after's first, every bone on the straight way.
# A clip part may also take "from"/"to" (seconds of the clip), "from_pass_of"
# (from where that timed clip's blow ends), "speed" (played that much
# faster), "hold": true (its root kept at the height the part before ended
# at, its own rise and fall taken out), "dive": true (its root driven from
# that height to the ground at one speed) and "strike": s (the clip's blow is
# this part's first `s` seconds: _compose_strikes). Each clip part after the
# first goes on across the ground from where the part before left the root.
static func _composed(clip: String, source: AnimationLibrary, parts: Array, rig: Skeleton3D, root_bone: String) -> Animation:
	var pieces: Array = []
	var owners: Array = []
	var last_made: Animation = null
	_compose_strikes.erase(clip)
	for part: Dictionary in parts:
		owners.append(part)
		if part.has("spin") or part.has("blend"):
			pieces.append(part)
			continue
		var made := _composed_part(source, part, rig, root_bone, last_made)
		if made == null:
			push_error("CharacterVisual: %s: a part would not build (%s)" % [clip, part])
			return null
		pieces.append(made)
		last_made = made
	var out: Animation = null
	for index in pieces.size():
		var starts_at := out.length if out != null else 0.0
		if (owners[index] as Dictionary).has("strike"):
			_compose_strikes[clip] = Vector2(starts_at, starts_at + float(owners[index]["strike"]))
		var piece: Variant = pieces[index]
		var animation: Animation
		if piece is Dictionary:
			if index == 0 or index == pieces.size() - 1 or not (pieces[index - 1] is Animation) \
					or not (pieces[index + 1] is Animation):
				push_error("CharacterVisual: %s: a spin or blend needs a part on each side" % clip)
				return null
			var before := pieces[index - 1] as Animation
			var after := pieces[index + 1] as Animation
			if (piece as Dictionary).has("blend"):
				var from_pose := _locals_at(before, rig, before.length, _track_map(before))
				var to_pose := _locals_at(after, rig, 0.0, _track_map(after))
				var seconds := maxf(float(piece["blend"]), MOTION_SAMPLE)
				animation = _baked_poses(rig, String(before.track_get_path(0)).get_slice(":", 0), seconds,
					func(time: float) -> Array[Transform3D]:
						var share := time / seconds
						var pose: Array[Transform3D] = []
						for bone in from_pose.size():
							pose.append(Transform3D(Basis(from_pose[bone].basis.get_rotation_quaternion().slerp(
								to_pose[bone].basis.get_rotation_quaternion(), share)),
								from_pose[bone].origin.lerp(to_pose[bone].origin, share)))
						return pose)
			else:
				animation = _pivot_clip("%s_spin%d" % [clip, index], before, before.length, rig, piece["spin"], after, 0.0)
			if animation == null:
				return null
		else:
			animation = piece as Animation
		out = animation if out == null else _joined(out, animation)
	print("PLAYGROUND_CLIP_COMPOSE clip=%s parts=%d length=%.2f s" % [clip, pieces.size(), out.length if out != null else 0.0])
	return out


static func _composed_part(source: AnimationLibrary, part: Dictionary, rig: Skeleton3D, root_bone: String,
		before: Animation = null) -> Animation:
	var first := String(part.get("clip", part.get("upper", "")))
	if not source.has_animation(StringName(first)):
		return null
	var main := source.get_animation(StringName(first)).duplicate(true) as Animation
	var prefix := String(main.track_get_path(0)).get_slice(":", 0)
	if part.has("clip"):
		_strip_travel(main, String(part.get("travel", "")), root_bone)
		var from := float(part.get("from", 0.0))
		var pass_of := String(part.get("from_pass_of", ""))
		if pass_of != "":
			if not _blade_parts.has(pass_of):
				push_error("CharacterVisual: a part starts where %s's blow ends, which is not timed before it" % pass_of)
				return null
			from = float((_blade_parts[pass_of] as Dictionary)["pass_to"])
		if from > 0.0 or part.has("to"):
			main = _cut(main, from, float(part.get("to", main.length)))
		var main_tracks := _track_map(main)
		# Where the part before left the root: its height along the skeleton's
		# up, and across the ground, where this part goes on from.
		var up: Vector3 = _body_axes()[0]
		var root := rig.find_bone(root_bone)
		var height_before := 0.0
		var across := Vector3.ZERO
		if before != null and root >= 0:
			var end_place := _locals_at(before, rig, before.length, _track_map(before))[root].origin
			var start_place := _locals_at(main, rig, 0.0, main_tracks)[root].origin
			height_before = end_place.dot(up)
			across = end_place - start_place
			across -= up * across.dot(up)
		var hold := bool(part.get("hold", false))
		var dive := bool(part.get("dive", false))
		var speed := maxf(float(part.get("speed", 1.0)), 0.01)
		var length := main.length / speed
		var twist: Dictionary = (part.get("twist", {}) as Dictionary).duplicate()
		if twist.has("step_clip") and source.has_animation(StringName(String(twist["step_clip"]))):
			twist["step_anim"] = source.get_animation(StringName(String(twist["step_clip"])))
		return _baked_poses(rig, prefix, length, func(time: float) -> Array[Transform3D]:
			var pose := _locals_at(main, rig, minf(time * speed, main.length), main_tracks)
			if not twist.is_empty():
				_twist_pose(pose, rig, twist, time, length)
			if root >= 0:
				pose[root].origin += across
			if root >= 0 and (hold or dive):
				var own := pose[root].origin.dot(up)
				var height := height_before
				if dive:
					height = height_before * (1.0 - time / maxf(length, 0.001))
				pose[root].origin += up * (height - own)
			return pose)
	var main_tracks := _track_map(main)
	var legs_name := String(part.get("legs", ""))
	if not source.has_animation(StringName(legs_name)):
		return null
	var legs := source.get_animation(StringName(legs_name))
	var legs_tracks := _track_map(legs)
	var other: Animation = null
	var other_tracks := {}
	if source.has_animation(StringName(String(part.get("legs_mix", "")))):
		other = source.get_animation(StringName(String(part["legs_mix"])))
		other_tracks = _track_map(other)
	var mix := clampf(float(part.get("mix", 0.5)), 0.0, 1.0)
	var lower: Array[bool] = []
	for bone in rig.get_bone_count():
		lower.append(_is_lower(rig.get_bone_name(bone)))
	var seconds := float(part.get("seconds", main.length))
	return _baked_poses(rig, prefix, seconds, func(time: float) -> Array[Transform3D]:
		var up := _locals_at(main, rig, minf(time, main.length), main_tracks)
		var down := _locals_at(legs, rig, fmod(time, maxf(legs.length, 0.001)), legs_tracks)
		if other != null:
			var down_2 := _locals_at(other, rig, fmod(time, maxf(other.length, 0.001)), other_tracks)
			for bone in down.size():
				down[bone] = Transform3D(Basis(down[bone].basis.get_rotation_quaternion().slerp(
					down_2[bone].basis.get_rotation_quaternion(), mix)), down[bone].origin.lerp(down_2[bone].origin, mix))
		for bone in up.size():
			if lower[bone]:
				up[bone] = down[bone]
		return up)


# 2026-11-22 (the user's deflect, off Block_Hold). Seen from the skeleton,
# each a turn about its own axes, put on a bone in its parent's frame:
#   "yaw" / "lean" (degrees): the upper body from the waist (spine_01..03
#     share them), + counter-clockwise from above / + to the body's left;
#   "hand": the sword hand about the up axis;
#   "tip_drop": the sword hand tipped so the blade's tip goes down by that
#     much (the hilt high, a hanging parry: the blow slides down the blade);
#   "pivot": the whole body about "pivot_foot", which stays (the root bone
#     turned and moved round it);
#   "sink" (metres): the hips lowered, both legs bent to keep the feet where
#     they are (the weight settled onto the braced leg);
# all easing in over "in" seconds after "delay", held, and back over the
# last "out". The feet are not touched by these.
# "step" ("l" / "r": the leg_bones side) steps that foot first, from the
# start: over "foot_in" it goes to "step_target" -- (right, back) metres from
# the pivot foot, in the stance's own frame -- lifted on the way as high as
# "step_clip"'s heel is off the ground between "step_from" and "step_to"
# (seconds, wrapping round its end; else "lift" at the middle), the ankle
# and toes turned as that clip turns them; and back the same way over the
# last "out". The leg is bent to the foot every frame (_reach), so a foot
# that has landed stays put while the body turns above it.
static func _twist_pose(pose: Array[Transform3D], rig: Skeleton3D, spec: Dictionary, time: float, length: float) -> void:
	var rise := maxf(float(spec.get("in", 0.1)), 0.001)
	var fall := maxf(float(spec.get("out", 0.1)), 0.001)
	var delay := maxf(float(spec.get("delay", 0.0)), 0.0)
	var going_back := 1.0 - smoothstep(0.0, 1.0, (time - (length - fall)) / fall)
	var share := smoothstep(0.0, 1.0, (time - delay) / rise) * going_back
	var foot_rise := maxf(float(spec.get("foot_in", rise)), 0.001)
	var foot_share := smoothstep(0.0, 1.0, time / foot_rise) * going_back
	if share <= 0.0 and foot_share <= 0.0:
		return
	var axes := _body_axes()
	var up: Vector3 = axes[0]
	var right: Vector3 = axes[1]
	var forward := up.cross(right).normalized()
	var base := _globals_of(rig, pose)
	# The whole body round the pivot foot.
	var pivot_deg := float(spec.get("pivot", 0.0))
	var root := rig.find_bone(String(profile().get("root_bone", "root")))
	var pivot_foot := rig.find_bone(String(spec.get("pivot_foot", "foot_r")))
	if pivot_deg != 0.0 and root >= 0 and pivot_foot >= 0:
		var at := base[pivot_foot].origin
		var whole := Basis(up, deg_to_rad(pivot_deg) * share)
		pose[root] = Transform3D((whole * pose[root].basis).orthonormalized(), at + whole * (pose[root].origin - at))
	# The hips lowered; the planted foot bent back to where it stood.
	var sink := float(spec.get("sink", 0.0)) * share
	var hips := rig.find_bone(String((profile().get("named_bones", {}) as Dictionary).get("hips", "pelvis")))
	var legs_all: Dictionary = profile().get("leg_bones", {})
	if sink != 0.0 and hips >= 0 and pivot_foot >= 0:
		var turned := _globals_of(rig, pose)
		var hips_parent := rig.get_bone_parent(hips)
		var parent_basis := turned[hips_parent].basis if hips_parent >= 0 else Basis.IDENTITY
		pose[hips] = Transform3D(pose[hips].basis, pose[hips].origin + parent_basis.inverse() * (-up * sink))
		for leg_side: String in legs_all:
			var leg: Array = legs_all[leg_side]
			if String(leg[2]) != rig.get_bone_name(pivot_foot):
				continue
			var top := rig.find_bone(String(leg[0]))
			var mid := rig.find_bone(String(leg[1]))
			if top < 0 or mid < 0:
				continue
			var now_legs := _globals_of(rig, pose)
			var bend := now_legs[mid].origin - (now_legs[top].origin + now_legs[pivot_foot].origin) * 0.5
			_reach(rig, pose, top, mid, pivot_foot, turned[pivot_foot].origin,
				bend.normalized() if bend.length_squared() > 0.0001 else forward)
			_face(rig, pose, pivot_foot, turned[pivot_foot].basis)
	# The stepping foot.
	var legs: Dictionary = profile().get("leg_bones", {})
	var side := String(spec.get("step", ""))
	if legs.has(side) and spec.has("step_target") and pivot_foot >= 0:
		var bones: Array = legs[side]
		var thigh := rig.find_bone(String(bones[0]))
		var calf := rig.find_bone(String(bones[1]))
		var step_foot := rig.find_bone(String(bones[2]))
		var ball := rig.find_bone(String(bones[3])) if bones.size() > 3 else -1
		if thigh >= 0 and calf >= 0 and step_foot >= 0:
			var offset: Array = spec["step_target"]
			var from_place := base[step_foot].origin
			var to_place := base[pivot_foot].origin + right * float(offset[0]) - forward * float(offset[1])
			to_place += up * (from_place - to_place).dot(up)
			# How far along the step (0..1) while the foot is in the air.
			var along := -1.0
			if time < foot_rise:
				along = time / foot_rise
			elif time > length - fall:
				along = 1.0 - clampf((time - (length - fall)) / fall, 0.0, 1.0)
			var raise := 0.0
			var step_anim := spec.get("step_anim", null) as Animation
			var ref: Array[Transform3D] = []
			if along >= 0.0 and step_anim != null:
				var from := float(spec.get("step_from", 0.0))
				var clip_t := fmod(from + (float(spec.get("step_to", from)) - from) * along, step_anim.length)
				var tracks := _track_map(step_anim)
				ref = _locals_at(step_anim, rig, clip_t, tracks)
				var ground := _globals_of(rig, _locals_at(step_anim, rig, fmod(from, step_anim.length), tracks))[step_foot].origin.dot(up)
				raise = maxf(_globals_of(rig, ref)[step_foot].origin.dot(up) - ground, 0.0)
			elif along >= 0.0:
				raise = float(spec.get("lift", 0.0)) * sin(PI * along)
			var target := from_place.lerp(to_place, foot_share) + up * raise
			var now := _globals_of(rig, pose)
			var knee_out := now[calf].origin - (now[thigh].origin + now[step_foot].origin) * 0.5
			if knee_out.length_squared() < 0.0001:
				knee_out = forward
			_reach(rig, pose, thigh, calf, step_foot, target, knee_out.normalized())
			if ref.is_empty():
				# Landed: the foot keeps lying as it lay, the leg bent above it.
				_face(rig, pose, step_foot, now[step_foot].basis)
			else:
				pose[step_foot] = Transform3D(ref[step_foot].basis, pose[step_foot].origin)
				if ball >= 0:
					pose[ball] = Transform3D(ref[ball].basis, pose[ball].origin)
	# The upper body and the hand.
	var spine := ["spine_01", "spine_02", "spine_03"]
	var yaw := deg_to_rad(float(spec.get("yaw", 0.0))) * share / float(spine.size())
	var lean := deg_to_rad(float(spec.get("lean", 0.0))) * share / float(spine.size())
	var turns := {}
	for bone_name: String in spine:
		turns[bone_name] = Basis(up, yaw) * Basis(forward, -lean)
	turns["hand_r"] = Basis(up, deg_to_rad(float(spec.get("hand", 0.0))) * share)
	var globals := _globals_of(rig, pose)
	for bone_name: String in turns:
		var bone := rig.find_bone(bone_name)
		if bone < 0:
			continue
		var parent := rig.get_bone_parent(bone)
		var parent_basis := globals[parent].basis.orthonormalized() if parent >= 0 else Basis.IDENTITY
		var local_turn := parent_basis.inverse() * (turns[bone_name] as Basis) * parent_basis
		pose[bone] = Transform3D((local_turn * pose[bone].basis).orthonormalized(), pose[bone].origin)
	# 2026-11-22 (the user: the whole body, not a twist on the guard): the
	# head kept on the foe ("head", degrees about up, against the turn), and
	# the arms put where the end pose has them -- "arm_r" / "arm_l": {"at":
	# [right, up, forward] metres from the hips, "blade": [right, up, forward]
	# the way the blade points (right arm only)}, both in the body's frame once
	# turned by the whole "pivot" -- eased there from the clip's own by share,
	# the elbows bent by _reach.
	var head_bone := rig.find_bone("neck_01")
	if head_bone >= 0 and spec.has("head"):
		var now_head := _globals_of(rig, pose)
		var neck_parent := rig.get_bone_parent(head_bone)
		var neck_basis := now_head[neck_parent].basis.orthonormalized()
		var neck_turn := neck_basis.inverse() * Basis(up, deg_to_rad(float(spec["head"])) * share) * neck_basis
		pose[head_bone] = Transform3D((neck_turn * pose[head_bone].basis).orthonormalized(), pose[head_bone].origin)
	var end_turn := Basis(up, deg_to_rad(pivot_deg))
	var end_right := end_turn * right
	var end_forward := end_turn * forward
	for arm_side: String in ["r", "l"]:
		var arm_key := "arm_" + arm_side
		if not spec.has(arm_key) or hips < 0:
			continue
		var arm: Dictionary = spec[arm_key]
		var upper := rig.find_bone("upperarm_" + arm_side)
		var lower := rig.find_bone("lowerarm_" + arm_side)
		var wrist := rig.find_bone("hand_" + arm_side)
		if upper < 0 or lower < 0 or wrist < 0:
			continue
		var now_arm := _globals_of(rig, pose)
		var at: Array = arm.get("at", [0.0, 0.0, 0.0])
		var wanted: Vector3 = now_arm[hips].origin + end_right * float(at[0]) + up * float(at[1]) + end_forward * float(at[2])
		var hand_target: Vector3 = now_arm[wrist].origin.lerp(wanted, share)
		var side_sign := 1.0 if arm_side == "r" else -1.0
		var elbow: Vector3 = (-up + end_right * side_sign * 0.6 - end_forward * 0.3).normalized()
		_reach(rig, pose, upper, lower, wrist, hand_target, elbow)
		if arm.has("blade") and arm_side == "r":
			var held_now := _globals_of(rig, pose)
			var weapon_bone := rig.find_bone(hand_bone())
			if weapon_bone >= 0:
				var b: Array = arm["blade"]
				var want_blade: Vector3 = (end_right * float(b[0]) + up * float(b[1]) + end_forward * float(b[2])).normalized()
				var have_blade: Vector3 = held_now[weapon_bone].basis.x.normalized()
				var toward_blade := have_blade.slerp(want_blade, share).normalized()
				if have_blade.cross(toward_blade).length_squared() > 0.000001:
					var swing := Basis(Quaternion(have_blade, toward_blade))
					_face(rig, pose, wrist, swing * held_now[wrist].basis.orthonormalized())
	# The tip down, the hilt up: the hand turned about the level line across
	# the blade (the blade runs along the weapon bone's +X).
	var drop := deg_to_rad(float(spec.get("tip_drop", 0.0))) * share
	var hand := rig.find_bone("hand_r")
	var weapon := rig.find_bone(hand_bone())
	if drop != 0.0 and hand >= 0 and weapon >= 0:
		var held := _globals_of(rig, pose)
		var blade := held[weapon].basis.x.normalized()
		var across := blade.cross(-up)
		if across.length_squared() > 0.0001:
			var hand_parent := rig.get_bone_parent(hand)
			var parent_basis := held[hand_parent].basis.orthonormalized() if hand_parent >= 0 else Basis.IDENTITY
			var local_turn := parent_basis.inverse() * Basis(across.normalized(), drop) * parent_basis
			pose[hand] = Transform3D((local_turn * pose[hand].basis).orthonormalized(), pose[hand].origin)


# A rotation and a position track for every bone, `sample` (time -> local
# poses) taken every MOTION_SAMPLE.
static func _baked_poses(rig: Skeleton3D, prefix: String, length: float, sample: Callable) -> Animation:
	var out := Animation.new()
	out.length = maxf(length, MOTION_SAMPLE)
	var turns: Array[int] = []
	var moves: Array[int] = []
	for bone in rig.get_bone_count():
		var path := NodePath("%s:%s" % [prefix, rig.get_bone_name(bone)])
		turns.append(out.add_track(Animation.TYPE_ROTATION_3D))
		out.track_set_path(turns[bone], path)
		moves.append(out.add_track(Animation.TYPE_POSITION_3D))
		out.track_set_path(moves[bone], path)
	var count := int(ceil(out.length / MOTION_SAMPLE - 0.001))
	for index in count + 1:
		var time := minf(index * MOTION_SAMPLE, out.length)
		var locals: Array[Transform3D] = sample.call(time)
		for bone in locals.size():
			out.rotation_track_insert_key(turns[bone], time, locals[bone].basis.get_rotation_quaternion())
			out.position_track_insert_key(moves[bone], time, locals[bone].origin)
	return out


# Turns `back` about the skeleton's up axis (its root bone's rotation keys)
# so that its first frame's hips face the way `before`'s hips do at `at`:
# the blend from the one into the other then has nothing to turn through.
static func _face_like(back: Animation, before: Animation, at: float, rig: Skeleton3D) -> void:
	var axes := _body_axes()
	var root_bone := String(profile().get("root_bone", "Hips"))
	var want := _hips_bearing(_globals_of(rig, _locals_at(before, rig, at, _track_map(before))), rig, axes[0], axes[1])
	var tracks := _track_map(back)
	if not tracks.has(root_bone + "/r"):
		return
	var track := int(tracks[root_bone + "/r"])
	var originals: Array[Quaternion] = []
	for key in back.track_get_key_count(track):
		originals.append(back.track_get_key_value(track, key) as Quaternion)
	var have := _hips_bearing(_globals_of(rig, _locals_at(back, rig, 0.0, tracks)), rig, axes[0], axes[1])
	var turn := deg_to_rad(wrapf(want - have, -180.0, 180.0))
	# Which way a turn about `up` moves the bearing is the rig's: tried, and
	# turned the other way if it went the wrong way.
	for attempt in 2:
		var by := Quaternion(axes[0], turn if attempt == 0 else -turn)
		for key in originals.size():
			back.track_set_key_value(track, key, by * originals[key])
		var got := _hips_bearing(_globals_of(rig, _locals_at(back, rig, 0.0, tracks)), rig, axes[0], axes[1])
		if absf(wrapf(want - got, -180.0, 180.0)) < 2.0:
			break
	# And it ends facing the way the stance does (the profile's idle clip,
	# first frame: what the next step starts from): what is left over is
	# spread along it, nothing at its first frame, all of it at its last.
	var idle_spec: Dictionary = (profile().get("library_clips", {}) as Dictionary).get(
		String((profile().get("clips", {}) as Dictionary).get("idle", "")), {})
	var library := load(String(profile().get("library", ""))) as AnimationLibrary
	var ends_at := 0.0
	if not idle_spec.is_empty() and library != null:
		var idle := library.get_animation(StringName(String(idle_spec["source"])))
		var stance := _hips_bearing(_globals_of(rig, _locals_at(idle, rig, 0.0, _track_map(idle))), rig, axes[0], axes[1])
		var started: Array[Quaternion] = []
		for key in back.track_get_key_count(track):
			started.append(back.track_get_key_value(track, key) as Quaternion)
		var got_end := _hips_bearing(_globals_of(rig, _locals_at(back, rig, back.length, tracks)), rig, axes[0], axes[1])
		var left_over := deg_to_rad(wrapf(stance - got_end, -180.0, 180.0))
		for attempt in 2:
			for key in started.size():
				var share := back.track_get_key_time(track, key) / maxf(back.length, 0.001)
				var by := Quaternion(axes[0], (left_over if attempt == 0 else -left_over) * share)
				back.track_set_key_value(track, key, by * started[key])
			ends_at = _hips_bearing(_globals_of(rig, _locals_at(back, rig, back.length, tracks)), rig, axes[0], axes[1])
			if absf(wrapf(stance - ends_at, -180.0, 180.0)) < 2.0:
				break
	print("PLAYGROUND_CLIP_BACK hips at the blow %.0f deg, the back clip's first frame %.0f -> turned %.0f deg; ends at %.0f" % [
		want, have, rad_to_deg(turn), ends_at])


# 2026-11-21 (the user: "spin round on the left foot in one go, not walk
# round"): a way back made here, `pivot` {"foot", "seconds"}. Every bone eases
# (smoothstep) from `before` at `at` -- the blow's last frame -- into the
# stance (the profile's idle clip, first frame), so the hips spin from where
# the blow left them to the front; the spin goes the way the clip's own
# follow-through went, the short way round if that is the way, else the long
# way (a whole turn added to the root, nothing at its first frame). The root
# does not travel; the body does, by _pivot_paths: round the pivot foot, so
# that foot stays where it is (and is held there, _study_feet).
#
# 2026-11-22 (the user: "2nd, spin, 3rd in one go"): with a `target`, the
# spin runs into that clip at `target_at` instead of the stance, at one speed
# all the way (slowing at neither end). Every bone on the straight way
# (slerp) between the two poses: a cubic through the frames either side was
# tried first and bent the body out of shape mid-spin (2026-11-22).
static func _pivot_clip(clip: String, before: Animation, at: float, rig: Skeleton3D, pivot: Dictionary,
		target: Animation = null, target_at := 0.0) -> Animation:
	var linked := target != null
	if not linked:
		var idle_spec: Dictionary = (profile().get("library_clips", {}) as Dictionary).get(
			String((profile().get("clips", {}) as Dictionary).get("idle", "")), {})
		var library := load(String(profile().get("library", ""))) as AnimationLibrary
		if idle_spec.is_empty() or library == null:
			return null
		target = library.get_animation(StringName(String(idle_spec["source"])))
		target_at = 0.0
	var seconds := maxf(float(pivot.get("seconds", 0.4)), MOTION_SAMPLE * 2.0)
	var axes := _body_axes()
	var before_tracks := _track_map(before)
	var target_tracks := _track_map(target)
	var start := _locals_at(before, rig, at, before_tracks)
	var stance := _locals_at(target, rig, target_at, target_tracks)
	var root := rig.find_bone(String(profile().get("root_bone", "Hips")))
	var h_start := _hips_bearing(_globals_of(rig, start), rig, axes[0], axes[1])
	var h_stance := _hips_bearing(_globals_of(rig, stance), rig, axes[0], axes[1])
	var h_later := _hips_bearing(_globals_of(rig, _locals_at(before, rig, minf(at + 0.3, before.length), before_tracks)),
		rig, axes[0], axes[1])
	var way := signf(wrapf(h_later - h_start, -180.0, 180.0))
	if way == 0.0:
		way = -1.0
	# "turn": "ccw" / "cw" as seen from above, whatever the follow-through
	# does (the rising cut's spin is counter-clockwise, the user's call
	# 2026-11-21). A rising bearing is counter-clockwise from above.
	match String(pivot.get("turn", "")):
		"ccw":
			way = 1.0
		"cw":
			way = -1.0
	var short := wrapf(h_stance - h_start, -180.0, 180.0)
	var whole := 0.0 if signf(short) == way else way * 360.0
	if bool(pivot.get("whole", false)):
		# A whole turn on top, whichever way is short (two poses facing alike).
		whole = way * 360.0
	# Which way a turn about `up` moves the bearing, on this rig.
	var tried := stance.duplicate()
	tried[root] = Transform3D(Basis(Quaternion(axes[0], deg_to_rad(10.0))) * stance[root].basis, stance[root].origin)
	var sense := signf(wrapf(_hips_bearing(_globals_of(rig, tried), rig, axes[0], axes[1]) - h_stance, -180.0, 180.0))
	var prefix := String(before.track_get_path(0)).get_slice(":", 0)
	var out := Animation.new()
	out.length = seconds
	var count := int(ceil(seconds / MOTION_SAMPLE - 0.001))
	for bone in rig.get_bone_count():
		var turns := out.add_track(Animation.TYPE_ROTATION_3D)
		out.track_set_path(turns, NodePath("%s:%s" % [prefix, rig.get_bone_name(bone)]))
		var moves := out.add_track(Animation.TYPE_POSITION_3D)
		out.track_set_path(moves, NodePath("%s:%s" % [prefix, rig.get_bone_name(bone)]))
		var from_turn := start[bone].basis.get_rotation_quaternion()
		var to_turn := stance[bone].basis.get_rotation_quaternion()
		for index in count + 1:
			var time := minf(index * MOTION_SAMPLE, seconds)
			# Linked: at one speed all the way, so it slows at neither end.
			var eased := time / seconds if linked else smoothstep(0.0, 1.0, time / seconds)
			var turn := from_turn.slerp(to_turn, eased)
			var place := start[bone].origin.lerp(stance[bone].origin, eased)
			if bone == root:
				# Starts a whole turn behind, so the turn itself adds `whole` to the
				# bearing (2026-11-21: the sign was the wrong way, the spin ran
				# 518 deg clockwise for the 202 counter-clockwise it said).
				turn = Quaternion(axes[0], deg_to_rad(-sense * whole * (1.0 - eased))) * turn
				place = start[bone].origin
			out.rotation_track_insert_key(turns, time, turn)
			out.position_track_insert_key(moves, time, place)
	# The body's way round the pivot foot.
	var legs: Dictionary = profile().get("leg_bones", {})
	var side := String(pivot.get("foot", "l"))
	var path := PackedVector3Array()
	if legs.has(side):
		var foot := rig.find_bone(String((legs[side] as Array)[2]))
		var forward := _measured_forward if _measured_forward.length_squared() > 0.0001 else Vector3.FORWARD
		var right := forward.cross(Vector3.UP).normalized()
		var metre := Player.BODY_HALF_HEIGHT * 2.0 / model_height()
		var tracks := _track_map(out)
		var first := Vector3.INF
		for index in count + 1:
			var globals := _globals_of(rig, _locals_at(out, rig, minf(index * MOTION_SAMPLE, seconds), tracks))
			var place := _skeleton_in_model.basis * (globals[foot].origin - globals[root].origin) * metre
			var flat := Vector3(place.dot(right), 0.0, place.dot(forward))
			if first == Vector3.INF:
				first = flat
			path.append(first - flat)
		_pivot_paths[clip] = path
		_pivot_feet[clip] = side
	# The spin as it comes out, bearing step by step (+ = counter-clockwise
	# from above).
	var spun := 0.0
	var out_tracks := _track_map(out)
	var last := h_start
	for index in range(1, count + 1):
		var now := _hips_bearing(_globals_of(rig, _locals_at(out, rig, minf(index * MOTION_SAMPLE, seconds), out_tracks)),
			rig, axes[0], axes[1])
		spun += wrapf(now - last, -180.0, 180.0)
		last = now
	print("PLAYGROUND_CLIP_PIVOT clip=%s on the %s foot, %.2f s: hips %.0f -> %.0f deg, meant %+.0f deg, measured %+.0f deg (%s from above), the body goes round %.2f m" % [
		clip, side, seconds, h_start, h_stance, short + whole, spun, "counter-clockwise" if spun > 0.0 else "clockwise",
		path[path.size() - 1].length() if not path.is_empty() else 0.0])
	return out


static func _time_blade(library: AnimationLibrary, clip: String, source: String, animation: Animation, rig: Skeleton3D,
		pass_index := -1, back_clip: Animation = null, then_clip: Animation = null, pivot: Dictionary = {}) -> Animation:
	var study := _blade_study(animation, rig)
	_print_study(clip, source, animation, study)
	if study.is_empty() or (study["passes"] as Array).is_empty():
		return animation
	var times: Array[float] = study["times"]
	var passes: Array = study["passes"]
	var splits: Array[int] = study["splits"]
	var chosen := int(study["fastest"]) if pass_index < 0 else pass_index
	if chosen >= passes.size():
		print("PLAYGROUND_CLIP_BLADE clip=%s source=%s: %d번째 칼 지나감이 없음 (%d번뿐), 가장 빠른 것으로" % [
			clip, source, chosen + 1, passes.size()])
		chosen = int(study["fastest"])
	var part_from := times[splits[chosen - 1]] if chosen > 0 and pass_index >= 0 else 0.0
	var pass_from := times[int(passes[chosen][0])]
	var pass_to := times[int(passes[chosen][1])]
	var back_to := times[splits[chosen]] if chosen < splits.size() else animation.length
	_timed_full[clip] = animation
	# 2026-11-22: "lead" {"from", "into", "foot", "seconds", "turn"}: the clip
	# is only ever played straight after `from`'s blow, and begins with a spin
	# made here (_pivot_clip, linked) out of that blow's last frame into this
	# clip `into` seconds in, at speed both ends; the clip plays on from there.
	var lead: Animation = null
	var lead_spec: Dictionary = ((profile().get("library_clips", {}) as Dictionary).get(clip, {}) as Dictionary).get("lead", {})
	if not lead_spec.is_empty():
		var other := String(lead_spec.get("from", ""))
		if _timed_full.has(other) and _blade_parts.has(other):
			var into := clampf(float(lead_spec.get("into", 0.0)), 0.0, maxf(pass_from - MOTION_SAMPLE * 2.0, 0.0))
			lead = _pivot_clip(clip + "_lead", _timed_full[other], float((_blade_parts[other] as Dictionary)["pass_to"]),
				rig, lead_spec, animation, into)
			if lead != null:
				part_from = into
		else:
			push_error("CharacterVisual: %s leads in from %s, which is not timed before it" % [clip, other])
	var lead_seconds := lead.length if lead != null else 0.0
	if not pivot.is_empty():
		# 2026-11-21: the way back is a spin made here (_pivot_clip).
		back_clip = _pivot_clip(clip, animation, pass_to, rig, pivot)
	elif back_clip != null:
		# 2026-11-21: a way back from elsewhere ("back_clip"), turned about
		# the up axis so it begins facing the way the blow left the hips.
		_face_like(back_clip, animation, pass_to, rig)
	if back_clip != null:
		var back := clip + "_end"
		library.add_animation(back, back_clip)
		_clip_lengths[back] = back_clip.length
		_auto_recoveries[clip] = back
		_raw_backs[clip] = back_clip
		_auto_strikes[clip] = pass_from - part_from + lead_seconds
		_blade_parts[clip] = {"part_from": part_from, "pass_from": pass_from, "pass_to": pass_to,
			"back_to": pass_to + back_clip.length, "lead": lead_seconds}
		return _led(lead, _cut(animation, part_from, pass_to))
	if back_to > pass_to + 0.05:
		var back := clip + "_end"
		var tail := _cut(animation, pass_to, back_to)
		if then_clip != null:
			# 2026-11-21: and after the clip's own way back, another clip
			# ("then_clip": the rising cut's landing), facing on from it.
			_face_like(then_clip, tail, tail.length, rig)
			tail = _joined(tail, then_clip)
			back_to += then_clip.length
		library.add_animation(back, tail)
		_clip_lengths[back] = tail.length
		_auto_recoveries[clip] = back
	_auto_strikes[clip] = pass_from - part_from + lead_seconds
	_blade_parts[clip] = {"part_from": part_from, "pass_from": pass_from, "pass_to": pass_to,
		"back_to": back_to if back_to > pass_to + 0.05 else pass_to, "lead": lead_seconds}
	return _led(lead, _cut(animation, part_from, pass_to))


# 2026-11-22: _time_blade's bookkeeping for a clip whose blow is known rather
# than read off its blade (a composed clip: the landing of the rising cut's
# dive). Played up to the blow's end; the rest is its way back.
static func _time_given(library: AnimationLibrary, clip: String, animation: Animation, pass_from: float,
		pass_to: float) -> Animation:
	pass_to = minf(pass_to, animation.length)
	_timed_full[clip] = animation
	if animation.length > pass_to + 0.05:
		var back := clip + "_end"
		var tail := _cut(animation, pass_to, animation.length)
		library.add_animation(back, tail)
		_clip_lengths[back] = tail.length
		_auto_recoveries[clip] = back
	_auto_strikes[clip] = pass_from
	_blade_parts[clip] = {"part_from": 0.0, "pass_from": pass_from, "pass_to": pass_to,
		"back_to": animation.length, "lead": 0.0}
	print("PLAYGROUND_CLIP_BLADE clip=%s (composed) blow %.3f..%.3f s of %.3f s" % [clip, pass_from, pass_to, animation.length])
	return _cut(animation, 0.0, pass_to)


# The root bone's place put back on its rest all through (after
# _strip_travel "body", which holds it on its first frame: for a clip that
# does not start on the ground that frame is off the rest).
static func _rest_root(animation: Animation, rig: Skeleton3D, root_bone: String) -> void:
	var root := rig.find_bone(root_bone)
	if root < 0:
		return
	var rest := rig.get_bone_rest(root).origin
	for track in animation.get_track_count():
		if animation.track_get_type(track) == Animation.TYPE_POSITION_3D \
				and String(animation.track_get_path(track).get_subname(0)) == root_bone:
			for key in animation.track_get_key_count(track):
				animation.track_set_key_value(track, key, rest)


static func _led(lead: Animation, head: Animation) -> Animation:
	return head if lead == null else _joined(lead, head)


# 2026-11-21: a timed library clip's motion, for SkillDef "Motion" (written by
# tools/sword_animset/bake.tscn): its windup, swing and recovery (seconds of
# the clip at its own speed: the part before the blade's pass, the pass, the
# way back) and the root bone's path over all three, sampled every
# MOTION_SAMPLE, as (right, up, forward) metres at the human capsule from
# where the part begins, and its turn about the up axis (degrees, + left).
# {} for a clip that was not timed. Needs the model loaded once (the
# skeleton's place and the facing are measured then).
const MOTION_SAMPLE := 1.0 / 30.0


static func baked_motion(clip: String) -> Dictionary:
	if not _blade_parts.has(clip) or not _raw_sources.has(clip):
		return {}
	var parts: Dictionary = _blade_parts[clip]
	var source := _raw_sources[clip] as Animation
	var root_bone := String(profile().get("root_bone", "Hips"))
	var moves := -1
	var turns := -1
	for track in source.get_track_count():
		if String(source.track_get_path(track).get_subname(0)) != root_bone:
			continue
		if source.track_get_type(track) == Animation.TYPE_POSITION_3D:
			moves = track
		elif source.track_get_type(track) == Animation.TYPE_ROTATION_3D:
			turns = track
	var from := float(parts["part_from"])
	var to := float(parts["back_to"])
	var skeleton_basis := _skeleton_in_model.basis
	var turn_basis := skeleton_basis.orthonormalized()
	var forward := _measured_forward if _measured_forward.length_squared() > 0.0001 else Vector3.FORWARD
	var right := forward.cross(Vector3.UP).normalized()
	var metre := Player.BODY_HALF_HEIGHT * 2.0 / model_height()
	# A clip with a lead spin is measured off its own first frame, as it was
	# before it had one (the crouch it starts into is in the height).
	var lead := float(parts.get("lead", 0.0))
	var reference := 0.0 if lead > 0.0 else from
	var start_place := source.position_track_interpolate(moves, reference) if moves >= 0 else Vector3.ZERO
	var start_turn := source.rotation_track_interpolate(turns, reference) if turns >= 0 else Quaternion.IDENTITY
	var times := PackedFloat32Array()
	var path := PackedVector3Array()
	var yaw := PackedFloat32Array()
	var time := from
	var pass_to := float(parts["pass_to"])
	var turned_back := _raw_backs.has(clip)
	var blow_moved := Vector3.ZERO
	while true:
		var at := minf(time, to)
		var moved := Vector3.ZERO
		if turned_back and at > pass_to:
			# A way back from elsewhere turns on the spot, its turn the
			# model's own (its root's): the body stays where the blow left it
			# -- or, for a pivot, goes round the pivot foot.
			var round_foot := Vector3.ZERO
			if _pivot_paths.has(clip):
				var steps := _pivot_paths[clip] as PackedVector3Array
				round_foot = steps[clampi(int(round((at - pass_to) / MOTION_SAMPLE)), 0, steps.size() - 1)]
			times.append(at)
			path.append(Vector3(blow_moved.dot(right), blow_moved.y, blow_moved.dot(forward)) * metre + round_foot)
			yaw.append(yaw[yaw.size() - 1] if not yaw.is_empty() else 0.0)
			if at >= to:
				break
			time += MOTION_SAMPLE
			continue
		if moves >= 0:
			moved = skeleton_basis * (source.position_track_interpolate(moves, at) - start_place)
		blow_moved = moved
		var bearing := 0.0
		if turns >= 0:
			var turned := Basis(source.rotation_track_interpolate(turns, at) * start_turn.inverse())
			var faced := turn_basis * turned * turn_basis.inverse() * forward
			faced.y = 0.0
			if faced.length_squared() > 0.0001:
				bearing = rad_to_deg(forward.signed_angle_to(faced.normalized(), Vector3.UP))
		times.append(at)
		path.append(Vector3(moved.dot(right), moved.y, moved.dot(forward)) * metre)
		yaw.append(bearing)
		if at >= to:
			break
		time += MOTION_SAMPLE
	_hold_ground(clip, times, path)
	if lead > 0.0:
		# The lead spin first: round the pivot foot, easing into the height and
		# turn the clip starts at; the clip's own path after it, from where the
		# spin left the body.
		var steps := _pivot_paths.get(clip + "_lead", PackedVector3Array()) as PackedVector3Array
		var n := int(round(lead / MOTION_SAMPLE))
		var round_end := steps[steps.size() - 1] if not steps.is_empty() else Vector3.ZERO
		var lead_times := PackedFloat32Array()
		var lead_path := PackedVector3Array()
		var lead_yaw := PackedFloat32Array()
		for index in n:
			var share := smoothstep(0.0, 1.0, float(index) / n)
			lead_times.append(from - lead + index * MOTION_SAMPLE)
			var round_foot := steps[mini(index, steps.size() - 1)] if not steps.is_empty() else Vector3.ZERO
			lead_path.append(round_foot + Vector3(path[0].x, path[0].y, path[0].z) * share)
			lead_yaw.append(yaw[0] * share)
		for index in path.size():
			path[index] += round_end
		lead_times.append_array(times)
		lead_path.append_array(path)
		lead_yaw.append_array(yaw)
		times = lead_times
		path = lead_path
		yaw = lead_yaw
	var out := {
		"windup": float(parts["pass_from"]) - from + lead,
		"swing": float(parts["pass_to"]) - float(parts["pass_from"]),
		"recovery": to - float(parts["pass_to"]),
		"times": times, "path": path, "yaw": yaw,
		"return_foot": "", "return_move": Vector3.ZERO,
	}
	var specs: Dictionary = profile().get("library_clips", {})
	if bool((specs.get(clip, {}) as Dictionary).get("return", false)):
		out.merge(_return_step(clip, to), true)
	return out


# 2026-11-21: the step back into the stance after a clip that does not end in
# it (SkillDef motion_return_*): the foot further forward at the clip's last
# frame (`at`, seconds of the source) stays; the body goes where the stance
# (the profile's idle clip, first frame) would have that foot exactly there.
# Feet against the root, metres at the capsule, (right, 0, forward).
static func _return_step(clip: String, at: float) -> Dictionary:
	var legs: Dictionary = profile().get("leg_bones", {})
	var specs: Dictionary = profile().get("library_clips", {})
	var idle_spec: Dictionary = specs.get(String((profile().get("clips", {}) as Dictionary).get("idle", "")), {})
	var library := load(String(profile().get("library", ""))) as AnimationLibrary
	var model := load(String(profile()["model"])) as PackedScene
	if legs.is_empty() or idle_spec.is_empty() or library == null or model == null:
		return {}
	var idle := library.get_animation(StringName(String(idle_spec["source"])))
	var holder := model.instantiate()
	var rig := holder.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	var forward := _measured_forward if _measured_forward.length_squared() > 0.0001 else Vector3.FORWARD
	var right := forward.cross(Vector3.UP).normalized()
	var metre := Player.BODY_HALF_HEIGHT * 2.0 / model_height()
	var root := rig.find_bone(String(profile().get("root_bone", "Hips")))
	var feet := {}
	for name_text: String in ["end", "stance"]:
		var animation := _raw_sources[clip] as Animation if name_text == "end" else idle
		var globals := _globals_of(rig, _locals_at(animation, rig, at if name_text == "end" else 0.0, _track_map(animation)))
		for side: String in ["l", "r"]:
			var foot := rig.find_bone(String((legs[side] as Array)[2]))
			var place := _skeleton_in_model.basis * (globals[foot].origin - globals[root].origin) * metre
			feet[name_text + side] = Vector3(place.dot(right), 0.0, place.dot(forward))
	holder.free()
	var kept := "l" if (feet["endl"] as Vector3).z >= (feet["endr"] as Vector3).z else "r"
	var move := (feet["end" + kept] as Vector3) - (feet["stance" + kept] as Vector3)
	print("PLAYGROUND_CLIP_RETURN clip=%s keeps %s foot, the body steps (%.2f right, %.2f forward) m; feet at the end l %s r %s, the stance's l %s r %s" % [
		clip, kept, move.x, move.z, feet["endl"], feet["endr"], feet["stancel"], feet["stancer"]])
	return {"return_foot": kept, "return_move": move}


# 2026-11-21: a library clip's "hold": part of its path kept where it is
# across the ground (the height is left alone). "after_blow": from the end
# of the blade's pass on. "until_air": until both feet have left the ground
# (_leaves_ground), and from there on what it travels, from that point.
static func _hold_ground(clip: String, times: PackedFloat32Array, path: PackedVector3Array) -> void:
	var specs: Dictionary = profile().get("library_clips", {})
	var hold := String((specs.get(clip, {}) as Dictionary).get("hold", ""))
	if hold == "" or path.is_empty():
		return
	var parts: Dictionary = _blade_parts[clip]
	if hold == "after_blow":
		if _raw_backs.has(clip):
			# Its way back is another clip, which does not travel: the path
			# there is already where the body stays (baked_motion).
			return
		var pass_to := float(parts["pass_to"])
		var kept := Vector3.ZERO
		for index in times.size():
			if times[index] <= pass_to + 0.0001:
				kept = path[index]
			else:
				path[index] = Vector3(kept.x, path[index].y, kept.z)
	elif hold == "until_air":
		var air := float(_leaves_ground.get(clip, -1.0))
		if air < 0.0:
			push_error("CharacterVisual: %s never leaves the ground; its hold is not applied" % clip)
			return
		var at_air := Vector3.ZERO
		for index in times.size():
			if times[index] <= air + 0.0001:
				at_air = path[index]
				path[index] = Vector3(0.0, path[index].y, 0.0)
			else:
				path[index] = Vector3(path[index].x - at_air.x, path[index].y, path[index].z - at_air.z)


# 2026-11-21: which feet a timed clip has on the ground: the ball of the foot
# (the leg's fourth bone) within FOOT_DOWN_HEIGHT of where the rest pose has
# it, metres at the capsule. Height only: this pack slides its feet along
# the ground on purpose (03_03 skids them at up to 20 m/s), so a foot that
# is down is not a foot that is still. Kept as the moment both feet first
# leave the ground (_leaves_ground), and per played clip (_foot_contacts)
# only where the body is held off the clip's own travel (the "hold" span):
# a foot is held there and nowhere else, so a clip the body follows exactly
# keeps its own feet, skids and all. PLAYGROUND_CLIP_FEET prints it.
const FOOT_DOWN_HEIGHT := 0.06


static func _study_feet(clip: String, rig: Skeleton3D) -> void:
	var legs: Dictionary = profile().get("leg_bones", {})
	if legs.is_empty() or not _raw_sources.has(clip):
		return
	var source := _raw_sources[clip] as Animation
	var parts: Dictionary = _blade_parts[clip]
	var tracks := _track_map(source)
	var to_model := _skeleton_in_model.basis
	var metre := Player.BODY_HALF_HEIGHT * 2.0 / model_height()
	var feet := {}
	var ground := {}
	for side: String in ["l", "r"]:
		var bones: Array = legs[side]
		feet[side] = rig.find_bone(String(bones[3] if bones.size() > 3 else bones[2]))
		if int(feet[side]) < 0:
			return
		ground[side] = (to_model * rig.get_bone_global_rest(int(feet[side])).origin).y * metre
	var from := float(parts["part_from"])
	var to := float(parts["back_to"])
	var down := {"l": [], "r": []}
	var times := PackedFloat32Array()
	var time := from
	var blow_end := float(parts["pass_to"])
	var back := _raw_backs.get(clip, null) as Animation
	var back_tracks := _track_map(back) if back != null else {}
	while true:
		var at := minf(time, to)
		var globals: Array[Transform3D]
		if back != null and at > blow_end:
			# The way back from elsewhere, on its own clock.
			globals = _globals_of(rig, _locals_at(back, rig, at - blow_end, back_tracks))
		else:
			globals = _globals_of(rig, _locals_at(source, rig, at, tracks))
		for side: String in ["l", "r"]:
			var place := to_model * globals[int(feet[side])].origin * metre
			var is_down := place.y <= float(ground[side]) + FOOT_DOWN_HEIGHT
			(down[side] as Array).append(1 if is_down else 0)
		times.append(at)
		if at >= to:
			break
		time += MOTION_SAMPLE
	# Split as played: the clip up to the blade's pass end, then its "_end".
	var pass_to := float(parts["pass_to"])
	var head := {"l": [], "r": []}
	var tail := {"l": [], "r": []}
	var air := -1.0
	var pass_from := float(parts["pass_from"])
	var left_marks := down["l"] as Array
	var right_marks := down["r"] as Array
	for index in times.size() - 1:
		if times[index] >= pass_from - 0.3 \
				and int(left_marks[index]) == 0 and int(right_marks[index]) == 0 \
				and int(left_marks[index + 1]) == 0 and int(right_marks[index + 1]) == 0:
			air = times[index]
			break
	_leaves_ground[clip] = air
	var specs: Dictionary = profile().get("library_clips", {})
	var hold := String((specs.get(clip, {}) as Dictionary).get("hold", ""))
	for index in times.size():
		# 2026-11-21: not over a way back from elsewhere (the turn): it does
		# not travel, so the body held in place IS where it puts the feet --
		# and holding a foot that pivots on its ball twisted the leg.
		var held := (hold == "after_blow" and times[index] > pass_to + 0.0001 and back == null) \
			or (hold == "until_air" and air >= 0.0 and times[index] <= air + 0.0001)
		for side: String in ["l", "r"]:
			var mark := int((down[side] as Array)[index]) if held else 0
			if _pivot_feet.has(clip) and times[index] > pass_to + 0.0001:
				# A pivot: the pivot foot is held all the way round.
				mark = 1 if side == String(_pivot_feet[clip]) else 0
			if times[index] <= pass_to + 0.0001:
				(head[side] as Array).append(mark)
			else:
				(tail[side] as Array).append(mark)
	var lead := float(parts.get("lead", 0.0))
	if lead > 0.0:
		# The lead spin: the pivot foot held all the way round.
		var pivot_side := String(_pivot_feet.get(clip + "_lead", ""))
		for side: String in ["l", "r"]:
			var marks := []
			for index in int(round(lead / MOTION_SAMPLE)):
				marks.append(1 if side == pivot_side else 0)
			marks.append_array(head[side] as Array)
			head[side] = marks
	_foot_contacts[clip] = {"l": PackedByteArray(head["l"]), "r": PackedByteArray(head["r"])}
	if _auto_recoveries.has(clip):
		_foot_contacts[String(_auto_recoveries[clip])] = {"l": PackedByteArray(tail["l"]), "r": PackedByteArray(tail["r"])}
	var line := ""
	for side: String in ["l", "r"]:
		var marks := down[side] as Array
		var text := ""
		for mark in marks:
			text += "|" if mark == 1 else "."
		line += " %s %s" % [side, text]
	print("PLAYGROUND_CLIP_FEET clip=%s from %.2f s, one mark per %.3f s (| down . up), leaves the ground at %.2f s:%s" % [
		clip, from, MOTION_SAMPLE, air, line])


# PLAYGROUND_CLIP_GAP: the end of `first` against the start of `second`: the
# bone that differs most and by how much, and how far apart the hips face.
# Over GAP_WARN_DEG the blend between them shows as a slide.
const GAP_WARN_DEG := 30.0


static func _print_gap(first_name: String, first: Animation, second_name: String, second: Animation, rig: Skeleton3D) -> void:
	var a := _locals_at(first, rig, first.length, _track_map(first))
	var b := _locals_at(second, rig, 0.0, _track_map(second))
	var worst := 0.0
	var worst_bone := ""
	for bone in rig.get_bone_count():
		var bone_name := rig.get_bone_name(bone)
		if bone_name.begins_with("ik_") or bone == 0:
			continue
		var angle := rad_to_deg(a[bone].basis.get_rotation_quaternion().angle_to(b[bone].basis.get_rotation_quaternion()))
		if angle > worst:
			worst = angle
			worst_bone = bone_name
	var axes := _body_axes()
	var turn := wrapf(_hips_bearing(_globals_of(rig, b), rig, axes[0], axes[1])
		- _hips_bearing(_globals_of(rig, a), rig, axes[0], axes[1]), -180.0, 180.0)
	print("PLAYGROUND_CLIP_GAP %s 끝 -> %s 시작: 가장 다른 뼈 %s %.0f°, 엉덩이 방향 차 %+.0f°  %s" % [
		first_name, second_name, worst_bone, worst, turn, "튈 수 있음" if worst > GAP_WARN_DEG or absf(turn) > GAP_WARN_DEG else "괜찮음"])


# Where in an attack clip the blade starts its pass, and the clip of its way
# back: the profile's tables, or what the blade timing found.
static func _strike_of(clip: String) -> float:
	var strikes: Dictionary = profile().get("strikes", {})
	return float(strikes.get(clip, _auto_strikes.get(clip, -1.0)))


static func _recovery_of(clip: String) -> String:
	var recoveries: Dictionary = profile().get("recoveries", {})
	return String(recoveries.get(clip, _auto_recoveries.get(clip, "")))


# How fast a clip's root bone goes across the floor, start to end, as m/s at
# the human capsule (the paces' unit): the model's units turned to metres by
# the scale that makes the model the capsule's height.
static func _root_pace(animation: Animation, root_bone: String) -> float:
	for track in animation.get_track_count():
		if animation.track_get_type(track) != Animation.TYPE_POSITION_3D:
			continue
		if String(animation.track_get_path(track).get_subname(0)) != root_bone:
			continue
		var count := animation.track_get_key_count(track)
		if count < 2 or animation.length <= 0.0:
			return 0.0
		var moved: Vector3 = animation.track_get_key_value(track, count - 1) - animation.track_get_key_value(track, 0)
		moved = _skeleton_in_model.basis * moved
		var per_second := Vector2(moved.x, moved.z).length() / animation.length
		return per_second * Player.BODY_HALF_HEIGHT * 2.0 / model_height()
	return 0.0


# ------------------------------------------------------------------ Mixamo clips

# One clip out of the profile's "fbx_clips": read, moved onto this rig's bone
# names, joined with its second file, cut, and kept on the spot.
static func _fbx_clip(clip: String, spec: Dictionary, skeleton_path: String, rig: Skeleton3D = null, built := {}) -> Animation:
	var animation := _fbx_animation(String(spec["file"]), skeleton_path)
	if animation == null:
		return null
	if spec.has("then"):
		var second := _fbx_animation(String(spec["then"]), skeleton_path)
		if second != null:
			_first_part[clip] = animation.length
			animation = _joined(animation, second)
	if bool(spec.get("mirror", false)) and rig != null:
		animation = _mirrored(animation, rig)
	if spec.has("yaw"):
		_turn_clip(animation, float(spec["yaw"]))
	# Before the cut, against where the whole file begins: a part cut out of
	# the middle starts after the file has already walked (the side cut's
	# third step 1.17 m on), and pinned to its own first frame the model
	# stood that far ahead of the body for the length of the step.
	_strip_travel(animation, String(spec.get("travel", "")))
	if spec.has("from") or spec.has("to"):
		animation = _cut(animation, float(spec.get("from", 0.0)), float(spec.get("to", animation.length)))
	if spec.has("upper"):
		var upper_spec: Dictionary = spec["upper"]
		var upper := _fbx_animation(String(upper_spec["file"]), skeleton_path)
		if upper != null:
			upper = _cut(upper, float(upper_spec.get("from", 0.0)), float(upper_spec.get("to", upper.length)))
			animation = _with_upper(animation, upper, bool(upper_spec.get("waist", true)))
	if spec.has("made") and rig != null:
		animation = _made(animation, rig, spec["made"], built)
	return animation


# ------------------------------------------------------------------ a made clip

# Every bone's place and turn against its parent at one moment of a clip: the
# track where the clip has one, the rest pose where it has not.
static func _locals_at(animation: Animation, rig: Skeleton3D, time: float, tracks: Dictionary) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	for bone in rig.get_bone_count():
		var rest := rig.get_bone_rest(bone)
		var local := Transform3D(rest.basis.orthonormalized(), rest.origin)
		var bone_name := rig.get_bone_name(bone)
		if tracks.has(bone_name + "/r"):
			local.basis = Basis(animation.rotation_track_interpolate(int(tracks[bone_name + "/r"]), time))
		if tracks.has(bone_name + "/p"):
			local.origin = animation.position_track_interpolate(int(tracks[bone_name + "/p"]), time)
		out.append(local)
	return out


# The same bones in the skeleton's own space (parents come before children).
static func _globals_of(rig: Skeleton3D, locals: Array[Transform3D]) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	for bone in rig.get_bone_count():
		var parent := rig.get_bone_parent(bone)
		out.append(locals[bone] if parent < 0 else out[parent] * locals[bone])
	return out


# Two bones bent so the end of the second is at `target`, or as near as they
# reach: `top` and `mid` are turned (in `locals`), `tip` is the bone that
# hangs off `mid`. The joint between them (a knee, an elbow) is found from the
# two lengths -- the triangle top-joint-target has all three sides known --
# and leans off the top-to-target line toward `pole`. Each bone is swung by
# the shortest turn from where it points to where it must. `plane_x`: a
# target out of reach is pulled in within its own upright plane (its X kept)
# rather than along the line from the top, so a blade stays in one plane.
static func _reach(rig: Skeleton3D, locals: Array[Transform3D], top: int, mid: int, tip: int,
		target: Vector3, pole: Vector3, plane_x := false) -> void:
	var globals := _globals_of(rig, locals)
	var origin := globals[top].origin
	var first := locals[mid].origin.length()
	var second := locals[tip].origin.length()
	# All but straight: 0.995 of the two lengths is a joint opened to 169
	# degrees (0.985 stopped it at 160, a visibly bent knee on a leg that
	# was meant to be straight).
	var longest := (first + second) * 0.995
	var span := target - origin
	if plane_x and span.length() > longest and absf(span.x) < longest:
		var flat := Vector2(span.y, span.z)
		if flat.length() > 0.0001:
			flat = flat.normalized() * sqrt(longest * longest - span.x * span.x)
			span = Vector3(span.x, flat.x, flat.y)
	var distance := clampf(span.length(), absf(first - second) + 0.001, longest)
	var line := span.normalized()
	var along := (first * first - second * second + distance * distance) / (2.0 * distance)
	var off := sqrt(maxf(first * first - along * along, 0.0))
	var lean := pole - line * pole.dot(line)
	lean = lean.normalized() if lean.length() > 0.001 else Vector3.DOWN
	var joint := origin + line * along + lean * off
	var end := origin + line * distance
	var top_basis := globals[top].basis
	top_basis = Basis(Quaternion((top_basis * locals[mid].origin).normalized(), (joint - origin).normalized())) * top_basis
	var mid_basis := top_basis * locals[mid].basis
	mid_basis = Basis(Quaternion((mid_basis * locals[tip].origin).normalized(), (end - joint).normalized())) * mid_basis
	var parent := rig.get_bone_parent(top)
	var parent_basis := globals[parent].basis if parent >= 0 else Basis.IDENTITY
	locals[top] = Transform3D((parent_basis.inverse() * top_basis).orthonormalized(), locals[top].origin)
	locals[mid] = Transform3D((top_basis.inverse() * mid_basis).orthonormalized(), locals[mid].origin)


# One bone turned to face a way given in the skeleton's own space.
static func _face(rig: Skeleton3D, locals: Array[Transform3D], bone: int, wanted: Basis) -> void:
	var globals := _globals_of(rig, locals)
	var parent := rig.get_bone_parent(bone)
	var parent_basis := globals[parent].basis if parent >= 0 else Basis.IDENTITY
	locals[bone] = Transform3D((parent_basis.inverse() * wanted).orthonormalized(), locals[bone].origin)


# One bone turned about an axis of the skeleton's own space, where it stands.
static func _turn_bone(rig: Skeleton3D, locals: Array[Transform3D], bone: int, axis: Vector3, radians: float) -> void:
	var globals := _globals_of(rig, locals)
	_face(rig, locals, bone, Basis(axis, radians) * globals[bone].basis)


# A value at `part` (0..1) out of keys [[part, value], ...], eased between
# the two either side so the body settles into each. Floats and Vector3s.
static func _key_at(keys: Array, part: float, column := 1) -> Variant:
	var before: Array = keys[0]
	var after: Array = keys[keys.size() - 1]
	if part <= float(before[0]):
		return before[column]
	if part >= float(after[0]):
		return after[column]
	for index in range(keys.size() - 1):
		if part >= float(keys[index][0]) and part <= float(keys[index + 1][0]):
			before = keys[index]
			after = keys[index + 1]
			break
	var along := clampf((part - float(before[0])) / maxf(float(after[0]) - float(before[0]), 0.0001), 0.0, 1.0)
	var eased := along * along * (3.0 - 2.0 * along)
	if before[column] is Vector3:
		return (before[column] as Vector3).lerp(after[column] as Vector3, eased)
	return lerpf(float(before[column]), float(after[column]), eased)


# A clip made on top of another (2026-11-19, the overhead cut: the user's
# picture, in the user's words, of a step and a cut no file has). `source`
# gives the body it starts from -- the armed stance -- and 120 times a second
# the parts the spec names are put where it says:
#   the hips are turned about the upright ("hips_yaw", degrees added);
#   the waist is straightened ("waist", degrees taken out of the forward
#     lean, shared between the "spine" bones);
#   the back foot comes forward and is set down ("step_foot": by how far it
#     ends ahead of where the body's middle is, lifted "foot_lift" on the
#     way, between "step_from" and "step_to"); the other foot stays where it
#     is ON THE GROUND -- the body itself moves forward "advance" metres
#     between "advance_from" and "advance_to" (the skill's own step_distance,
#     step_from and step_to say the same), so in the model's terms it slides
#     back by that much;
#   the sword hand goes where "sword_arm" says with the blade pointing where
#     it says, the flat of the blade square across the body;
#   the other hand goes where "off_arm" says.
# Keys are in metres and the body's own terms: right of its middle, above
# the floor, ahead. The rig is in its own units, faces +Z, right hand at -X.
#   "step_side" is the foot that steps ("Right" unless said). "after" names
# a made clip this one follows: the feet start where that one left them,
# not where the stance has them. "step_to_stance": the stepping foot is set
# down where the stance has it and both feet end turned as the stance has
# them -- the way back into the stance.
static func _made(source: Animation, rig: Skeleton3D, spec: Dictionary, built := {}) -> Animation:
	var per_metre := float(profile()["height"]) / (Player.BODY_HALF_HEIGHT * 2.0)
	var stepping := String(spec.get("step_side", "Right"))
	var standing := "Left" if stepping == "Right" else "Right"
	var names := {
		"hips": "Hips",
		"step": [stepping + "UpLeg", stepping + "Leg", stepping + "Foot"],
		"stay": [standing + "UpLeg", standing + "Leg", standing + "Foot"],
		"sword": ["RightArm", "RightForeArm", "RightHand"],
		"off": ["LeftArm", "LeftForeArm", "LeftHand"],
	}
	var hips := rig.find_bone("Hips")
	var slot := rig.find_bone(HAND_BONE)
	var chains := {}
	for key in ["step", "stay", "sword", "off"]:
		var chain: Array[int] = []
		for bone_name: String in names[key]:
			chain.append(rig.find_bone(bone_name))
		if chain.has(-1):
			return source
		chains[key] = chain
	var spine: Array[int] = []
	for bone_name in spec.get("spine", ["Spine", "Spine1"]):
		spine.append(rig.find_bone(String(bone_name)))
	if hips < 0 or slot < 0 or spine.has(-1):
		return source
	var slot_rest := rig.get_bone_rest(slot).basis.orthonormalized()
	var source_tracks := {}
	var node_path := ""
	for track in source.get_track_count():
		var path := source.track_get_path(track)
		node_path = String(path).get_slice(":", 0)
		var suffix := "/r" if source.track_get_type(track) == Animation.TYPE_ROTATION_3D else "/p"
		source_tracks[String(path.get_subname(0)) + suffix] = track
	# Every bone that is put somewhere gets its track written over.
	var written: Array[int] = [hips]
	written.append_array(spine)
	for key: String in chains:
		written.append_array(chains[key] as Array[int])
	var out := source.duplicate(true) as Animation
	var out_track := {}
	for bone in written:
		var found := out.find_track(NodePath("%s:%s" % [node_path, rig.get_bone_name(bone)]), Animation.TYPE_ROTATION_3D)
		if found < 0:
			found = out.add_track(Animation.TYPE_ROTATION_3D)
			out.track_set_path(found, NodePath("%s:%s" % [node_path, rig.get_bone_name(bone)]))
		while out.track_get_key_count(found) > 0:
			out.track_remove_key(found, 0)
		out_track[bone] = found
	# The hips' own place is written too (they are raised as the hip joints
	# open).
	var hips_path := NodePath("%s:%s" % [node_path, rig.get_bone_name(hips)])
	var hips_place := out.find_track(hips_path, Animation.TYPE_POSITION_3D)
	if hips_place < 0:
		hips_place = out.add_track(Animation.TYPE_POSITION_3D)
		out.track_set_path(hips_place, hips_path)
	while out.track_get_key_count(hips_place) > 0:
		out.track_remove_key(hips_place, 0)
	# Where the feet stand and how they are turned when the clip begins.
	var start := _globals_of(rig, _locals_at(source, rig, 0.0, source_tracks))
	var step_chain: Array[int] = chains["step"]
	var stay_chain: Array[int] = chains["stay"]
	var sword_chain: Array[int] = chains["sword"]
	var off_chain: Array[int] = chains["off"]
	# After another made clip: where that one left the feet.
	var begin := start
	if spec.has("after") and built.has(spec["after"]):
		var prior: Animation = built[spec["after"]]
		var prior_tracks := {}
		for track in prior.get_track_count():
			var prior_path := prior.track_get_path(track)
			var prior_suffix := "/r" if prior.track_get_type(track) == Animation.TYPE_ROTATION_3D else "/p"
			prior_tracks[String(prior_path.get_subname(0)) + prior_suffix] = track
		begin = _globals_of(rig, _locals_at(prior, rig, prior.length, prior_tracks))
	var step_from_place := begin[step_chain[2]].origin
	var stay_place := begin[stay_chain[2]].origin
	var step_foot_basis := begin[step_chain[2]].basis
	var stay_foot_basis := begin[stay_chain[2]].basis
	var to_stance := bool(spec.get("step_to_stance", false))
	var stance_step_basis := start[step_chain[2]].basis
	var stance_stay_basis := start[stay_chain[2]].basis
	var advance := float(spec.get("advance", 0.0)) * per_metre
	var step_to_z := float(spec.get("step_foot", 0.4)) * per_metre
	# "feet_apart": the stepping foot ends this far ahead of where the other
	# one is by then (which has been carried back by the body's advance).
	if spec.has("feet_apart"):
		step_to_z = stay_place.z - advance + float(spec["feet_apart"]) * per_metre
	# "step_in_line": and straight ahead of it, not out to its own side.
	var step_to_x := stay_place.x if bool(spec.get("step_in_line", false)) else step_from_place.x
	if to_stance:
		step_to_z = start[step_chain[2]].origin.z
		step_to_x = start[step_chain[2]].origin.x
	var stay_pivot := float(spec.get("stay_pivot", 0.0))
	var lift := float(spec.get("foot_lift", 0.12)) * per_metre
	var sword_pole_metres: Vector3 = spec.get("sword_pole", Vector3(0.7, -0.6, -0.2))
	var off_pole_metres: Vector3 = spec.get("off_pole", Vector3(-0.6, -0.7, -0.2))
	var sword_pole := Vector3(-sword_pole_metres.x, sword_pole_metres.y, sword_pole_metres.z).normalized()
	var off_pole := Vector3(-off_pole_metres.x, off_pole_metres.y, off_pole_metres.z).normalized()
	var flat_side := Vector3.ZERO
	var steps := int(ceil(source.length * 120.0))
	for step in steps + 1:
		var time := minf(float(step) / 120.0, source.length)
		var part := time / maxf(source.length, 0.001)
		var locals := _locals_at(source, rig, time, source_tracks)
		# The hips: turned about the upright, the right side coming forward.
		var yaw := deg_to_rad(float(_key_at(spec.get("hips_yaw", [[0.0, 0.0]]), part)))
		locals[hips] = Transform3D(Basis(Vector3.UP, yaw) * locals[hips].basis, locals[hips].origin)
		# The feet. How far the body has gone forward (0..1) and how far the
		# stepping foot has come (0..1), each over its own stretch of the clip.
		var gone := smoothstep(float(spec.get("advance_from", 0.0)), float(spec.get("advance_to", 1.0)), part)
		var stepped := smoothstep(float(spec.get("step_from", 0.0)), float(spec.get("step_to", 1.0)), part)
		var stay_target := stay_place + Vector3(0.0, 0.0, -advance * gone)
		var step_target := Vector3(
			lerpf(step_from_place.x, step_to_x, stepped),
			step_from_place.y + lift * sin(PI * stepped),
			lerpf(step_from_place.z, step_to_z, stepped))
		# The hip joints opened ("extend", 0..1; the user: "open the hips all
		# the way as the arm starts down"). The stance sits low with the
		# pelvis tipped forward over bent legs. Opened, the pelvis is stood
		# upright and the hips are raised as far as the legs let them: at 1
		# they are as high as they can be with both feet still where they
		# are, which is the nearer leg straight.
		var extend := clampf(float(_key_at(spec.get("extend", [[0.0, 0.0]]), part)), 0.0, 1.0)
		if extend > 0.0:
			var long_axis := locals[hips].basis.y.normalized()
			var tipped := atan2(long_axis.z, long_axis.y)
			locals[hips] = Transform3D(Basis(Vector3.RIGHT, -tipped * extend) * locals[hips].basis, locals[hips].origin)
			# How high each leg lets the hips go with its foot where it is.
			var allows: Array[float] = []
			for pair: Array in [[stay_chain, stay_target], [step_chain, step_target]]:
				var chain: Array[int] = pair[0]
				var foot_at: Vector3 = pair[1]
				var leg := (locals[chain[1]].origin.length() + locals[chain[2]].origin.length()) * 0.993
				# Where this leg's joint sits against the hips' own place.
				var joint_off := locals[hips].basis * locals[chain[0]].origin
				var joint_flat := Vector2(locals[hips].origin.x + joint_off.x - foot_at.x, locals[hips].origin.z + joint_off.z - foot_at.z)
				var rise := sqrt(maxf(leg * leg - joint_flat.length_squared(), 0.0))
				allows.append(foot_at.y + rise - joint_off.y)
			# While the stepping foot is in the air only the standing leg
			# counts: the body rises onto it, straight. As that foot is set
			# down it counts too, and the body comes down onto it.
			var landed := smoothstep(0.8, 1.0, stepped)
			var highest := lerpf(allows[0], minf(allows[0], allows[1]), landed)
			if highest > locals[hips].origin.y:
				locals[hips].origin.y = lerpf(locals[hips].origin.y, highest, extend)
		# "sink": the hips let down by this many metres, the feet where
		# they are (the legs below bend to it).
		locals[hips].origin.y -= float(_key_at(spec.get("sink", [[0.0, 0.0]]), part)) * per_metre
		# The waist: straightened about the body's own side-to-side axis.
		var straighter := deg_to_rad(float(_key_at(spec.get("waist", [[0.0, 0.0]]), part)))
		for bone in spine:
			_turn_bone(rig, locals, bone, Vector3.RIGHT, -straighter / float(spine.size()))
		_reach(rig, locals, stay_chain[0], stay_chain[1], stay_chain[2], stay_target, Vector3(0.25, 0.0, 1.0).normalized())
		# The standing foot turns where it stands: with the hips as they
		# come round, or back to how the stance has it.
		if to_stance:
			_face(rig, locals, stay_chain[2], Basis(stay_foot_basis.orthonormalized().get_rotation_quaternion().slerp(
				stance_stay_basis.orthonormalized().get_rotation_quaternion(), part * part * (3.0 - 2.0 * part))))
		else:
			_face(rig, locals, stay_chain[2], Basis(Vector3.UP, yaw * stay_pivot) * stay_foot_basis)
		_reach(rig, locals, step_chain[0], step_chain[1], step_chain[2], step_target, Vector3(-0.25, 0.0, 1.0).normalized())
		# The stepping foot turns with the hips, or to how the stance has it.
		if to_stance:
			_face(rig, locals, step_chain[2], Basis(step_foot_basis.orthonormalized().get_rotation_quaternion().slerp(
				stance_step_basis.orthonormalized().get_rotation_quaternion(), stepped)))
		else:
			_face(rig, locals, step_chain[2], Basis(Vector3.UP, yaw * stepped) * step_foot_basis)
		# The sword arm: the hand where the key says, the blade the way it says.
		var hand_metres: Vector3 = _key_at(spec["sword_arm"], part, 1)
		var blade_metres: Vector3 = _key_at(spec["sword_arm"], part, 2)
		var blade := Vector3(-blade_metres.x, blade_metres.y, blade_metres.z).normalized()
		_reach(rig, locals, sword_chain[0], sword_chain[1], sword_chain[2],
			Vector3(-hand_metres.x, hand_metres.y, hand_metres.z) * per_metre, sword_pole, true)
		var after_arm := _globals_of(rig, locals)
		# Which side the blade's flat faces is settled once and kept: asked
		# again at every step it changed sides partway down and the hand
		# turned over about the blade.
		if flat_side == Vector3.ZERO:
			flat_side = Vector3.RIGHT if (after_arm[sword_chain[2]].basis * slot_rest).z.dot(Vector3.RIGHT) >= 0.0 else Vector3.LEFT
		var flat := (flat_side - blade * flat_side.dot(blade)).normalized()
		_face(rig, locals, sword_chain[2], Basis(blade.cross(flat).normalized(), blade, flat) * slot_rest.inverse())
		# The other arm: out for balance.
		if spec.has("off_arm"):
			var off_metres: Vector3 = _key_at(spec["off_arm"], part, 1)
			_reach(rig, locals, off_chain[0], off_chain[1], off_chain[2],
				Vector3(-off_metres.x, off_metres.y, off_metres.z) * per_metre, off_pole)
		for bone in written:
			out.rotation_track_insert_key(int(out_track[bone]), time, locals[bone].basis.orthonormalized().get_rotation_quaternion())
		out.position_track_insert_key(hips_place, time, locals[hips].origin)
	return out

# The FBX's one clip with its tracks renamed for this rig. Read at run time
# (FBXDocument), the way the model's own files are: no import is needed.
static func _fbx_animation(path: String, skeleton_path: String) -> Animation:
	var doc := FBXDocument.new()
	var state := FBXState.new()
	# Some of the files carry a skinned mesh and its texture; only the clip
	# is wanted.
	state.handle_binary_image = GLTFState.HANDLE_BINARY_DISCARD_TEXTURES
	var err := doc.append_from_file(path, state)
	if err != OK:
		push_error("CharacterVisual: %s would not load (%d)" % [path, err])
		return null
	var root := doc.generate_scene(state)
	if root == null:
		push_error("CharacterVisual: %s gave no scene" % path)
		return null
	var source: Animation = null
	for node in root.find_children("*", "AnimationPlayer", true, false):
		var player_node := node as AnimationPlayer
		for clip in player_node.get_animation_list():
			source = player_node.get_animation(clip)
	if source == null:
		push_error("CharacterVisual: %s has no clip" % path)
		root.free()
		return null
	var out := Animation.new()
	out.length = source.length
	for track in source.get_track_count():
		var kind := source.track_get_type(track)
		var from_path := source.track_get_path(track)
		if from_path.get_subname_count() == 0:
			continue
		if kind != Animation.TYPE_POSITION_3D and kind != Animation.TYPE_ROTATION_3D:
			continue
		var bone := String(from_path.get_subname(0)).trim_prefix(MIXAMO_PREFIX)
		var at := out.add_track(kind)
		out.track_set_path(at, NodePath("%s:%s" % [skeleton_path, bone]))
		for key in source.track_get_key_count(track):
			_put_key(out, at, kind, source.track_get_key_time(track, key), source.track_get_key_value(track, key))
	root.free()
	return out


static func _put_key(animation: Animation, track: int, kind: int, time: float, value: Variant) -> void:
	if kind == Animation.TYPE_POSITION_3D:
		animation.position_track_insert_key(track, time, value)
	elif kind == Animation.TYPE_ROTATION_3D:
		animation.rotation_track_insert_key(track, time, value)


static func _sample(animation: Animation, track: int, kind: int, time: float) -> Variant:
	if kind == Animation.TYPE_POSITION_3D:
		return animation.position_track_interpolate(track, time)
	return animation.rotation_track_interpolate(track, time)


# The part of a clip between two times. Only the bone tracks are carried.
static func _cut(source: Animation, from: float, to: float) -> Animation:
	to = minf(to, source.length)
	from = clampf(from, 0.0, to)
	var out := Animation.new()
	out.length = maxf(to - from, 0.01)
	for track in source.get_track_count():
		var kind := source.track_get_type(track)
		if kind != Animation.TYPE_POSITION_3D and kind != Animation.TYPE_ROTATION_3D:
			continue
		if source.track_get_key_count(track) == 0:
			continue
		var at := out.add_track(kind)
		out.track_set_path(at, source.track_get_path(track))
		_put_key(out, at, kind, 0.0, _sample(source, track, kind, from))
		for key in source.track_get_key_count(track):
			var time := source.track_get_key_time(track, key)
			if time > from and time < to:
				_put_key(out, at, kind, time - from, source.track_get_key_value(track, key))
		_put_key(out, at, kind, out.length, _sample(source, track, kind, to))
	return out


# Two clips end to end.
static func _joined(first: Animation, second: Animation) -> Animation:
	var out := first.duplicate(true) as Animation
	out.length = first.length + second.length
	for track in second.get_track_count():
		var kind := second.track_get_type(track)
		var at := out.find_track(second.track_get_path(track), kind)
		if at < 0:
			at = out.add_track(kind)
			out.track_set_path(at, second.track_get_path(track))
		for key in second.track_get_key_count(track):
			_put_key(out, at, kind, first.length + second.track_get_key_time(track, key),
				second.track_get_key_value(track, key))
	return out


# The whole clip turned about the upright, in place: the hips are the root,
# so their turn and their place are what change and everything else follows.
static func _turn_clip(animation: Animation, degrees: float) -> void:
	var turn := Quaternion(Vector3.UP, deg_to_rad(degrees))
	for track in animation.get_track_count():
		if String(animation.track_get_path(track).get_subname(0)) != "Hips":
			continue
		for key in animation.track_get_key_count(track):
			if animation.track_get_type(track) == Animation.TYPE_ROTATION_3D:
				animation.track_set_key_value(track, key, turn * (animation.track_get_key_value(track, key) as Quaternion))
			elif animation.track_get_type(track) == Animation.TYPE_POSITION_3D:
				animation.track_set_key_value(track, key, turn * (animation.track_get_key_value(track, key) as Vector3))


# Takes the walk across the floor out of the hips (or the profile's root
# bone): the body moves itself.
static func _strip_travel(animation: Animation, mode: String, bone := "Hips") -> void:
	if mode == "":
		return
	for track in animation.get_track_count():
		if animation.track_get_type(track) != Animation.TYPE_POSITION_3D:
			continue
		if String(animation.track_get_path(track).get_subname(0)) != bone:
			continue
		var count := animation.track_get_key_count(track)
		if count == 0:
			continue
		var first: Vector3 = animation.track_get_key_value(track, 0)
		var last: Vector3 = animation.track_get_key_value(track, count - 1)
		for key in count:
			var value: Vector3 = animation.track_get_key_value(track, key)
			if mode == "body":
				# 2026-11-21: the body carries all of it, the height too (a
				# skill whose path is baked off this clip, SkillDef "Motion").
				value = first
			elif mode == "pin":
				value.x = first.x
				value.z = first.z
			else:
				var along := animation.track_get_key_time(track, key) / maxf(animation.length, 0.001)
				value.x -= (last.x - first.x) * along
				value.z -= (last.z - first.z) * along
			animation.track_set_key_value(track, key, value)


# The clip as seen in a mirror standing along the body's middle (the plane
# across the skeleton's X): what the left side did the right side does.
#
# Worked in the skeleton's own space, 30 times a second: every bone's pose is
# built up from the tracks (the rest pose where a bone has none), each bone's
# orientation is reflected and handed to the bone on the other side, and the
# result is turned back into poses against the parent. A bone's own axes are
# not laid out the same way on the two sides (this rig's hips sit a quarter
# turn round), so the reflection is carried through each pair's REST poses
# rather than assumed: mirrored(m) = S . global(b) . rest(b)^-1 . S . rest(m)
# for b the other side's bone. Holds for a rig whose rest pose is symmetric.
static func _mirrored(source: Animation, skeleton: Skeleton3D) -> Animation:
	var count := skeleton.get_bone_count()
	var flip := Basis.from_scale(Vector3(-1.0, 1.0, 1.0))
	var partner: Array[int] = []
	var rest_local: Array[Basis] = []
	var rest_global: Array[Basis] = []
	var track_of: Array[int] = []
	var node_path := ""
	var hips_position := -1
	for bone in count:
		var bone_name := skeleton.get_bone_name(bone)
		var other := bone_name
		if bone_name.begins_with("Left"):
			other = "Right" + bone_name.trim_prefix("Left")
		elif bone_name.begins_with("Right"):
			other = "Left" + bone_name.trim_prefix("Right")
		var found := skeleton.find_bone(other)
		partner.append(found if found >= 0 else bone)
		rest_local.append(skeleton.get_bone_rest(bone).basis.orthonormalized())
		track_of.append(-1)
	for bone in count:
		# Parents come before their children in a Skeleton3D.
		var parent := skeleton.get_bone_parent(bone)
		rest_global.append(rest_local[bone] if parent < 0 else rest_global[parent] * rest_local[bone])
	for track in source.get_track_count():
		var path := source.track_get_path(track)
		var bone := skeleton.find_bone(String(path.get_subname(0)))
		if bone < 0:
			continue
		node_path = String(path).get_slice(":", 0)
		if source.track_get_type(track) == Animation.TYPE_ROTATION_3D:
			track_of[bone] = track
		elif source.track_get_type(track) == Animation.TYPE_POSITION_3D:
			hips_position = track
	var out := Animation.new()
	out.length = source.length
	var out_track: Array[int] = []
	for bone in count:
		out_track.append(-1)
		if track_of[partner[bone]] >= 0:
			var at := out.add_track(Animation.TYPE_ROTATION_3D)
			out.track_set_path(at, NodePath("%s:%s" % [node_path, skeleton.get_bone_name(bone)]))
			out_track[bone] = at
	var global: Array[Basis] = []
	var mirrored: Array[Basis] = []
	global.resize(count)
	mirrored.resize(count)
	var steps := int(ceil(source.length * 30.0))
	for step in steps + 1:
		var time := minf(float(step) / 30.0, source.length)
		for bone in count:
			var local := rest_local[bone]
			if track_of[bone] >= 0:
				local = Basis(source.rotation_track_interpolate(track_of[bone], time))
			var parent := skeleton.get_bone_parent(bone)
			global[bone] = local if parent < 0 else global[parent] * local
		for bone in count:
			var from := partner[bone]
			mirrored[bone] = flip * global[from] * rest_global[from].inverse() * flip * rest_global[bone]
		for bone in count:
			if out_track[bone] < 0:
				continue
			var parent := skeleton.get_bone_parent(bone)
			var pose := mirrored[bone] if parent < 0 else mirrored[parent].inverse() * mirrored[bone]
			out.rotation_track_insert_key(out_track[bone], time, pose.orthonormalized().get_rotation_quaternion())
	if hips_position >= 0:
		var at := out.add_track(Animation.TYPE_POSITION_3D)
		out.track_set_path(at, source.track_get_path(hips_position))
		for key in source.track_get_key_count(hips_position):
			var place: Vector3 = source.track_get_key_value(hips_position, key)
			out.position_track_insert_key(at, source.track_get_key_time(hips_position, key), Vector3(-place.x, place.y, place.z))
	return out


static func _is_lower(bone: String) -> bool:
	if profile().has("lower_bones"):
		for head: String in profile()["lower_bones"]:
			if bone.begins_with(head):
				return true
		return false
	for tail in LOWER_BONES:
		if bone.ends_with(tail):
			return true
	return false


# The hips and legs of one clip under everything above them from another,
# the second fitted to the first's length.
static func _with_upper(legs: Animation, upper: Animation, waist := true) -> Animation:
	var out := Animation.new()
	out.length = legs.length
	var fit := legs.length / maxf(upper.length, 0.001)
	# The chest rides on the hips, and the two clips turn their hips
	# differently: left alone, the upper body would be swung round by the
	# other clip's hips. The first bone above the hips ("Spine") is turned
	# by the difference, so everything above it points where it does in its
	# own clip. With `waist` false nothing is turned: the chest rides on the
	# legs' hips as they are -- for an upper half whose own hips do something
	# that is not wanted (the overhead cut's are in a full turn and a leap).
	var hips_legs := _rotation_track(legs, "Hips") if waist else -1
	var hips_upper := _rotation_track(upper, "Hips") if waist else -1
	for pair: Array in [[legs, true, 1.0], [upper, false, fit]]:
		var source: Animation = pair[0]
		for track in source.get_track_count():
			var bone := String(source.track_get_path(track).get_subname(0))
			if _is_lower(bone) != bool(pair[1]):
				continue
			var kind := source.track_get_type(track)
			var at := out.add_track(kind)
			out.track_set_path(at, source.track_get_path(track))
			var at_waist := source == upper and bone == "Spine" and kind == Animation.TYPE_ROTATION_3D \
				and hips_legs >= 0 and hips_upper >= 0
			for key in source.track_get_key_count(track):
				var time := source.track_get_key_time(track, key)
				var value: Variant = source.track_get_key_value(track, key)
				if at_waist:
					var under: Quaternion = legs.rotation_track_interpolate(hips_legs, minf(time * fit, legs.length))
					var own: Quaternion = upper.rotation_track_interpolate(hips_upper, time)
					value = under.inverse() * own * (value as Quaternion)
				_put_key(out, at, kind, time * float(pair[2]), value)
	return out


static func _rotation_track(animation: Animation, bone: String) -> int:
	for track in animation.get_track_count():
		if animation.track_get_type(track) == Animation.TYPE_ROTATION_3D \
				and String(animation.track_get_path(track).get_subname(0)) == bone:
			return track
	return -1


static func _upper_only(source: Animation) -> Animation:
	var out := Animation.new()
	out.length = source.length
	for track in source.get_track_count():
		var bone := String(source.track_get_path(track).get_subname(0))
		if _is_lower(bone):
			continue
		var kind := source.track_get_type(track)
		var at := out.add_track(kind)
		out.track_set_path(at, source.track_get_path(track))
		for key in source.track_get_key_count(track):
			_put_key(out, at, kind, source.track_get_key_time(track, key), source.track_get_key_value(track, key))
	return out


func _load_model() -> void:
	if String(profile()["model"]) == "":
		return
	var path := String(profile()["model"])
	var packed: PackedScene = (load(path) as PackedScene) if bool(profile().get("imported", false)) else _generate(path)
	if packed == null:
		push_error("CharacterVisual: %s would not load" % path)
		return
	var scene := packed.instantiate() as Node3D
	# The clips' tracks are paths from the file's own root. A root that
	# carries a turn or a scale of its own (an FBX's axis or unit fix) keeps
	# it inside a holder, which takes the yaw and the body's scale instead.
	var clip_root := scene
	if scene.transform.is_equal_approx(Transform3D()):
		_model = scene
	else:
		_model = Node3D.new()
		_model.add_child(scene)
	_model.name = "Model"
	var skeletons := _model.find_children("*", "Skeleton3D", true, false)
	if skeletons.is_empty():
		push_error("CharacterVisual: the model has no skeleton")
		add_child(_model)
		return
	_skeleton = skeletons[0] as Skeleton3D
	_measure_model()
	_model.rotation.y = float(profile()["yaw"]) + _measured_yaw
	add_child(_model)
	_anim = AnimationPlayer.new()
	_anim.name = "AnimationPlayer"
	clip_root.add_child(_anim)
	_anim.root_node = NodePath("..")
	_anim.add_animation_library("", _build_library())
	_anim.animation_finished.connect(_on_clip_finished)
	if _upper_library != null and not _upper_library.get_animation_list().is_empty():
		# Added after _anim and processed after it, so on the bones it has
		# tracks for its pose is the one left standing each frame.
		_upper = AnimationPlayer.new()
		_upper.name = "UpperBody"
		clip_root.add_child(_upper)
		_upper.root_node = NodePath("..")
		_upper.process_priority = 1
		_upper.add_animation_library("", _upper_library)
	var lean_bones: Array = profile().get("lean_bones", [])
	if not lean_bones.is_empty():
		_lean = SPINE_LEAN.new()
		_lean.name = "SpineLean"
		var named: Array[String] = []
		for bone in lean_bones:
			named.append(String(bone))
		_lean.set("bones", named)
		_skeleton.add_child(_lean)
	_add_feet()
	_hand = _attachment(hand_bone(), "Hand")
	_offhand = _attachment(offhand_bone(), "OffHandSlot")
	_grip = _grip_under(_hand)
	_offgrip = _grip_under(_offhand)
	if _lean != null:
		# The weapon's turn in the hand is the modifier's too (_aim_grip).
		var forearm: Array = profile().get("forearm_bones", [])
		if forearm.size() == 2:
			_lean.set("grip", _grip)
			_lean.set("slot_bone", hand_bone())
			_lean.set("elbow_bone", String(forearm[0]))
			_lean.set("wrist_bone", String(forearm[1]))
	_loaded = _hand != null
	set_body_scale(1.0)
	_play("idle")


func _attachment(bone: String, label: String) -> BoneAttachment3D:
	var index := _skeleton.find_bone(bone)
	if index < 0:
		push_error("CharacterVisual: no bone %s" % bone)
		return null
	var attachment := BoneAttachment3D.new()
	attachment.name = label
	attachment.bone_name = bone
	_skeleton.add_child(attachment)
	return attachment


# For a profile that leaves them to be measured: the height (floor to the
# top of the meshes, "height" 0), the skeleton's place in the model, and the
# turn that faces the model the body's way ("yaw_from": the heel and the ball
# of a foot, rest pose). Once per process, like the library.
func _measure_model() -> void:
	_skeleton_in_model = _in_model(_skeleton, _model)
	if float(profile()["height"]) <= 0.0 and _measured_height <= 0.0:
		var top := -INF
		for node in _model.find_children("*", "MeshInstance3D", true, false):
			var mesh := node as MeshInstance3D
			var box := _in_model(mesh, _model) * mesh.get_aabb()
			top = maxf(top, box.position.y + box.size.y)
		_measured_height = top if top > 0.0 else 1.0
	var feet: Array = profile().get("yaw_from", [])
	if feet.size() == 2:
		var heel := _skeleton.find_bone(String(feet[0]))
		var ball := _skeleton.find_bone(String(feet[1]))
		if heel >= 0 and ball >= 0:
			var along := _skeleton_in_model.basis * (_skeleton.get_bone_global_rest(ball).origin - _skeleton.get_bone_global_rest(heel).origin)
			# The body faces -Z: turned by this, the foot's line points there.
			_measured_yaw = PI - atan2(along.x, along.z)
			_measured_forward = Vector3(along.x, 0.0, along.z).normalized()


# A node's place against the model's root, built from local transforms (the
# model is not in the tree yet when it is measured).
static func _in_model(node: Node, model_root: Node) -> Transform3D:
	var out := Transform3D()
	while node != null and node != model_root:
		if node is Node3D:
			out = (node as Node3D).transform * out
		node = node.get_parent()
	return out


static func _grip_under(attachment: BoneAttachment3D) -> Node3D:
	if attachment == null:
		return null
	var grip := Node3D.new()
	grip.name = "Grip"
	attachment.add_child(grip)
	return grip


# The model is as tall as the capsule: `scale` is the body's race scale, the
# capsule's half height times it is where the feet go. The grips undo that
# scale so the props keep their own size.
func set_body_scale(scale: float) -> void:
	if _model == null:
		return
	var half := Player.BODY_HALF_HEIGHT * scale
	model_scale = half * 2.0 / model_height()
	_model.scale = Vector3.ONE * model_scale
	_model.position = Vector3(0.0, -half, 0.0)
	# An FBX's unit scale on the skeleton (the mannequin's) is undone too.
	var inner := _skeleton_in_model.basis.get_scale().x
	if inner <= 0.0:
		inner = 1.0
	for grip in [_grip, _offgrip]:
		if grip != null:
			grip.scale = Vector3.ONE / (model_scale * inner)
	if _lean != null:
		_lean.set("grip_scale", 1.0 / (model_scale * inner))


# The model's height on this screen, measured off the skeleton's meshes.
func measured_height() -> float:
	if _skeleton == null:
		return 0.0
	var top := -INF
	var bottom := INF
	for node in _skeleton.get_children():
		var mesh := node as MeshInstance3D
		if mesh == null:
			continue
		var box := mesh.get_aabb()
		top = maxf(top, box.position.y + box.size.y)
		bottom = minf(bottom, box.position.y)
	if top == -INF:
		return 0.0
	# Anything above the profile's height (KayKit's visor spike) is excluded
	# the way the height itself excludes it.
	return minf(top, model_height()) * model_scale - bottom * model_scale


# ------------------------------------------------------------------ props

# The held weapon: the KayKit sword for a sword, the primitive stand-in for
# the rest. Hangs off the right hand bone. The node's -Z is the blade, so
# Player's weapon_length_mult scale on Z still lengthens it.
static func build_weapon_mesh(kind: int) -> Node3D:
	# The model is the family's, at the weapon's own size.
	var family := Weapons.family_kind(kind)
	var ratio := Weapons.size_ratio_of(kind)
	if family == WeaponKinds.Kind.SWORD:
		var packed := _generate(SWORD_PATH)
		if packed != null:
			var root := Node3D.new()
			# The holder: +Y is turned onto the node's -Z (the blade), at
			# the length the order names.
			var holder := Node3D.new()
			holder.name = "SwordMesh"
			holder.rotation_degrees.x = -90.0
			holder.scale = Vector3.ONE * (SWORD_LENGTH / SWORD_MODEL_LENGTH) * ratio
			root.add_child(holder)
			# The model stands on its tip: turned over (half a turn about Z,
			# which keeps the flat of the blade facing the way it did) and
			# lifted so the middle of the grip is where the hand is.
			var mesh := packed.instantiate() as Node3D
			mesh.name = "Model"
			mesh.rotation_degrees.z = 180.0
			mesh.position.y = SWORD_GRIP_AT
			holder.add_child(mesh)
			return root
	if family == WeaponKinds.Kind.SHIELD:
		var packed := _generate(SHIELD_PATH)
		if packed != null:
			var root := Node3D.new()
			var mesh := packed.instantiate() as Node3D
			mesh.name = "ShieldMesh"
			mesh.scale = Vector3.ONE * SHIELD_SCALE * ratio
			root.add_child(mesh)
			return root
	return WeaponKinds.build_mesh(kind)


# Parents the weapon node to the hand. The slot bone's +Y is where a held
# prop points; the node's -Z is turned onto it.
func attach_weapon(node: Node3D) -> bool:
	if _grip == null:
		return false
	_grip.add_child(node)
	node.position = Vector3.ZERO
	if profile().has("grip_basis"):
		# The profile's own hand bone, laid out its own way (the mannequin's
		# Weapon_R: the blade along its +X).
		node.basis = profile()["grip_basis"]
	else:
		node.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	return true


func attach_offhand(node: Node3D) -> bool:
	if _offgrip == null:
		return false
	_offgrip.add_child(node)
	node.position = Vector3.ZERO
	node.rotation_degrees = Vector3.ZERO
	return true


func set_block(raised: bool) -> void:
	_block_raised = raised


# ------------------------------------------------------------------ phases

# The cast's show, from Player.show_skill_phase on every peer: "windup",
# "strike", "recovery", or "" when it ends or is cancelled. The clip is sped
# up to windup + active (the swing's time); the recovery holds the clip's
# last frame; the end blends back to the state's clip at once.
func show_phase(def: SkillDef, phase: String) -> void:
	if _anim == null:
		return
	if def == null or phase == "":
		if _attack_clip != "":
			_blend_once = ATTACK_OUT_BLEND
			# 2026-11-21 (the user: the side cut's second step stepped twice):
			# its clip steps back into a stance of its own; the blend into
			# the idle after it must not move the feet again. They stay
			# planted where the clip left them until the body moves.
			if _attack_baked and _feet != null and player != null:
				_feet.call("plant")
		_attack_clip = ""
		_attack_phase = ""
		_attack_phase_of_return = ""
		_vanish_left = 0.0
		_pick_state_clip(true)
		_blend_once = -1.0
		return
	if def.motion_return_only:
		# 2026-11-23: a step that is only the step back into the stance (the
		# thrust's pull): no clip starts; the pose the step before it left
		# goes into the stance now, as that step's own return would have.
		if _attack_phase_of_return != def.id or phase == "windup" or _attack_phase == "":
			_attack_phase_of_return = def.id
			_attack_baked = true
			_follow_hold = 0.0
			_return_seconds = def.motion_return_seconds()
			_return_foot = def.motion_return_foot
			_returned = false
			_step_back_into_stance()
		_attack_phase = phase
		return
	_attack_phase_of_return = ""
	var clip := _attack_clip_for(def)
	_attack_baked = def.has_motion() and _blade_parts.has(clip)
	# The step back into the stance after the clip (SkillDef motion_return_*),
	# shown once the clip and its own way back are through.
	if phase == "windup" or (phase == "strike" and _attack_clip != clip):
		_returned = false
	_return_seconds = def.motion_return_seconds() if _attack_baked else 0.0
	_return_foot = def.motion_return_foot
	# What is left of the recovery once the swing is through: how long a
	# recovery clip (the profile's "recoveries") has to play in.
	_recovery_seconds = maxf(def.value("recovery") - def.swing_time(), 0.0)
	match phase:
		"windup":
			_start_attack(clip, def.value("windup") + def.swing_time(), def.swing_time())
		"strike":
			if _attack_clip != clip or _attack_phase == "":
				# No windup: the clip starts at the strike, over the active time.
				_start_attack(clip, def.swing_time())
			else:
				_enter_strike(def.swing_time())
			# The dash cut: not drawn while it crosses (Player draws the streak).
			_vanish_left = def.swing_time() if def.vanish_streak else 0.0
		"recovery":
			pass
	_attack_phase = phase


func _attack_clip_for(def: SkillDef) -> String:
	if def.id == "shield_raise":
		var raise := clip_now("block_raise")
		return raise if raise != "" else clip_now("block")
	# A skill with a picture of its own name, where the profile has one (the
	# kick, the punch, the parry, each step of a combo).
	var own := clip_now(def.id)
	if own != "":
		return own
	if def.is_thrust_motion():
		return clip_now("thrust")
	if def.arc_plane == SkillDef.ArcPlane.VERTICAL:
		return clip_now("slash_v")
	return clip_now("slash_h")


# ------------------------------------------------------------------ draw, sheathe

# The weapon has just come into the hand: the draw, over whatever the legs
# are doing. The blade is not shown until the hand has reached the hip.
func play_draw(weapon_node: Node3D) -> void:
	var clip := _play_upper("draw")
	if clip == "" or weapon_node == null:
		return
	weapon_node.visible = false
	var reach := float(_first_part.get(clip, 0.0))
	get_tree().create_timer(reach).timeout.connect(func() -> void:
		if is_instance_valid(weapon_node):
			weapon_node.visible = true)


func play_sheathe() -> void:
	_play_upper("sheathe")


func _play_upper(key: String) -> String:
	if _upper == null or not is_inside_tree():
		return ""
	var armed: Dictionary = profile().get("armed", {})
	var clip := String(armed.get(key, ""))
	if clip == "" or not _upper.has_animation(clip):
		return ""
	_upper.stop()
	_upper.play(clip)
	return clip


# `seconds` is the whole cast (windup + swing). With `swing` given and the
# profile naming where this clip's blade starts its pass ("strikes"), the
# clip is played in two parts: up to that moment over the windup, and from it
# over the swing (_enter_strike, on the strike phase), each at its own speed.
# Without, the whole clip runs evenly over `seconds`, as it always did.
func _start_attack(clip: String, seconds: float, swing := -1.0) -> void:
	var length := clip_length(clip)
	if length <= 0.0:
		return
	var strike := _strike_of(clip)
	_strike_at = -1.0
	var speed := length / maxf(seconds, 0.02)
	if swing > 0.0 and seconds - swing > 0.02 and strike >= 0.0:
		_strike_at = clampf(strike, 0.01, length - 0.01)
		speed = _strike_at / (seconds - swing)
	_follow_hold = 0.0
	_attack_clip = clip
	_attack_done = false
	attack_expected_seconds = seconds
	attack_started_msec = Time.get_ticks_msec()
	attack_finished_msec = 0
	attacks_shown += 1
	picture = "attack"
	# The same clip again starts over from its first frame. A different one
	# is blended into from where the body is (2026-11-18: a stop here threw
	# the pose away, and a combo's next step, or its legs, began with a snap).
	if _anim.assigned_animation == clip:
		_anim.stop(true)
	_play_at(clip, speed)


# The swing has begun (the strike phase): the clip is put at the moment its
# blade starts its pass and the rest of it runs over the swing's time, so the
# blade moves exactly while the server sweeps and the trail is drawn.
func _enter_strike(swing: float) -> void:
	if _strike_at < 0.0 or _attack_clip == "" or _anim.assigned_animation != _attack_clip:
		return
	var length := clip_length(_attack_clip)
	_anim.speed_scale = (length - _strike_at) / maxf(swing, 0.02)
	# Only pulled forward or back if the windup's own pace left it off by
	# more than a frame or two: a seek for nothing is a visible hitch.
	if absf(_anim.current_animation_position - _strike_at) > 0.04:
		_anim.seek(_strike_at, true)
	_strike_at = -1.0


# The pace is the player's speed_scale, so clip_speed() reads what is
# running (play()'s own custom speed is not readable back).
func _play_at(clip: String, speed: float) -> void:
	_anim.speed_scale = speed
	_anim.play(clip, _blend_once if _blend_once >= 0.0 else BLEND)


# 2026-11-22: a guard's own pictures, "perfect", "hit" or "break" (the
# profile's "guard_<kind>" clips; nothing where it has none). They hold over
# the state's clip the way the hit clip does; a blow on the guard does not
# cut a perfect guard or a break short.
var _guard_until_msec := 0
var _guard_kind := ""
# 2026-11-22 (the user): a picture started at the press off this screen's
# foresight (PlayerSkills._guard_foresight), not yet the server's word. A
# blow that then lands on the guard with damage (late: a plain block) cuts it
# for the guard's hit; the server's perfect guard confirms it instead.
var _guard_foreseen := false


func play_guard(kind: String, foreseen := false, damaged := false) -> void:
	if _anim == null or player == null or _attack_clip != "":
		return
	if player.state == Player.State.DEAD or player.state == Player.State.DOWNED:
		return
	if kind == "hit" and Time.get_ticks_msec() < _guard_until_msec and _guard_kind != "hit" \
			and not (_guard_foreseen and damaged):
		return
	var clip := clip_now("guard_" + kind)
	if clip == "" or not _anim.has_animation(clip):
		return
	_guard_foreseen = foreseen
	# A perfect guard (knocked away or deflected) is ruled at the touch: its
	# clip starts a little way in, after a moment held still.
	var perfect := kind == "perfect" or kind == "deflect"
	var lead: float = Tuning.values.guard_anim_lead if perfect else 0.0
	var hold: float = Tuning.values.guard_hitstop if perfect else 0.0
	_guard_until_msec = Time.get_ticks_msec() + int((clip_length(clip) - lead + hold) * 1000.0)
	_guard_kind = kind
	_hit_until_msec = _guard_until_msec
	picture = "guard"
	_anim.stop(true)
	_play_at(clip, 0.0 if hold > 0.0 else 1.0)
	if lead > 0.0:
		_anim.seek(minf(lead, clip_length(clip)), true)
	if hold > 0.0:
		var started := clip
		get_tree().create_timer(hold).timeout.connect(func() -> void:
			if is_instance_valid(_anim) and _anim.assigned_animation == started:
				_anim.speed_scale = 1.0)


# 2026-11-22: the server's word on a perfect guard (or a break) of `kind`:
# true when that picture is already running, started at the press off the
# foresight -- it is kept, not started over, and is the server's now.
func confirm_guard(kind: String) -> bool:
	if _guard_kind == kind and Time.get_ticks_msec() < _guard_until_msec:
		_guard_foreseen = false
		return true
	return false


# A hit lands: the hit clip, unless something that matters more is showing.
# `damaged`: it cost something (a guarded blow that was not perfect).
func play_hit(damaged := true) -> void:
	if _anim == null or player == null:
		return
	if _attack_clip != "" or player.state == Player.State.DEAD or player.state == Player.State.DOWNED:
		return
	# 2026-11-22: on a raised guard, or while a guard's picture runs, the
	# guard's own.
	if _block_raised or Time.get_ticks_msec() < _guard_until_msec:
		play_guard("hit", false, damaged)
		return
	var clip := clip_now("hit")
	if clip == "" or not _anim.has_animation(clip):
		return
	_hit_until_msec = Time.get_ticks_msec() + int(clip_length(clip) / HIT_SPEED * 1000.0)
	picture = "hit"
	_anim.stop(true)
	_play_at(clip, HIT_SPEED)


func _on_clip_finished(clip: StringName) -> void:
	if _attack_clip != "" and String(clip) == _attack_clip and not _attack_done:
		_attack_done = true
		attack_finished_msec = Time.get_ticks_msec()
		# The blow is through: the way back, where the profile has one, over
		# what is left of the recovery. A next step or the end of the cast
		# takes over from wherever this has got to.
		# First the blow is held for a moment (FOLLOW_HOLD): the stop after a
		# fast cut is what gives it weight. _process starts the way back.
		if _recovery_of(_attack_clip) != "":
			_follow_hold = FOLLOW_HOLD if not _attack_baked else 0.0001
		elif _return_seconds > 0.0:
			_step_back_into_stance()
	elif _attack_clip != "" and _attack_done and _return_seconds > 0.0 			and String(clip) == _recovery_of(_attack_clip):
		# The clip's own way back (the thrust's pause) is through: the step.
		_step_back_into_stance()


# 2026-11-21: after a clip that does not end in the stance, the stance is
# blended into over the return (SkillDef motion_return_*) while the body
# (moved by the cast's path) steps into it: the kept foot stays where it is
# and the other one steps through (foot_lock_modifier.gd).
func _step_back_into_stance() -> void:
	if _returned:
		return
	_returned = true
	var stance := clip_now("idle")
	if stance == "" or not _anim.has_animation(stance):
		return
	_blend_once = _return_seconds
	_play_at(stance, 1.0)
	_blend_once = -1.0
	if _feet != null:
		_feet.call("begin_return", _return_seconds, _return_foot)


# The way back after a blow, once its hold is over. It is not squeezed into
# what is left of the recovery (a second-long return in a fifth of a second
# is a snap): it plays at up to RECOVERY_SPEED_MAX and the end of the cast
# blends out of wherever it has got to.
func _play_recovery() -> void:
	var back := _recovery_of(_attack_clip)
	if back == "" or not _anim.has_animation(back):
		return
	var left := maxf(_recovery_seconds - _return_seconds - (0.0 if _attack_baked else FOLLOW_HOLD), 0.05)
	# A baked one runs exactly over its recovery: the body's path does too.
	var speed := clip_length(back) / left
	_play_at(back, speed if _attack_baked else minf(speed, RECOVERY_SPEED_MAX))


# ------------------------------------------------------------------ the loop

func _process(delta: float) -> void:
	if _anim == null:
		return
	_aim_grip(delta)
	_bend(delta)
	_feed_feet()
	if _follow_hold > 0.0:
		_follow_hold -= delta
		if _follow_hold <= 0.0 and _attack_clip != "" and _attack_done:
			_play_recovery()
	if player == null:
		return
	_measure(delta)
	_hide_for_dash(delta)
	if _attack_clip != "":
		return
	# The hit clip runs its course unless the body has gone down, died, been
	# stunned or been picked up meanwhile: those pictures matter more.
	if Time.get_ticks_msec() < _hit_until_msec and not _overrides_hit(player.state):
		return
	# The braking after a dash runs its course only while the body stands.
	if Time.get_ticks_msec() < _stop_until_msec:
		if player.state == Player.State.IDLE:
			return
		_stop_until_msec = 0
	_pick_state_clip(false)


# ------------------------------------------------------------------ the feet

# 2026-11-21: the foot lock and, after it on the skeleton, the engine's
# two-bone IK with a target and a knee pole per leg (top level: placed in the
# world by the lock every frame). Last of the modifiers, so it bends the legs
# of the pose everything else has made.
func _add_feet() -> void:
	var legs: Dictionary = profile().get("leg_bones", {})
	if legs.is_empty() or _skeleton == null:
		return
	_feet = FOOT_LOCK.new()
	_feet.name = "FootLock"
	_skeleton.add_child(_feet)
	var ik := TwoBoneIK3D.new()
	ik.name = "LegIK"
	_skeleton.add_child(ik)
	ik.setting_count = 2
	var targets := {}
	var poles := {}
	var index := 0
	for side: String in ["l", "r"]:
		var names: Array = legs[side]
		var target := Node3D.new()
		target.name = "FootTarget_" + side
		target.top_level = true
		add_child(target)
		var pole := Node3D.new()
		pole.name = "KneePole_" + side
		pole.top_level = true
		add_child(pole)
		ik.set_root_bone_name(index, String(names[0]))
		ik.set_middle_bone_name(index, String(names[1]))
		ik.set_end_bone_name(index, String(names[2]))
		ik.set_target_node(index, ik.get_path_to(target))
		ik.set_pole_node(index, ik.get_path_to(pole))
		targets[side] = target
		poles[side] = pole
		index += 1
	ik.active = false
	_feet.set("ik", ik)
	_feet.set("legs", legs)
	_feet.set("targets", targets)
	_feet.set("poles", poles)


# Every frame: which feet the clip on screen has down, off what was measured
# at load (none for a clip that was not: those feet are let go). A step home
# under way is given up the moment the body starts to walk.
func _feed_feet() -> void:
	if _feet == null:
		return
	var contact := {"l": false, "r": false}
	var clip := String(_anim.assigned_animation)
	if _attack_clip != "" and _foot_contacts.has(clip):
		var marks: Dictionary = _foot_contacts[clip]
		var at := int(round(_anim.current_animation_position / MOTION_SAMPLE)) if _anim.is_playing() \
			else (marks["l"] as PackedByteArray).size() - 1
		for side: String in ["l", "r"]:
			var row := marks[side] as PackedByteArray
			if not row.is_empty():
				contact[side] = row[clampi(at, 0, row.size() - 1)] == 1
	_feet.set("contact", contact)
	if bool(_feet.call("returning")) and player != null and _attack_clip == "" \
			and not (player.state == Player.State.IDLE or player.is_casting()):
		_feet.call("cancel_return")
	# Planted feet are let go the moment anything but standing shows.
	if bool(_feet.call("planted")) and (_attack_clip != "" or picture != "idle"):
		_feet.call("unplant")


# The waist, bent forward while a clip the profile names (the thrust and the
# kick after it) is the attack on screen, and straightened after. The angle is
# this screen's own slider; the modifier lays it over the clip every frame.
func _bend(delta: float) -> void:
	if _lean == null:
		return
	var clips: Array = profile().get("lean_clips", [])
	var want := 1.0 if _attack_clip != "" and clips.has(_attack_clip) else 0.0
	_lean_weight = move_toward(_lean_weight, want, delta * LEAN_RATE)
	var eased := _lean_weight * _lean_weight * (3.0 - 2.0 * _lean_weight)
	_lean.set("degrees", float(Tuning.values.visual_thrust_lean_deg) * eased)
	# The straightening is on from the clip's first frame (its bend is
	# already there) and eases off when the attack ends.
	var straight: Array = profile().get("straighten_clips", [])
	var upright := 1.0 if _attack_clip != "" and straight.has(_attack_clip) else 0.0
	_straight_weight = upright if upright > _straight_weight \
		else move_toward(_straight_weight, upright, delta * LEAN_RATE)
	_lean.set("straighten", float(Tuning.values.visual_chop_straighten) * _straight_weight)
	# The head: on at once (the clip's first frame already has it turned),
	# eased off when the attack ends.
	var ahead: Array = profile().get("look_ahead_clips", [])
	var facing := 1.0 if _attack_clip != "" and ahead.has(_attack_clip) else 0.0
	_look_weight = facing if facing > _look_weight else move_toward(_look_weight, facing, delta * LEAN_RATE)
	_lean.set("look_ahead", _look_weight)


# The weapon in the hand, turned so the blade lies along the forearm while a
# clip the profile names (a thrust) is the attack on screen, and back after.
# The slot's +Y is where the blade points; it is swung onto the forearm's
# direction by the shortest turn, eased in and out.
#
# Only the weight is worked out here. The turn itself is the modifier's
# (spine_lean_modifier.gd), made in the same frame the animation has just
# posed the arm in: worked out here it was a frame behind the wrist, and
# through the last of the thrust, where the wrist turns fast, the blade
# swung back and forth by 10 to 25 degrees a frame (measured at 60 fps).
func _aim_grip(delta: float) -> void:
	if _lean == null:
		return
	var along: Array = profile().get("aim_along_arm", [])
	var want := 1.0 if _attack_clip != "" and along.has(_attack_clip) else 0.0
	_aim_weight = move_toward(_aim_weight, want, delta * AIM_RATE)
	_lean.set("aim", _aim_weight * _aim_weight * (3.0 - 2.0 * _aim_weight))


# The dash is a crouch, nothing, and an arrival: past the profile's
# dash_hide_after the model is not drawn until the body is out of DASH. A
# blow thrown out of the dash is drawn. The body is where it always was.
var _vanish_left := 0.0


func _hide_for_dash(delta: float) -> void:
	var after := float(profile().get("dash_hide_after", -1.0))
	var hidden := false
	if after >= 0.0 and player.state == Player.State.DASH and _attack_clip == "":
		_dash_shown_for += delta
		hidden = _dash_shown_for >= after
	else:
		_dash_shown_for = 0.0
	if _vanish_left > 0.0:
		_vanish_left -= delta
		hidden = true
	if _model.visible == hidden:
		_model.visible = not hidden


static func _overrides_hit(state: int) -> bool:
	return state == Player.State.DOWNED or state == Player.State.DEAD \
		or state == Player.State.STUNNED or state == Player.State.GRABBED


func _measure(delta: float) -> void:
	var at := player.global_position
	if _have_last and delta > 0.0:
		var moved := at - _last_position
		var h := Vector2(moved.x, moved.z).length() / delta
		var v := moved.y / delta
		# Smoothed hard: a replica's eased position arrives in steps.
		_h_speed = lerpf(_h_speed, h, 0.1)
		_v_speed = lerpf(_v_speed, v, 0.3)
	_last_position = at
	_have_last = true


func _pick_state_clip(force: bool) -> void:
	if player == null:
		# Preview (no body): the test drives the clips itself.
		return
	var key := _state_key()
	var armed := is_armed()
	if key != picture or force or armed != _armed_shown:
		var was := picture
		picture = key
		_armed_shown = armed
		if was == "dash" and key == "idle" and _play_stop():
			return
		_play(key)
	# The locomotion clips keep the stride at the body's own pace, up to the
	# local cap (Tuning.values.visual_stride_max).
	var stride_max: float = maxf(float(Tuning.values.visual_stride_max), 1.0)
	match key:
		"walk":
			_anim.speed_scale = clampf(_h_speed / _pace("walk"), 0.6, stride_max)
		"run":
			_anim.speed_scale = clampf(_h_speed / _pace("run"), 0.7, stride_max)
		"dash":
			_anim.speed_scale = float(profile()["dash_speed"])


# The pace the gait clip on screen was made at.
func _pace(key: String) -> float:
	var paces: Dictionary = profile().get("paces", {})
	var clip := clip_now(key)
	if float(_measured_paces.get(clip, 0.0)) > 0.0:
		return float(_measured_paces[clip])
	return maxf(float(paces.get(clip, profile()[key + "_speed"])), 0.01)


# A dash that ends standing: the braking, once, then the idle.
func _play_stop() -> bool:
	var clip := clip_now("dash_stop")
	if clip == "" or not _anim.has_animation(clip):
		return false
	_stop_until_msec = Time.get_ticks_msec() + int(clip_length(clip) / STOP_SPEED * 1000.0)
	picture = "stop"
	_play_at(clip, STOP_SPEED)
	return true


func _state_key() -> String:
	match player.state:
		Player.State.DEAD:
			return "death"
		Player.State.DOWNED:
			return "down"
		Player.State.STUNNED:
			return "stunned"
		Player.State.DASH:
			return "dash"
		Player.State.AIRBORNE:
			return "jump" if _v_speed > 0.5 else "fall"
		Player.State.CLIMB, Player.State.MANTLE:
			return "climb"
		Player.State.GRABBED:
			return "carried"
		Player.State.GRABBING:
			return "carry"
		Player.State.CASTING, Player.State.RECOVERING:
			# A cast with no show of its own (a remote body before the stamp
			# arrives): stand.
			return "idle"
		Player.State.MOVE:
			# The walk is the default gait (2026-11-06); the run shows past
			# the local visual_run_speed and stays until the pace drops under
			# visual_walk_back_speed, a band so a replica's eased position
			# does not flicker across one line. Both are LocalTuning sliders.
			if picture == "run":
				return "run" if _h_speed > float(Tuning.values.visual_walk_back_speed) else "walk"
			return "run" if _h_speed > float(Tuning.values.visual_run_speed) else "walk"
		_:
			return "block" if _block_raised else "idle"


func _play(key: String) -> void:
	var clip := clip_now(key)
	if clip == "" or not _anim.has_animation(clip):
		return
	var speed := 1.0
	match key:
		"jump":
			speed = 1.4
		"stunned":
			speed = 0.8
	var holds: Dictionary = profile().get("holds", {})
	if _anim.current_animation == clip and _anim.is_playing() and key != "death" and key != "jump" \
			and not holds.has(key):
		_anim.speed_scale = speed
		return
	_play_at(clip, speed)
	# Held poses (the profile's "holds"): the clip is put at a frame and
	# paused. The lying itself is Player's (the visual container turns flat);
	# the body just holds still.
	if holds.has(key):
		_anim.seek(clip_length(clip) * float(holds[key]), true)
		_anim.pause()
