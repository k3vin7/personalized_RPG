class_name HitFeedback
extends Node3D

# C-0: the hit feedback set, on this screen only. Hitstop, a flash on the body
# that was hit, a burst at the point of contact, a sound hook, a camera shake
# for the big ones, and the damage as a number floating off the point. Every
# number is a LocalTuning slider; nothing here is a ruling and nothing here
# travels. Three things call in:
#
#   - the server tells the attacker its blow landed (ServerAuthority.hit_feedback)
#   - the body that was hit applies its force event (Player, Dummy)
#   - a body on another screen is seen losing HP (the replica)
#
# so the same hit can arrive here twice on one screen. C-1a: every report
# carries the hit's id (the force event's, replicated with the HP), and one
# id is one hit -- two monsters landing on the same body in the same frame
# are two. A report with no id (0) is never folded.

static var instance: HitFeedback

# How many hit ids are remembered for the fold.
const REMEMBER_IDS := 64
const NUMBER_RISE := 1.2
const NUMBER_FONT := 30
const PARTICLE_LIFE := 0.35
const PARTICLE_SPEED := 3.5
const SOUND_LAYER := 1 << 18

signal hit_sound(kind: String, point: Vector3)

var player: Player
# Read by the checks.
var hits := 0
var hitstops := 0
var flashes := 0
var particles := 0
var sounds := 0
var shakes := 0
var numbers := 0
var deduped := 0
var last_number_value := 0.0
var last_point := Vector3.ZERO
var last_target := ""
# hit id -> {big}
var _recent := {}
var _recent_order: Array[int] = []
var _sound: AudioStreamPlayer3D


func setup(owner_player: Player) -> void:
	player = owner_player
	instance = self
	# The hook: a player with no stream. A sound is a stream dropped in here.
	_sound = AudioStreamPlayer3D.new()
	_sound.name = "HitSound"
	add_child(_sound)


func _exit_tree() -> void:
	if instance == self:
		instance = null


# One hit, from whichever side reported it.
#   target: the body that was hit. point: where, in the world. damage: what
#   it cost. big: a big swing or a launch (shakes). by_me: this screen's
#   body dealt it. on_me: this screen's body took it. kind: a log label.
func on_hit(target: Node3D, point: Vector3, damage: float, big: bool, by_me: bool, on_me: bool, kind := "", hit_id := 0) -> void:
	if not Tuning.values.hit_feedback_enabled or target == null or not is_instance_valid(target):
		return
	if hit_id > 0 and _recent.has(hit_id):
		deduped += 1
		# The same hit from the other side. Which report comes first is a
		# matter of packet order: on the host its own body's HP is written a
		# step before the force event is applied. The one thing the later
		# report can add is "big" -- the shake -- so that is taken from it.
		var recent: Dictionary = _recent[hit_id]
		if big and not bool(recent.get("big", false)) and (by_me or on_me):
			recent["big"] = true
			_shake()
		return
	if hit_id > 0:
		_recent[hit_id] = {"big": big}
		_recent_order.append(hit_id)
		if _recent_order.size() > REMEMBER_IDS:
			_recent.erase(_recent_order.pop_front())
	hits += 1
	last_point = point
	last_target = target.name
	# Hitstop: the one who swung feels the contact; so does the one hit.
	if by_me or on_me:
		var frames := int(Tuning.values.hitstop_frames)
		if frames > 0 and player != null:
			player.hitstop(frames)
			hitstops += 1
	if target.has_method("flash_hit"):
		target.flash_hit(Tuning.values.hit_flash_time)
		flashes += 1
	_burst(point)
	if Tuning.values.hit_sound_enabled:
		_sound.global_position = point
		hit_sound.emit(kind, point)
		sounds += 1
		print("PLAYGROUND_HIT_SOUND kind=%s target=%s" % [kind, target.name])
	if big and (by_me or on_me):
		_shake()
	# A number only on what has HP to lose: a kicked rock is pushed, not hurt.
	if damage > 0.0 and (target is Player or target is Dummy):
		_number(point, damage, big)
	print("PLAYGROUND_HIT_FEEDBACK target=%s damage=%.1f big=%s by_me=%s on_me=%s kind=%s" % [
		target.name, damage, big, by_me, on_me, kind])


func _shake() -> void:
	if player == null or player.camera == null:
		return
	player.camera.shake(Tuning.values.camera_shake_amp, Tuning.values.camera_shake_time)
	shakes += 1


# A few bright specks out of the contact point.
func _burst(point: Vector3) -> void:
	var count := int(Tuning.values.hit_particle_count)
	if count <= 0:
		return
	var burst := CPUParticles3D.new()
	burst.one_shot = true
	burst.explosiveness = 1.0
	burst.amount = count
	burst.lifetime = PARTICLE_LIFE
	burst.direction = Vector3.UP
	burst.spread = 180.0
	burst.initial_velocity_min = PARTICLE_SPEED * 0.5
	burst.initial_velocity_max = PARTICLE_SPEED
	burst.gravity = Vector3(0.0, -9.8, 0.0)
	burst.scale_amount_min = 0.05
	burst.scale_amount_max = 0.1
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	burst.mesh = quad
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.9, 0.6)
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	quad.material = material
	burst.layers = SOUND_LAYER
	add_child(burst)
	burst.global_position = point
	burst.emitting = true
	particles += 1
	get_tree().create_timer(PARTICLE_LIFE + 0.2).timeout.connect(burst.queue_free)


# The damage, floating up off the point and fading.
func _number(point: Vector3, damage: float, big: bool) -> void:
	var label := Label3D.new()
	label.text = "%d" % roundi(damage) if damage >= 1.0 else "%.1f" % damage
	label.font_size = NUMBER_FONT + (10 if big else 0)
	label.outline_size = 8
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.modulate = Color(1.0, 0.95, 0.7) if not big else Color(1.0, 0.6, 0.4)
	add_child(label)
	label.global_position = point + Vector3.UP * 0.3
	numbers += 1
	last_number_value = damage
	var time := maxf(float(Tuning.values.damage_number_time), 0.05)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "global_position", label.global_position + Vector3.UP * NUMBER_RISE, time)
	tween.tween_property(label, "modulate:a", 0.0, time).set_delay(time * 0.4)
	tween.chain().tween_callback(label.queue_free)
