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
const DEFAULT_PROFILE := "tripo"
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

static var _profile_name := ""
static var _scene_cache := {}
static var _library: AnimationLibrary
# Draw and sheathe with the leg tracks left out, for the second player.
static var _upper_library: AnimationLibrary
static var _clip_lengths := {}
# For a clip made of two files: how long the first one is.
static var _first_part := {}

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
var _lean: SkeletonModifier3D
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


# The clip for a picture on this body now.
func clip_now(key: String) -> String:
	if is_armed():
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


static func model_height() -> float:
	return float(profile()["height"])


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
	for path in profile()["clip_files"]:
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


# Takes the walk across the floor out of the hips: the body moves itself.
static func _strip_travel(animation: Animation, mode: String) -> void:
	if mode == "":
		return
	for track in animation.get_track_count():
		if animation.track_get_type(track) != Animation.TYPE_POSITION_3D:
			continue
		if String(animation.track_get_path(track).get_subname(0)) != "Hips":
			continue
		var count := animation.track_get_key_count(track)
		if count == 0:
			continue
		var first: Vector3 = animation.track_get_key_value(track, 0)
		var last: Vector3 = animation.track_get_key_value(track, count - 1)
		for key in count:
			var value: Vector3 = animation.track_get_key_value(track, key)
			if mode == "pin":
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
	var packed := _generate(String(profile()["model"]))
	if packed == null:
		return
	_model = packed.instantiate() as Node3D
	_model.name = "Model"
	_model.rotation.y = float(profile()["yaw"])
	add_child(_model)
	var skeletons := _model.find_children("*", "Skeleton3D", true, false)
	if skeletons.is_empty():
		push_error("CharacterVisual: the model has no skeleton")
		return
	_skeleton = skeletons[0] as Skeleton3D
	_anim = AnimationPlayer.new()
	_anim.name = "AnimationPlayer"
	_model.add_child(_anim)
	_anim.root_node = NodePath("..")
	_anim.add_animation_library("", _build_library())
	_anim.animation_finished.connect(_on_clip_finished)
	if _upper_library != null and not _upper_library.get_animation_list().is_empty():
		# Added after _anim and processed after it, so on the bones it has
		# tracks for its pose is the one left standing each frame.
		_upper = AnimationPlayer.new()
		_upper.name = "UpperBody"
		_model.add_child(_upper)
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
	_hand = _attachment(HAND_BONE, "Hand")
	_offhand = _attachment(OFFHAND_BONE, "OffHandSlot")
	_grip = _grip_under(_hand)
	_offgrip = _grip_under(_offhand)
	if _lean != null:
		# The weapon's turn in the hand is the modifier's too (_aim_grip).
		var forearm: Array = profile().get("forearm_bones", [])
		if forearm.size() == 2:
			_lean.set("grip", _grip)
			_lean.set("slot_bone", HAND_BONE)
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
	for grip in [_grip, _offgrip]:
		if grip != null:
			grip.scale = Vector3.ONE / model_scale
	if _lean != null:
		_lean.set("grip_scale", 1.0 / model_scale)


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
		_attack_clip = ""
		_attack_phase = ""
		_vanish_left = 0.0
		_pick_state_clip(true)
		_blend_once = -1.0
		return
	var clip := _attack_clip_for(def)
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
	var strikes: Dictionary = profile().get("strikes", {})
	_strike_at = -1.0
	var speed := length / maxf(seconds, 0.02)
	if swing > 0.0 and seconds - swing > 0.02 and strikes.has(clip):
		_strike_at = clampf(float(strikes[clip]), 0.01, length - 0.01)
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


# A hit lands: the hit clip, unless something that matters more is showing.
func play_hit() -> void:
	if _anim == null or player == null:
		return
	if _attack_clip != "" or player.state == Player.State.DEAD or player.state == Player.State.DOWNED:
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
		var recoveries: Dictionary = profile().get("recoveries", {})
		if String(recoveries.get(_attack_clip, "")) != "":
			_follow_hold = FOLLOW_HOLD


# The way back after a blow, once its hold is over. It is not squeezed into
# what is left of the recovery (a second-long return in a fifth of a second
# is a snap): it plays at up to RECOVERY_SPEED_MAX and the end of the cast
# blends out of wherever it has got to.
func _play_recovery() -> void:
	var recoveries: Dictionary = profile().get("recoveries", {})
	var back := String(recoveries.get(_attack_clip, ""))
	if back == "" or not _anim.has_animation(back):
		return
	var left := maxf(_recovery_seconds - FOLLOW_HOLD, 0.05)
	_play_at(back, minf(clip_length(back) / left, RECOVERY_SPEED_MAX))


# ------------------------------------------------------------------ the loop

func _process(delta: float) -> void:
	if _anim == null:
		return
	_aim_grip(delta)
	_bend(delta)
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
	return maxf(float(paces.get(clip_now(key), profile()[key + "_speed"])), 0.01)


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
