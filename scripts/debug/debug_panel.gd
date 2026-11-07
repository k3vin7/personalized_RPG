class_name DebugPanel
extends CanvasLayer

# F1. Stats and every tuning field as live sliders, a readout of what the
# formulas currently produce, and a preview of the arc the next jump would take.
# Folded into sections: what is yours (race, weapon, keys) open at the top,
# the server's tables closed under it, grouped the way PhysicsTuning groups
# them, with a Korean name beside the fields the work order talks about.
#
# Stat changes are replicated, because other peers compute shoves against this
# body's weight. N-1: so are the server's tuning values -- a slider in that
# section is a request, and the value it shows is whatever the server pushed
# back. Only LocalTuning (how a press is read, what is drawn) is edited here
# directly.

# H-1: the 100-point scale. An orc is 100 strength and 140 kg, so the old
# 1-40 / 3-30 sliders could not reach any of the four races. The bounds the
# server enforces are its own (DEBUG_STRENGTH_RANGE / DEBUG_WEIGHT_RANGE);
# these are the panel's, and they sit inside them.
const STAT_RANGES := {
	"strength": Vector2(1.0, 150.0),
	"race_weight": Vector2(20.0, 200.0),
	# Gear is not a system yet, and this is the only way to put weight on a
	# body that is neither its own nor what it is carrying -- which is what
	# comparing bare against equipped needs.
	"gear_weight": Vector2(0.0, 80.0),
}
const ARC_STEPS := 90
const PANEL_WIDTH := 600.0

