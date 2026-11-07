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
const SWORD_PATH := PACK + "Assets/gltf/sword_1handed.gltf"
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
		# Tripo shipped 12 clips (walk, run, wait, standing_relax, chop, box x3,
		# front_kick x2, dive, swim). Only pictures with a clip of the same
		# meaning are filled: the rest wait for Mixamo clips and stay "".
		# run_looped and chop_single are cut from run and chop by the build script.
		"clips": {
			# standing_relax (17.6 s, seam 0.026), not wait (hands on hips):
			# the user's pick on 2026-11-06.
			"idle": "standing_relax",
			"walk": "walk",
			"run": "run_looped",
			"dash": "run_looped",
			"jump": "",
			"fall": "",
			"slash_h": "",
			"slash_v": "chop_single",
			"thrust": "",
			"block": "",
			"hit": "",
			"death": "",
			"down": "",
			"carry": "",
			"carried": "",
			"climb": "",
			"stunned": "",
		},
		"looping": ["idle", "walk", "run", "dash"],
	},
}
const DEFAULT_PROFILE := "tripo"

# The KayKit sword is 1.78 units hilt to tip; drawn at 1.2 m (a 1.0 m blade
# and a 0.2 m grip, the proportions the order names).
const SWORD_LENGTH := 1.2
const SWORD_MODEL_LENGTH := 1.775
const SHIELD_SCALE := 1.0
const BLEND := 0.12
const HIT_SPEED := 1.6

static var _profile_name := ""
static var _scene_cache := {}
static var _library: AnimationLibrary
static var _clip_lengths := {}

var player: Player
var _model: Node3D
var _skeleton: Skeleton3D
var _anim: AnimationPlayer
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


# ------------------------------------------------------------------ profile

static func profile_name() -> String:
	if _profile_name == "":
		_profile_name = DEFAULT_PROFILE
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
	_clip_lengths.clear()


static func model_height() -> float:
	return float(profile()["height"])


# ------------------------------------------------------------------ loading

static func _generate(path: String) -> PackedScene:
	if _scene_cache.has(path):
		return _scene_cache[path]
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
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
	for key in profile()["looping"]:
		var clip := clip_for(key)
		if library.has_animation(clip):
			library.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
	_library = library
	return library


func _load_model() -> void:
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
	_hand = _attachment(HAND_BONE, "Hand")
	_offhand = _attachment(OFFHAND_BONE, "OffHandSlot")
	_grip = _grip_under(_hand)
	_offgrip = _grip_under(_offhand)
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
	if kind == WeaponKinds.Kind.SWORD:
		var packed := _generate(SWORD_PATH)
		if packed != null:
			var root := Node3D.new()
			var mesh := packed.instantiate() as Node3D
			mesh.name = "SwordMesh"
			# The sword's own length runs along +Y; turned so it runs along
			# the node's -Z, at the length the order names.
			mesh.rotation_degrees.x = -90.0
			mesh.scale = Vector3.ONE * (SWORD_LENGTH / SWORD_MODEL_LENGTH)
			root.add_child(mesh)
			return root
	if kind == WeaponKinds.Kind.SHIELD:
		var packed := _generate(SHIELD_PATH)
		if packed != null:
			var root := Node3D.new()
			var mesh := packed.instantiate() as Node3D
			mesh.name = "ShieldMesh"
			mesh.scale = Vector3.ONE * SHIELD_SCALE
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
		_attack_clip = ""
		_attack_phase = ""
		_pick_state_clip(true)
		return
	var clip := _attack_clip_for(def)
	match phase:
		"windup":
			_start_attack(clip, def.value("windup") + def.swing_time())
		"strike":
			if _attack_clip != clip or _attack_phase == "":
				# No windup: the clip starts at the strike, over the active time.
				_start_attack(clip, def.swing_time())
		"recovery":
			pass
	_attack_phase = phase


func _attack_clip_for(def: SkillDef) -> String:
	if def.id == "shield_raise":
		return clip_for("block")
	if def.is_thrust_motion():
		return clip_for("thrust")
	if def.arc_plane == SkillDef.ArcPlane.VERTICAL:
		return clip_for("slash_v")
	return clip_for("slash_h")


func _start_attack(clip: String, seconds: float) -> void:
	var length := clip_length(clip)
	if length <= 0.0:
		return
	_attack_clip = clip
	_attack_done = false
	attack_expected_seconds = seconds
	attack_started_msec = Time.get_ticks_msec()
	attack_finished_msec = 0
	attacks_shown += 1
	picture = "attack"
	_anim.stop(true)
	_play_at(clip, length / maxf(seconds, 0.02))


# The pace is the player's speed_scale, so clip_speed() reads what is
# running (play()'s own custom speed is not readable back).
func _play_at(clip: String, speed: float) -> void:
	_anim.speed_scale = speed
	_anim.play(clip, BLEND)


# A hit lands: the hit clip, unless something that matters more is showing.
func play_hit() -> void:
	if _anim == null or player == null:
		return
	if _attack_clip != "" or player.state == Player.State.DEAD or player.state == Player.State.DOWNED:
		return
	var clip := clip_for("hit")
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


# ------------------------------------------------------------------ the loop

func _process(delta: float) -> void:
	if _anim == null or player == null:
		return
	_measure(delta)
	if _attack_clip != "":
		return
	# The hit clip runs its course unless the body has gone down, died, been
	# stunned or been picked up meanwhile: those pictures matter more.
	if Time.get_ticks_msec() < _hit_until_msec and not _overrides_hit(player.state):
		return
	_pick_state_clip(false)


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
	if key != picture or force:
		picture = key
		_play(key)
	# The locomotion clips keep the stride at the body's own pace, up to the
	# local cap (Tuning.values.visual_stride_max).
	var stride_max: float = maxf(float(Tuning.values.visual_stride_max), 1.0)
	match key:
		"walk":
			_anim.speed_scale = clampf(_h_speed / float(profile()["walk_speed"]), 0.6, stride_max)
		"run":
			_anim.speed_scale = clampf(_h_speed / float(profile()["run_speed"]), 0.7, stride_max)
		"dash":
			_anim.speed_scale = float(profile()["dash_speed"])


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
	var clip := clip_for(key)
	if clip == "" or not _anim.has_animation(clip):
		return
	var speed := 1.0
	match key:
		"jump":
			speed = 1.4
		"stunned":
			speed = 0.8
	if _anim.current_animation == clip and _anim.is_playing() and key != "death" and key != "jump":
		_anim.speed_scale = speed
		return
	_play_at(clip, speed)
	# Held poses: the clip is put at a frame and paused. The lying itself is
	# Player's (the visual container turns flat); the body just holds still.
	if key == "block":
		_anim.seek(clip_length(clip) * 0.35, true)
		_anim.pause()
	elif key == "down":
		_anim.seek(0.0, true)
		_anim.pause()