# The @export_group names of PhysicsTuning, in Korean for the fold titles.
const GROUP_LABELS := {
	"Movement": "이동 · 점프",
	"Strength to weight": "근력 대 무게 배율 (손맛 Q12)",
	"Dash": "돌진",
	"Climb": "등반 · 스태미나",
	"Vitals": "HP · 스태미나 최대",
	"Force": "힘 · 밀치기 · 잡기 · 넉백 (손맛 Q6)",
	"Skills": "기술 · 허수아비 공격",
	"Survival": "낙하 · 낙사 · 리스폰",
	"Combat": "전투 튜닝 (서버 승인) — 무기 공격력 · 방어력 · 치명타",
	"Sword": "검 4기술 (서버 승인) — 찌르기 · 횡베기 · 종베기 · 흘리기",
	"Shield": "방패 4기술 (서버 승인) — 들기 · 밀기 · 던지기 · 찍기",
	"Dash combo": "돌진 조합 (서버 승인) — 창 · 배율 · 치트 허용 오차",
}
# C-1g-e: local fields whose range is not "four times the default".
const LOCAL_LIMITS := {
	"camera_zoom": Vector2(0.0, 1.0),
	"camera_near_mult": Vector2(0.1, 1.0),
	"camera_pitch_deg": Vector2(10.0, 89.0),
	"camera_near_pitch_deg": Vector2(20.0, 89.0),
	"camera_zoom_step": Vector2(0.02, 0.5),
	"visual_run_speed": Vector2(0.0, 20.0),
	"visual_walk_back_speed": Vector2(0.0, 20.0),
	"visual_stride_max": Vector2(1.0, 8.0),
}
# A Korean name beside the field names that come up in the work order and the
# feel questions. The field name stays: it is what the documents call it.
const FIELD_LABELS := {
	"walk_slope_max_deg": "걷기 가능 경사 한계 (넘으면 미끄러짐)",
	"slide_max_deg": "미끄러짐 상한 (넘으면 낙하)",
	"terrain_collision_radius": "클라 지형 충돌 반경 (몸 주변)",
	"terrain_collision_shape_size": "클라 지형 충돌 조각 크기",
	"camera_zoom": "카메라 줌 (1 멀리 · 0 가까이, 휠)",
	"camera_distance": "카메라 거리 (줌 1)",
	"camera_pitch_deg": "카메라 각 (줌 1, 지면 기준)",
	"camera_near_mult": "최대 확대 거리 배수",
	"camera_near_pitch_deg": "각 하한 (줌 0, 지면 기준)",
	"camera_zoom_step": "휠 한 칸 줌 폭",
	"camera_zoom_smoothing": "줌 따라가는 속도",
	"visual_run_speed": "달리기 그림 시작 속도 (m/s, 아래는 걷기)",
	"visual_walk_back_speed": "걷기 그림 복귀 속도 (m/s)",
	"visual_stride_max": "보행 클립 최대 배속",
	"gravity": "중력",
	"base_move_speed": "기본 이속",
	"base_jump_height": "기본 점프 높이",
	"ratio_ref": "근력/무게 기준값",
	"ratio_k_jump": "점프 배율 계수",
	"ratio_k_speed": "이속 배율 계수",
	"ratio_mult_min": "배율 하한",
	"ratio_mult_max": "배율 상한",
	"dash_cooldown": "돌진 쿨다운",
	"stamina_dash_cost": "돌진 스태미나",
	"k_hp": "체력당 HP (k_hp)",
	"stamina_alpha": "스태미나 = 지구력 × (1+α)",
	"stat_point_weight": "배분 포인트 가중치",
	"weapon_attack_sword": "검 공격력",
	"weapon_attack_shield": "방패 공격력",
	"weapon_attack_bare": "맨손 공격력",
	"armor_player": "캐릭터 방어력 (장비 대신)",
	"armor_dummy": "허수아비 방어력",
	"armor_flat_pct": "방어력 고정 감소 비율",
	"crit_base": "치명타 기본 확률",
	"crit_mult": "치명타 배율",
	"crit_per_agility": "민첩 1당 치명타 확률",
	"punch_stamina": "주먹 스태미나",
	"kick_stamina": "발차기 스태미나",
	"shove_stamina": "밀치기 스태미나",
	"grab_stamina": "들기 중 초당 스태미나",
	"dummy_max_hp": "허수아비 HP",
	"thrust_speed_bonus": "찌르기 속도 보정 계수",
	"side_cut_angle": "횡베기 부채꼴 각도 (바닥 표시, C-1g-c까지)",
	"side_cut_arc_deg": "횡베기 호 (판정·연출·궤적, 좌우 합)",
	"overhead_cut_width": "종베기 칼날 폭",
	"overhead_cut_arc_deg": "종베기 수직 호 (머리 위에서 앞으로)",
	"swing_arc_margin_deg": "판정 호 - 애니 호 허용 여유",
	"parry_window": "흘리기 판정 창",
	"parry_recovery": "흘리기 실패 후딜",
	"shield_raise_time": "방패 올림 시간",
	"shield_posture_time": "자세 완성 시간",
	"shield_raise_angle": "막기 각도",
	"block_stamina_mult": "막은 피해당 스태미나",
	"block_tolerance_mult": "자세 100%의 허용치 보정(임시)",
	"block_recover_fraction": "막기 재개 스태미나 비율(임시)",
	"shield_throw_range": "방패 던지기 사거리",
	"shield_weight": "방패 무게(임시)",
	"shield_slam_height_bonus": "찍기 m당 피해 보정",
	"dash_combo_window": "돌진 조합 창",
	"dash_combo_mult_max": "돌진 조합 최대 배율(간격 0)",
	"combo_jitter_allow": "조합 수신 간격 허용 오차(치트 검사)",
	"shove_power": "밀치기 힘",
	"grab_range": "잡기 거리",
	"lift_per_strength": "근력당 들 수 있는 kg",
	"k_push": "밀기 배율 계수",
	"tolerance_per_strength": "근력당 넉백 허용치",
	"launch_min_up_speed": "튕길 때 최소 상승 속도",
	"knock_lift_angle_deg": "이 각도 위는 들어올림",
	"same_party": "같은 파티로 본다",
	"server_speed_tolerance": "이동 검사 여유",
	"down_time": "넘어짐 시간",
	"dummy_attack_enabled": "허수아비 공격 켜기",
	"catch_power_mult": "공격 잡기 힘 배수",
	"fall_damage_enabled": "낙하 피해 켜기",
	"fall_damage_min_height": "낙하 피해 시작 높이",
	"kill_plane_y": "낙사 높이",
	"respawn_delay": "리스폰 대기",
	"smart_key_enabled": "스마트 키 (누르면 바로 시전)",
	"jump_aims_at_cursor": "점프는 커서 쪽으로",
	"jump_aim_deadzone": "제자리 점프 반경",
	"move_intent_timeout": "이동 의도 유지(초)",
	"grab_cursor_radius": "잡기 커서 반경",
	"throw_hold_threshold": "잡기 키 길게 기준(초)",
	"throw_charge_max": "던지기 충전 최대(초)",
	"strength": "근력",
	"race_weight": "몸무게",
	"gear_weight": "장비 무게",
	# C-0: the hit feedback set (this screen only).
	"hit_feedback_enabled": "타격 피드백 켜기",
	"hitstop_frames": "히트스탑 (프레임)",
	"hit_flash_time": "피격 플래시 (초)",
	"hit_particle_count": "타격 파티클 개수",
	"hit_sound_enabled": "사운드 훅 켜기",
	"camera_shake_amp": "카메라 흔들림 세기 (m)",
	"camera_shake_time": "카메라 흔들림 시간 (초)",
	"damage_number_time": "피해 숫자 표시 시간 (초)",
}

var player: Player

var _root: PanelContainer
var _readout: Label
# M-1: which slot is waiting for its next key, and the buttons that show them.
var _rebind_slot := -1
var _slot_buttons: Array[Button] = []
# The dash key, rebound the same way: the button asks, the next key answers.
var _rebind_dash := false
var _dash_button: Button
var _arc: MeshInstance3D
# Off by default (2026-11-03): the line drawn from the feet along the jump
# the cursor would get was always on and read as clutter. The panel's
# "점프 궤적 미리보기" switch turns it on for this screen.
var _arc_enabled := false
# The race and weapon buttons, by kind; the one this body has is lit.
var _race_buttons := {}
var _weapon_buttons := {}
var _race_status: Label
# The ability rows, by field: they follow the server's value (a race change
# rewrites it) whenever the slider is not the thing being dragged.
var _stat_rows := {}


func setup(owner_player: Player) -> void:
	player = owner_player
	layer = 10
	_build_ui()
	_build_arc()
	visible = false
	set_process(true)


func _unhandled_input(event: InputEvent) -> void:
	if _rebind_dash and event is InputEventKey and event.is_pressed() and not event.is_echo():
		if is_instance_valid(player) and player.movement != null:
			player.movement.rebind_dash((event as InputEventKey).physical_keycode)
		_rebind_dash = false
		_refresh_dash_button()
		# The key may have come off a slot.
		_refresh_slot_buttons()
		get_viewport().set_input_as_handled()
		return
	# M-1: the next key pressed goes on the slot that asked for it.
	if _rebind_slot >= 0 and event is InputEventKey and event.is_pressed() and not event.is_echo():
		if is_instance_valid(player) and player.skills != null:
			player.skills.rebind(_rebind_slot, (event as InputEventKey).physical_keycode)
		_rebind_slot = -1
		_refresh_slot_buttons()
		# The key may have come off the dash.
		_refresh_dash_button()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("debug_panel"):
		visible = not visible
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if not is_instance_valid(player) or not player.is_inside_tree():
		return
	if visible:
		_refresh_readout()
		_refresh_choice_buttons()
	_refresh_arc()


func _build_ui() -> void:
	_root = PanelContainer.new()
	_root.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_root.position = Vector2(12.0, 12.0)
	_root.custom_minimum_size = Vector2(PANEL_WIDTH, 620.0)
	# Opaque: the default panel is translucent and the plaza showed through
	# the text, which is most of why it was hard to read.
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.10, 0.12, 0.96)
	style.content_margin_left = 10.0
	style.content_margin_right = 10.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0
	_root.add_theme_stylebox_override("panel", style)
	add_child(_root)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(PANEL_WIDTH - 20.0, 600.0)
	_root.add_child(scroll)
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(column)

	var title := Label.new()
	title.text = "F1 디버그 패널 — ▸ 를 누르면 펼침.  '서버 승인'은 요청이고 서버가 정한 값이 돌아온다."
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(title)

	_readout = Label.new()
	_readout.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_readout)

	# ------------------------------------------------------- 1. my character
	var me := _section(column, "내 캐릭터 — 종족 · 무기 · 능력치 (서버 승인)", true)
	me.add_child(_hint("종족: 빈손으로 서 있을 때만 바뀐다 (선택대와 같은 요청). 바꾸면 능력치 슬라이더는 종족 값으로 돌아간다."))
	var race_row := HBoxContainer.new()
	_race_buttons.clear()
	for kind in Races.all_kinds():
		var data := Races.data_for(kind)
		var button := Button.new()
		button.name = "Race%d" % kind
		button.text = "%s\n근력 %.0f · %.0fkg" % [data.label, data.strength, data.body_weight]
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(func() -> void: _ask_race(kind))
		race_row.add_child(button)
		_race_buttons[kind] = button
	me.add_child(race_row)
	_race_status = _hint("")
	me.add_child(_race_status)

	me.add_child(_hint("무기: 들고 있는 게 없을 때만 바뀐다 (무기 선택대와 같은 요청)."))
	var weapon_row := HBoxContainer.new()
	_weapon_buttons.clear()
	for kind in WeaponKinds.LABELS.keys():
		var button := Button.new()
		button.name = "Weapon%d" % kind
		button.text = WeaponKinds.LABELS[kind]
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(func() -> void: player.set_weapon(kind))
		weapon_row.add_child(button)
		_weapon_buttons[kind] = button
	me.add_child(weapon_row)

	# H-1: the abilities are the server's, so a slider states a number and the
	# server decides. Moving one holds this body off its race at that value;
	# the button puts it back on the race, which is also what choosing a race
	# at a pedestal does.
	me.add_child(_hint("능력치 슬라이더: 종족 값 위에 덮어쓰는 임시값. 되돌리기로 종족 값 복귀."))
	for field in STAT_RANGES.keys():
		var range_values: Vector2 = STAT_RANGES[field]
		var intent_key := "strength"
		if field == "race_weight":
			intent_key = "weight"
		elif field == "gear_weight":
			intent_key = "gear"
		var row := _slider(
			field,
			float(player.stats.get(field)),
			range_values.x,
			range_values.y,
			func(value: float) -> void: _ask_stats({intent_key: value}))
		me.add_child(row)
		_stat_rows[field] = row
	var follow := Button.new()
	follow.text = "종족 값으로 되돌리기"
	follow.pressed.connect(func() -> void: _ask_stats({
		"strength": null, "weight": null, "gear": null}))
	me.add_child(follow)

	# ------------------------------------------------------------ 2. display
	var show := _section(column, "표시 (이 화면만)", true)
	var arc_toggle := CheckButton.new()
	arc_toggle.text = "점프 궤적 미리보기"
	arc_toggle.button_pressed = _arc_enabled
	arc_toggle.toggled.connect(func(on: bool) -> void: _arc_enabled = on)
	show.add_child(arc_toggle)
	if OS.is_debug_build():
		var boundary_toggle := CheckButton.new()
		boundary_toggle.name = "DebugBoundaries"
		boundary_toggle.text = "빨간 경계 표시 (디버그)"
		boundary_toggle.button_pressed = Tuning.debug_boundaries_visible
		boundary_toggle.toggled.connect(func(on: bool) -> void: Tuning.debug_boundaries_visible = on)
		show.add_child(boundary_toggle)

	# --------------------------------------------------------------- 3. keys
	# M-1: the slot keys. A button asks; the next key pressed is the answer.
	var keys := _section(column, "조작 키 (이 컴퓨터만 · 버튼 누른 뒤 아무 키)", true)
	keys.add_child(_hint("한 키는 한 뜻: 이미 쓰는 키를 주면 그쪽 칸이 비워진다."))
	_dash_button = Button.new()
	_dash_button.name = "DashKey"
	_dash_button.pressed.connect(func() -> void:
		_rebind_dash = true
		_refresh_dash_button())
	keys.add_child(_dash_button)
	_refresh_dash_button()
	_slot_buttons.clear()
	for index in PlayerSkills.SLOT_COUNT:
		var button := Button.new()
		button.name = "SlotKey%d" % (index + 1)
		button.pressed.connect(func() -> void:
			_rebind_slot = index
			_refresh_slot_buttons())
		keys.add_child(button)
		_slot_buttons.append(button)
	_refresh_slot_buttons()

	# What stays on this machine: how a press is read, what is drawn.
	var local := _section(column, "조작 설정 (이 컴퓨터만)", false)
	for name_text in Tuning.field_names(Tuning.values):
		# Keycodes are not sliders: the dash key has its button above.
		if name_text == "dash_key":
			continue
		var value: Variant = Tuning.values.get(name_text)
		if typeof(value) == TYPE_BOOL:
			local.add_child(_check(name_text, value, func(on: bool) -> void:
				Tuning.values.set(name_text, on)
				Tuning.notify_changed()))
		elif typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
			var integer := typeof(value) == TYPE_INT
			var limits: Vector2 = LOCAL_LIMITS.get(name_text, numeric_limits(name_text, float(value)))
			local.add_child(_slider(
				name_text,
				float(value),
				limits.x,
				limits.y,
				func(new_value: float) -> void:
					Tuning.values.set(name_text, roundi(new_value) if integer else new_value)
					Tuning.notify_changed(),
				integer))

	# ------------------------------------------------- 4. the race multipliers
	# H-2: the per-race seats. The server's table, not a local tuning value:
	# the move multiplier is in the cap the server checks every body against,
	# so a slider here is a request and the answer comes back replicated.
	var mults := _section(column, "종족 배수 (서버 승인) — 손맛 Q8 드워프 허용치 · Q9 엘프 이속", false)
	var judge := ServerAuthority.instance
	for field in ServerAuthority.RACE_MULT_FIELDS:
		mults.add_child(_hint("넉백 허용치 배수 (1.0 = 종족 근력 그대로)" if field == "tolerance" else "이동 속도 배수 (1.0 = 기본)"))
		for kind in Races.all_kinds():
			var current := 1.0
			if judge != null and field == "tolerance":
				current = judge.race_tolerance_mult(kind)
			elif judge != null:
				current = judge.race_move_mult(kind)
			mults.add_child(_slider(
				"race_%s_mult[%s]" % [field, Races.label_for(kind)],
				current,
				ServerAuthority.DEBUG_RACE_MULT_RANGE.x,
				ServerAuthority.DEBUG_RACE_MULT_RANGE.y,
				func(value: float) -> void: _ask_race_mult(field, kind, value)))

	# ------------------------------------------------------ 5. server tuning
	# N-1: the server's table. Every number a ruling, a trajectory or a cost is
	# built from, so a control here states a value and the server decides --
	# the range it may ask for is the range the server will accept.
	var server := _section(column, "서버 튜닝 (서버 승인) — 묶음별로 펼침", false)
	for group in _grouped_fields(Tuning.server):
		var group_name: String = group["group"]
		var box := _section(server, "%s (%d)" % [GROUP_LABELS.get(group_name, group_name), group["fields"].size()], false)
		for name_text: String in group["fields"]:
			var value: Variant = Tuning.server.get(name_text)
			if typeof(value) == TYPE_BOOL:
				box.add_child(_check(name_text, value,
					func(on: bool) -> void: _ask_server_tuning(name_text, on)))
			else:
				var limits := Tuning.limits_for(name_text)
				box.add_child(_slider(
					name_text,
					float(value),
					limits.x,
					limits.y,
					func(new_value: float) -> void: _ask_server_tuning(name_text, new_value),
					typeof(value) == TYPE_INT))

	# ------------------------------------------------------- 6. skill visuals
	# M-1: the procedural show of each skill, as this machine draws it.
	var visuals := _section(column, "기술 연출 (이 컴퓨터만 · 모양일 뿐 판정 아님)", false)
	for id in Skills.all_ids():
		var def := Skills.get_def(id)
		if def == null:
			continue
		# C-0: the swing's arc joins the lean and the bar. C-1g-a: a sword
		# skill's arc_deg is the server's (Tuning.server.<id>_arc_deg, in the
		# Sword group above), so no local slider for it here.
		for field in ["windup_lean_deg", "recovery_lean_deg", "strike_extent", "strike_height",
				"arc_start_deg", "arc_deg", "arc_duration", "weapon_length_mult", "step_distance"]:
			if field == "arc_deg" and def.tuning_prefix != "" \
					and Tuning.is_server_field("%s_arc_deg" % def.tuning_prefix):
				continue
			if field == "arc_start_deg" and def.arc_centred:
				continue
			var current := float(def.get(field))
			var limits := numeric_limits(field, current)
			if field == "strike_height":
				limits = Vector2(-1.0, 1.5)
			elif field == "arc_deg":
				limits = Vector2(0.0, 360.0)
			elif field == "arc_start_deg":
				limits = Vector2(-180.0, 180.0)
			elif field.ends_with("_deg"):
				limits = Vector2(-45.0, 45.0)
			elif field == "arc_duration":
				limits = Vector2(0.0, 1.0)
			elif field == "weapon_length_mult":
				limits = Vector2(0.5, 2.0)
			elif field == "step_distance":
				limits = Vector2(0.0, 1.5)
			visuals.add_child(_slider(
				"%s.%s" % [id, field],
				current,
				limits.x,
				limits.y,
				func(new_value: float) -> void: def.set(field, new_value)))


# A fold: a button with the title, and a box under it that the button shows
# or hides. Closed sections cost nothing to look past, which is the point.
func _section(parent: Container, title_text: String, open: bool) -> VBoxContainer:
	var button := Button.new()
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.toggle_mode = true
	button.button_pressed = open
	var box := VBoxContainer.new()
	box.visible = open
	var refresh := func() -> void:
		button.text = "%s %s" % ["▾" if button.button_pressed else "▸", title_text]
		box.visible = button.button_pressed
	button.toggled.connect(func(_on: bool) -> void: refresh.call())
	refresh.call()
	var spacer := Label.new()
	spacer.text = ""
	parent.add_child(spacer)
	parent.add_child(button)
	parent.add_child(box)
	return box


func _hint(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.modulate = Color(1.0, 1.0, 1.0, 0.7)
	return label


# The exported fields of a resource, in order, split by their @export_group.
func _grouped_fields(resource: Resource) -> Array:
	var out: Array = []
	var current := {"group": "", "fields": PackedStringArray()}
	for property in resource.get_property_list():
		var usage := int(property["usage"])
		var name_text := String(property["name"])
		if usage & PROPERTY_USAGE_GROUP:
			if current["fields"].size() > 0:
				out.append(current)
			current = {"group": name_text, "fields": PackedStringArray()}
			continue
		if not (usage & PROPERTY_USAGE_EDITOR):
			continue
		if name_text.begins_with("resource_") or name_text == "script":
			continue
		current["fields"].append(name_text)
	if current["fields"].size() > 0:
		out.append(current)
	return out


# The race, asked for the way a pedestal asks. The answer is the server's:
# the buttons below follow player.stats.race, which only the server writes.
func _ask_race(kind: int) -> void:
	if not is_instance_valid(player):
		return
	var ruling: Variant = ServerAuthority.submit_intent(player, ServerAuthority.Intent.RACE, {"race": kind})
	if ruling == null and multiplayer.is_server():
		_race_status.text = "거부: %s" % _refusal_label(ServerAuthority.instance.last_refusal if ServerAuthority.instance != null else "")
	else:
		_race_status.text = "%s 요청 보냄" % Races.label_for(kind)


func _refusal_label(why: String) -> String:
	match why:
		"holding":
			return "손에 든 것을 내려놓아야 한다"
		"held":
			return "잡혀 있는 동안은 안 된다"
		"climbing":
			return "등반 중에는 안 된다"
		"down":
			return "넘어져 있는 동안은 안 된다"
		"not_standing":
			return "땅에 서 있을 때만 된다"
	return why if why != "" else "서버가 거부했다"


func _refresh_choice_buttons() -> void:
	if not is_instance_valid(player) or player.stats == null:
		return
	for field: String in _stat_rows.keys():
		var row: HBoxContainer = _stat_rows[field]
		var slider := row.get_node(field) as HSlider
		if slider == null or slider.has_focus():
			continue
		var current := float(player.stats.get(field))
		if not is_equal_approx(slider.value, current):
			slider.set_value_no_signal(current)
			(row.get_child(2) as Label).text = "%.2f" % current
	for kind: int in _race_buttons.keys():
		var button: Button = _race_buttons[kind]
		var mine := kind == player.stats.race
		button.disabled = mine
		button.modulate = Color(0.7, 1.0, 0.7) if mine else Color.WHITE
	for kind: int in _weapon_buttons.keys():
		var button: Button = _weapon_buttons[kind]
		var mine := kind == player.weapon
		button.disabled = mine
		button.modulate = Color(0.7, 1.0, 0.7) if mine else Color.WHITE


func _refresh_slot_buttons() -> void:
	if not is_instance_valid(player) or player.skills == null:
		return
	for index in _slot_buttons.size():
		var def := player.skills.slot_def(index)
		var what := def.label if def != null else "빈 칸"
		if _rebind_slot == index:
			_slot_buttons[index].text = "슬롯 %d (%s): 키를 누르세요…" % [index + 1, what]
		else:
			_slot_buttons[index].text = "슬롯 %d (%s): %s  — 키 변경" % [
				index + 1, what, player.skills.key_label(index)]


func _refresh_dash_button() -> void:
	if _dash_button == null or not is_instance_valid(player) or player.movement == null:
		return
	if _rebind_dash:
		_dash_button.text = "돌진: 키를 누르세요…"
	else:
		_dash_button.text = "돌진: %s  — 키 변경" % player.movement.dash_key_label()


func numeric_limits(field: String, value: float) -> Vector2:
	if value < 0.0:
		return Vector2(minf(value * 4.0, -1.0), 0.0)
	return Vector2(0.0, maxf(value * 4.0, 1.0))


func _slider(field: String, value: float, minimum: float, maximum: float, on_change: Callable, integer := false) -> HBoxContainer:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = _field_label(field)
	label.custom_minimum_size.x = 300.0
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(label)
	var slider := HSlider.new()
	slider.name = field
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = 1.0 if integer else maxf((maximum - minimum) / 200.0, 0.01)
	slider.set_value_no_signal(value)
	slider.custom_minimum_size.x = 150.0
	row.add_child(slider)
	var readout := Label.new()
	readout.text = "%.2f" % value
	readout.custom_minimum_size.x = 60.0
	row.add_child(readout)
	slider.value_changed.connect(func(new_value: float) -> void:
		readout.text = "%.2f" % new_value
		on_change.call(new_value))
	return row


func _field_label(field: String) -> String:
	return "%s  %s" % [FIELD_LABELS[field], field] if FIELD_LABELS.has(field) else field


func _check(field: String, value: bool, on_change: Callable) -> CheckBox:
	var box := CheckBox.new()
	box.name = field
	box.text = _field_label(field)
	box.button_pressed = value
	box.toggled.connect(func(on: bool) -> void: on_change.call(on))
	return box


# One entry of one table, asked for. The race id is the index, which is what
# keeps the four numbers from drifting apart.
func _ask_race_mult(field: String, kind: int, value: float) -> void:
	if not is_instance_valid(player):
		return
	ServerAuthority.submit_intent(player, ServerAuthority.Intent.RACE_MULT, {
		"field": field, "race": kind, "value": value})


# One door for both sliders and the reset button.
func _ask_stats(payload: Dictionary) -> void:
	if not is_instance_valid(player):
		return
	ServerAuthority.submit_intent(player, ServerAuthority.Intent.STATS, payload)


func _refresh_readout() -> void:
	var movement := player.movement
	_readout.text = "\n".join(PackedStringArray([
		"상태: %s   지상: %s" % [Player.State.keys()[player.state], player.is_on_floor()],
		"속도: (%.2f, %.2f, %.2f)" % [player.velocity.x, player.velocity.y, player.velocity.z],
		"종족: %s%s   근력 %.0f  무게 %.0fkg (장비 %.0f, 든 것 %.0f)  키 %.0fcm" % [
			Races.label_for(player.stats.race),
			" (슬라이더)" if player.stats.is_overridden() else "",
			player.stats.strength, player.stats.total_weight(),
			player.stats.gear_weight, player.stats.held_weight,
			player.stats.height_cm],
		"지구력 %.0f  민첩 %.0f  지능 %.0f  체력 %.0f   배분 %s" % [
			player.stats.endurance, player.stats.agility, player.stats.intellect,
			player.stats.vitality, player.stats.points],
		"ratio: %.3f (기준 %.2f)   점프 높이: %.2f m   초기 속도: %.2f" % [
			player.get_ratio(), Tuning.server.ratio_ref,
			player.get_jump_height(), player.get_jump_velocity()],
		"이동 속도: %.2f m/s" % player.get_move_speed(),
		"이동 의도: %.2f초 남음" % (movement.intent_seconds_left() if movement != null else 0.0),
		"HP: %.0f / %.0f   스태미나: %.0f / %.0f" % [
			player.hp, player.stats.max_hp, player.stamina, player.stats.max_stamina],
		"종족별 HP/스태미나 최대: " + _race_vitals_line(),
	]))


# H-3: the four races' derived maxima, from the server's coefficients -- the
# same numbers the server clamps HP to, so this line is a readout of a ruling.
func _race_vitals_line() -> String:
	var parts := PackedStringArray()
	for kind in Races.all_kinds():
		var data := Races.data_for(kind)
		parts.append("%s %.0f/%.1f" % [
			Races.label_for(kind),
			data.vitality * Tuning.server.k_hp,
			data.endurance * (1.0 + Tuning.server.stamina_alpha)])
	return "  ".join(parts)


# N-1: one field of the server's table, asked for. The server clamps, writes
# its copy and pushes it back; the control shows what it asked until then.
func _ask_server_tuning(field: String, value: Variant) -> void:
	if not is_instance_valid(player):
		return
	ServerAuthority.submit_intent(player, ServerAuthority.Intent.SERVER_TUNING, {
		"field": field, "value": value})


func _build_arc() -> void:
	_arc = MeshInstance3D.new()
	_arc.name = "JumpArc"
	_arc.top_level = true
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("ffd166")
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = false
	_arc.material_override = material
	get_tree().current_scene.add_child.call_deferred(_arc)


func _refresh_arc() -> void:
	if not is_instance_valid(_arc) or not _arc.is_inside_tree():
		return
	if not _arc_enabled or not player.is_grounded_state():
		_arc.visible = false
		return
	# Stepped with the same integration the body uses, at the same tick rate,
	# so the line is where the body will actually go rather than an idealised
	# parabola that quietly disagrees with it.
	var step := 1.0 / float(Engine.physics_ticks_per_second)
	var gravity: float = Tuning.server.gravity
	var position := player.global_position
	var velocity := _preview_launch_velocity()
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	mesh.surface_add_vertex(position)
	for _index in range(ARC_STEPS):
		if _index > 0:
			velocity.y -= gravity * step
		position += velocity * step
		mesh.surface_add_vertex(position)
		if position.y < player.global_position.y - 6.0:
			break
	mesh.surface_end()
	_arc.mesh = mesh
	_arc.visible = true


func _preview_launch_velocity() -> Vector3:
	return player.movement.jump_launch_velocity() if player.movement != null else Vector3.ZERO

