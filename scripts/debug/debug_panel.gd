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
# The model profiles (CharacterVisual.PROFILES) a button is shown for.
const MODEL_LABELS := {
	"mannequin": "검 팩 마네킹",
	"none": "없음 (떠 있는 손)",
	"tripo": "Tripo 사람",
	"kaykit": "KayKit 기사",
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
	"Mount": "말 타기 (서버 승인) — 소환 · 크기 · 속도",
	"Combat": "전투 튜닝 (서버 승인) — 무기 공격력 · 방어력 · 치명타",
	"Sword": "검 4기술 (서버 승인) — 찌르기 · 횡베기 · 종베기 · 흘리기",
	"Shield": "방패 4기술 (서버 승인) — 들기 · 밀기 · 던지기 · 찍기",
	"Weapon variants": "무기 무게 · 큰 칼 · 큰 방패 (서버 승인, 임시)",
	"Dash combo": "돌진 조합 (서버 승인) — 창 · 배율 · 치트 허용 오차",
	"Wolf": "늑대 (서버 승인) — 인식 · 물기 · 몸 · 시체",
}
# C-1g-e: local fields whose range is not "four times the default".
const LOCAL_LIMITS := {
	"camera_zoom": Vector2(0.0, 1.0),
	"camera_near_mult": Vector2(0.1, 1.0),
	"camera_stop_near_m": Vector2(4.0, 20.0),
	"camera_stop_far_m": Vector2(18.0, 40.0),
	"camera_pitch_deg": Vector2(10.0, 89.0),
	"camera_near_pitch_deg": Vector2(20.0, 89.0),
	"camera_zoom_step": Vector2(0.02, 0.5),
	"camera_turn_step_deg": Vector2(1.0, 90.0),
	"interior_brightness": Vector2(0.0, 1.0),
	"visual_run_speed": Vector2(0.0, 20.0),
	"visual_walk_back_speed": Vector2(0.0, 20.0),
	"visual_stride_max": Vector2(1.0, 8.0),
	"visual_thrust_lean_deg": Vector2(0.0, 60.0),
	"visual_chop_straighten": Vector2(0.0, 1.0),
	"swing_sound_db": Vector2(-60.0, 6.0),
	"swing_kick_m": Vector2(0.0, 0.4),
	"swing_kick_time": Vector2(0.05, 0.5),
	"flinch_squash": Vector2(0.0, 0.5),
	"visual_dodge_speed": Vector2(0.2, 4.0),
	"dash_trail_interval": Vector2(0.01, 0.2),
	"dash_trail_life": Vector2(0.05, 1.0),
	"dash_trail_count": Vector2(1.0, 24.0),
	"flinch_recoil": Vector2(0.0, 0.5),
}
# A Korean name beside the field names that come up in the work order and the
# feel questions. The field name stays: it is what the documents call it.
const FIELD_LABELS := {
	"walk_slope_max_deg": "걷기 가능 경사 한계 (넘으면 미끄러짐)",
	"slide_max_deg": "미끄러짐 상한 (넘으면 낙하)",
	"step_height": "걸어서 넘는 턱 높이 (m, 0 = 끔)",
	"jump_enabled": "점프 허용 (보류 중 · 기본 꺼짐)",
	"climb_enabled": "등반 · 벽잡기 허용 (보류 중 · 기본 꺼짐)",
	"coop_launch_enabled": "협동 발사(아군 발판) 허용 (보류 중 · 기본 꺼짐)",
	"terrain_collision_radius": "클라 지형 충돌 반경 (몸 주변)",
	"terrain_collision_shape_size": "클라 지형 충돌 조각 크기",
	"camera_zoom": "카메라 줌 (1 멀리 · 0 가까이, 휠 클릭으로 3단계)",
	"camera_distance": "카메라 거리 (줌 1)",
	"camera_pitch_deg": "카메라 각 (줌 1, 지면 기준)",
	"camera_near_mult": "최대 확대 거리 배수",
	"camera_stop_near_m": "휠 클릭 확대 단계: 캐릭터까지 거리 (m)",
	"camera_stop_far_m": "휠 클릭 축소 단계: 캐릭터까지 거리 (m)",
	"camera_near_pitch_deg": "각 하한 (줌 0, 지면 기준)",
	"camera_zoom_step": "휠 한 칸 줌 폭 (지금 안 씀)",
	"camera_zoom_smoothing": "줌 따라가는 속도",
	"camera_pan_speed": "둘러보기 속도 (F2 · 방향키, m/s · Shift 3배)",
	"camera_turn_step_deg": "휠 한 칸 카메라 회전 (도)",
	"interior_door_glimpse": "건물 안: 문 밖이 밝게 보이는 길이 (m)",
	"interior_door_light": "건물 안: 문 자리 빛 세기",
	"interior_fade_time": "건물 안: 바뀌는 시간 (초)",
	"interior_brightness": "건물 안: 실내 밝기 (바깥 대비)",
	"interior_torch_energy": "건물 안: 횃불 세기",
	"interior_torch_range": "건물 안: 횃불 닿는 거리 (m)",
	"interior_candle_energy": "건물 안: 촛불 세기",
	"interior_candle_range": "건물 안: 촛불 닿는 거리 (m)",
	"visual_run_speed": "달리기 그림 시작 속도 (m/s, 아래는 걷기)",
	"visual_walk_back_speed": "걷기 그림 복귀 속도 (m/s)",
	"visual_stride_max": "보행 클립 최대 배속",
	"visual_thrust_lean_deg": "찌르기 때 허리 숙이는 각도 (도)",
	"visual_chop_straighten": "종베기 때 허리 세우기 (0 = 동작 그대로, 1 = 꼿꼿이)",
	"mount_summon_time": "말 소환 시간 (초)",
	"mount_linger_time": "내린 뒤 말이 남는 시간 (초)",
	"mount_length": "말 길이 (m)",
	"mount_back_height": "말 등 높이 (m)",
	"mount_width": "말 폭 (m)",
	"mount_large_scale": "큰 말 배율 (오크)",
	"mount_radius": "탄 동안 충돌 캡슐 반지름 (m)",
	"mount_seat_above": "앉은 높이 (등 위, 몸 배율당 m)",
	"mount_speed_mult": "말 속도 배율 (인간 맨몸 이속 대비)",
	"mount_accel_time": "말 가속 시간 (0 → 최고, 초)",
	"mount_decel_time": "말 감속 시간 (최고 → 0, 초)",
	"mount_turn_deg": "말 회전 속도 (도/초)",
	"mount_floor_snap": "말 바닥 붙기 길이 (m)",
	"mount_turn_slow_deg": "방향 어긋남 감속 시작 각도 (도)",
	"mount_turn_min_ratio": "방향 어긋남 최저 속도 비율 (0~1)",
	"gravity": "중력",
	"base_move_speed": "기본 이속",
	"base_jump_height": "기본 점프 높이",
	"ratio_ref": "근력/무게 기준값",
	"ratio_k_jump": "점프 배율 계수",
	"ratio_k_speed": "이속 배율 계수",
	"ratio_mult_min": "배율 하한",
	"ratio_mult_max": "배율 상한",
	"dash_cooldown": "돌진 쿨다운",
	"dash_brake_share": "돌진: 끝에서 감속하는 구간 (거리의 몫)",
	"dash_end_speed": "돌진: 끝 속도 (최고 속도의 몫)",
	"visual_dodge_speed": "돌진 회피 동작 빠르기 (그림만)",
	"dash_trail_enabled": "돌진 잔상 켜기",
	"dash_trail_interval": "돌진 잔상 간격 (초)",
	"dash_trail_life": "돌진 잔상이 사라지는 시간 (초)",
	"dash_trail_count": "돌진 잔상 최대 개수",
	"dash_trail_colour": "돌진 잔상 색",
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
	"wolf_aggro_range": "늑대 인식 거리 (m)",
	"wolf_leash_range": "늑대 포기 거리 (처음 자리에서, m)",
	"wolf_bite_start_range": "물기를 시작하는 거리 (m)",
	"wolf_bite_range": "물기 뛰는 거리 (m)",
	"wolf_bite_width": "물기 길 폭 (m)",
	"wolf_bite_windup": "물기 선딜 (초)",
	"wolf_bite_recovery": "물기 후딜 (초)",
	"wolf_bite_damage": "물기 피해",
	"wolf_lunge_time": "뛰는 데 걸리는 시간 (초)",
	"wolf_interrupt_power": "물기 준비를 끊는 타격 힘 (0 = 아무 공격이나)",
	"wolf_interrupt_pause": "끊긴 뒤 멈춰 있는 시간 (초)",
	"flinch_time": "움찔 시간 (초, 다리가 멈춤, 무게 무관)",
	"flinch_slide": "움찔 때 뒤로 밀리는 거리 (m, 무게 무관)",
	"wolf_run_speed_mult": "늑대 달리기 배율 (인간 맨몸 이속 대비)",
	"wolf_walk_speed_mult": "늑대 서성임 배율 (인간 맨몸 이속 대비)",
	"wolf_wander_radius": "서성이는 반경 (m)",
	"wolf_wander_pause": "서성임 사이 멈춤 (초)",
	"wolf_weight": "늑대 무게 (kg)",
	"wolf_body_radius": "늑대 몸 반지름 (m, 다시 시작해야 적용)",
	"wolf_body_length": "늑대 몸 길이 (m, 다시 시작해야 적용)",
	"wolf_hit_radius": "늑대 맞는 반지름 (m)",
	"wolf_strength": "늑대 근력 (넉백 허용치용)",
	"wolf_max_hp": "늑대 HP",
	"wolf_corpse_time": "시체가 사라지는 시간 (초)",
	"wolf_return_speed_mult": "귀환 속도 배율 (달리기 대비)",
	"wolf_rideable": "늑대 등에 올라탈 수 있음",
	"wolf_shake_after": "늑대: 등에 탄 지 이만큼 지나면 털어냄 (초)",
	"wolf_shake_windup": "늑대 털기 예고 시간 (초)",
	"wolf_shake_power": "늑대 털기 세기",
	"wolf_shake_angle": "늑대 털기 각도 (도, 위로)",
	"back_stab_damage": "내려찍기 피해 (배, 항상 치명타)",
	"wolf_respawn_time": "죽은 뒤 다시 나오는 시간 (초)",
	"thrust_speed_bonus": "찌르기 속도 보정 계수",
	"side_cut_angle": "횡베기 부채꼴 각도 (바닥 표시, C-1g-c까지)",
	"side_cut_arc_deg": "횡베기 호 (판정·연출·궤적, 좌우 합)",
	"dash_cut_windup": "일섬 준비 (숙이는 시간, 초)",
	"dash_cut_recovery": "일섬 회복 (초)",
	"dash_cut_cooldown": "일섬 재사용 대기 (초)",
	"dash_cut_range": "일섬 판정 길이 (돌진 거리 + 칼 길이)",
	"dash_cut_width": "일섬 판정 폭",
	"overhead_cut_width": "종베기 칼날 폭",
	"overhead_cut_arc_deg": "종베기 수직 호 (머리 위에서 앞으로)",
	"swing_arc_margin_deg": "판정 호 - 애니 호 허용 여유",
	"parry_window": "흘리기 판정 창",
	"parry_recovery": "흘리기 실패 후딜",
	"sword_guard_angle": "검 막기 각도 (앞쪽, 도)",
	"sword_guard_move_mult": "검 막기 중 이동 배율 (0 = 제자리)",
	"shield_raise_move_mult": "방패 들고 이동 배율",
	"sword_guard_damage_taken": "검 막기: 막아도 들어오는 피해 비율",
	"sword_guard_perfect_window": "검 막기: 누른 뒤 완벽 막기 창 (초, 숙련 1+)",
	"guard_perfect_stun": "완벽 막기 시 공격자 경직 (초)",
	"guard_perfect_stamina_share": "완벽 막기 기력 소모 (그냥 막기 대비)",
	"guard_deflect_pull": "흘리기: 공격자를 막은 사람 왼쪽 앞으로 끄는 힘",
	"guard_counter_window": "반격베기: 근접 공격을 완벽 막기한 뒤 옆베기 키를 받는 시간 (초, 던진 것은 안 열림)",
	"guard_crit_window": "완벽 막기 뒤 확정 치명타: 다음 공격을 받는 시간 (초)",
	"counter_cut_damage": "반격베기 피해 계수",
	"counter_cut_power": "반격베기 미는 힘",
	"counter_cut_motion_recovery_speed": "반격베기 후딜 동작 속도",
	"guard_anim_lead": "완벽 막기 동작을 이만큼 건너뛰고 시작 (초)",
	"guard_hitstop": "완벽 막기 순간 멈칫 (초)",
	"guard_foresight_slack": "흘리기: 누를 때 미리 보는 여유 (초, 완벽 창에 더함)",
	"dummy_sword_enabled": "검 허수아비 공격",
	"dummy_sword_anchored": "검 허수아비: 맞아도 안 밀림",
	"dummy_sword_approach": "검 허수아비: 이 거리 안에 오면 벰 (m)",
	"dummy_sword_rest": "검 허수아비: 벤 뒤 쉬는 시간 (초)",
	"pitch_enabled": "피칭머신 발사",
	"pitch_period": "피칭머신 발사 간격 (초)",
	"pitch_windup": "피칭머신 예고 시간 (초)",
	"pitch_range": "피칭머신 사거리 (m)",
	"pitch_lane_half_width": "피칭머신 레인 반폭 (m)",
	"pitch_speed": "피칭머신 공 속도 (m/s)",
	"guard_reflect_lift_share": "튕겨낼 수 있는 무게 (들 수 있는 무게의 비율)",
	"sword_guard_min_hold": "검 막기 최소 유지 시간 (초, 완벽 막기면 바로 풀림)",
	"sword_guard_recovery": "검 막기 내린 뒤 다시 들 수 없는 시간 (초)",
	"shield_raise_time": "방패 올림 시간",
	"shield_posture_time": "자세 완성 시간",
	"shield_raise_angle": "막기 각도",
	"block_stamina_mult": "막은 피해당 스태미나",
	"debug_stamina_pin": "지구력 고정 (검사용 · 모든 사람 · 막기 잠김도 바로 풀림)",
	"debug_stamina_pin_value": "고정할 지구력 값",
	"block_tolerance_mult": "자세 100%의 허용치 보정(임시)",
	"block_recover_fraction": "막기 재개 스태미나 비율(임시)",
	"shield_throw_range": "방패 던지기 사거리",
	"shield_weight": "방패 무게 — 손에 든 것·던진 것 (임시)",
	"sword_weight": "검 무게 (kg)",
	"great_sword_reach_mult": "큰 칼 길이·사거리 배율 (검 대비)",
	"great_sword_windup_mult": "큰 칼 선딜 배율 (검 대비)",
	"great_sword_weight": "큰 칼 무게 (kg)",
	"great_shield_block_mult": "큰 방패 막기 각도 배율 (방패 대비)",
	"great_shield_width_mult": "큰 방패 밀치기 폭 배율 (방패 대비)",
	"great_shield_weight": "큰 방패 무게 (kg)",
	"shield_slam_height_bonus": "찍기 m당 피해 보정",
	"dash_combo_window": "돌진 조합 창",
	"start_weapon": "시작할 때 든 무기 (0 없음 · 1 검)",
	"rising_cut_arc_deg": "올려베기 호 (판정·연출·궤적)",
	# 2026-11-21: the baked skills' timing is the clip's (SkillDef "Motion").
	"rising_cut_motion_speed": "올려베기 빠르기 (1 = 동작 그대로, 내려찍기 공통)",
	"rising_cut_motion_reach": "올려베기 이동 거리 배율 (1 = 동작 그대로)",
	"side_cut_motion_speed": "횡베기 빠르기 (1 = 동작 그대로, 2타 공통)",
	"side_cut_motion_reach": "횡베기 이동 거리 배율 (1 = 동작 그대로)",
	"side_cut_2_motion_recovery_speed": "횡베기 2타 후딜 빠르기 (1 = 동작 그대로)",
	"rising_cut_m2_radius": "내려찍기 원 반지름 (m)",
	"rising_cut_m2_range": "내려찍기 원 중심 앞 거리 (m, 0 = 몸 둘레)",
	"side_cut_motion_recovery_speed": "횡베기 1타 후딜 빠르기 (1 = 동작 그대로)",
	"thrust_combo_auto_after": "찌르기: 박힌 채 기다리는 시간 (초, 지나면 자동 뽑기)",
	"thrust_pull_motion_return": "찌르기 뽑기: 자세로 돌아가는 시간 (초)",
	"thrust_pull_damage": "찌르기 뽑기 피해 (배)",
	"thrust_motion_return": "찌르기 뒤 자세로 돌아가는 시간 (초, 앞발 고정)",
	"thrust_motion_speed": "찌르기 빠르기 (1 = 동작 그대로)",
	"thrust_motion_reach": "찌르기 이동 거리 배율 (1 = 동작 그대로)",
	"mastery_debug_level": "숙련 단계 (임시, 모든 기술 공통. 올려베기: 0 = 1타, 1 = 2타, 2 = 3타)",
	"combo_press_after_swing": "연속기: 칼이 지나간 뒤 다음 타 입력을 받는 시간 (초)",
	"combo_window": "연속기: 앞 타가 끝난 뒤에도 이어지는 시간 (초, 0 = 끝나기 전에 눌러야 함)",
	"combo_early_slack": "연속기: 서버가 일찍 온 다음 타를 받아주는 시간 (초)",
	"thrust_2_windup": "찌르기 2타(밀어차기) 준비 (초)",
	"thrust_2_recovery": "찌르기 2타(밀어차기) 회복 (초)",
	"combo_grace": "연속기: 서버가 더 봐주는 시간 (지연 몫, 초)",
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
	"flinch_squash": "움찔: 몸이 눌리는 정도 (키의 몫)",
	"flinch_recoil": "움찔: 늑대 몸이 뒤로 젖혀지는 거리 (m, 그림만)",
	"hit_particle_count": "타격 파티클 개수",
	"swing_feel_enabled": "휘두름 연출 켜기 (소리 · 카메라 밀기)",
	"swing_sound_db": "휘두르는 소리 크기 (dB, -60 이하 = 끔)",
	"swing_kick_m": "휘두를 때 카메라 밀리는 거리 (m)",
	"swing_kick_time": "카메라가 돌아오는 시간 (초)",
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
var _rebind_mount := false
var _mount_button: Button
var _rebind_jump := false
var _jump_button: Button
var _arc: MeshInstance3D
# Off by default (2026-11-03): the line drawn from the feet along the jump
# the cursor would get was always on and read as clutter. The panel's
# "점프 궤적 미리보기" switch turns it on for this screen.
var _arc_enabled := false
# The race and weapon buttons, by kind; the one this body has is lit.
var _race_buttons := {}
var _weapon_buttons := {}
var _model_buttons := {}
# Preloaded, not a class_name: nothing else needs the name, and a new global
# class is not seen by a run until the editor has rescanned.
const CAST_TRACE := preload("res://scripts/debug/cast_trace.gd")
var _cast_trace: Node
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
	if _rebind_jump and event is InputEventKey and event.is_pressed() and not event.is_echo():
		if is_instance_valid(player) and player.movement != null:
			player.movement.rebind_jump((event as InputEventKey).physical_keycode)
		_rebind_jump = false
		_refresh_dash_button()
		_refresh_slot_buttons()
		get_viewport().set_input_as_handled()
		return
	if _rebind_mount and event is InputEventKey and event.is_pressed() and not event.is_echo():
		if is_instance_valid(player) and player.movement != null:
			player.movement.rebind_mount((event as InputEventKey).physical_keycode)
		_rebind_mount = false
		_refresh_dash_button()
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
	# The model every body is drawn with on this screen. Drawn only: the
	# body, its size and every ruling are the same under any of them.
	show.add_child(_hint("캐릭터 모델: 이 화면에 보이는 모든 캐릭터의 그림만 바뀐다 (판정·크기는 그대로)."))
	var model_row := HBoxContainer.new()
	_model_buttons.clear()
	for profile_name in MODEL_LABELS.keys():
		var button := Button.new()
		button.name = "Model_%s" % profile_name
		button.text = MODEL_LABELS[profile_name]
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(func() -> void: _use_model(profile_name))
		model_row.add_child(button)
		_model_buttons[profile_name] = button
	show.add_child(model_row)
	_refresh_model_buttons()
	# The recorder: what this screen drew of this body for the next 8 s, frame
	# by frame, saved to a file. For a complaint the eye has and a check
	# cannot reproduce.
	var trace_button := Button.new()
	trace_button.name = "CastTrace"
	trace_button.text = "동작 기록 시작 (누른 뒤 8초 동안 내 캐릭터를 프레임마다 기록)"
	var trace_status := _hint("기록을 누르고 F1을 닫은 뒤, 이상해 보이는 동작을 하면 된다.")
	trace_button.pressed.connect(func() -> void:
		if _cast_trace == null:
			_cast_trace = CAST_TRACE.new()
			_cast_trace.name = "CastTrace"
			add_child(_cast_trace)
			_cast_trace.connect("finished", func(path: String) -> void:
				trace_status.text = "기록 끝. 저장: %s" % path)
		_cast_trace.call("start", player)
		trace_status.text = "기록 중 (8초)...")
	show.add_child(trace_button)
	show.add_child(trace_status)
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
	_mount_button = Button.new()
	_mount_button.name = "MountKey"
	_mount_button.pressed.connect(func() -> void:
		_rebind_mount = true
		_refresh_dash_button())
	keys.add_child(_mount_button)
	_jump_button = Button.new()
	_jump_button.name = "JumpKey"
	_jump_button.pressed.connect(func() -> void:
		_rebind_jump = true
		_refresh_dash_button())
	keys.add_child(_jump_button)
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
		if name_text == "dash_key" or name_text == "mount_key" or name_text == "jump_key":
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
				func(new_value: float) -> void:
					for copy in Skills.every_copy(id):
						copy.set(field, new_value)))


# Swaps the model profile and rebuilds the picture of every body in the
# scene. The first use of a profile reads its files, which takes a moment.
func _use_model(profile_name: String) -> void:
	if profile_name == CharacterVisual.profile_name():
		return
	CharacterVisual.use_profile(profile_name)
	for node in get_tree().root.find_children("*", "Player", true, false):
		(node as Player).rebuild_visual()
	_refresh_model_buttons()


func _refresh_model_buttons() -> void:
	for profile_name in _model_buttons:
		(_model_buttons[profile_name] as Button).disabled = profile_name == CharacterVisual.profile_name()


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
		var mine := kind != WeaponKinds.Kind.NONE and (kind == player.weapon or kind == player.offhand)
		# Greyed when this body's race may not hold it (the server would
		# refuse the request; this only saves the click).
		button.disabled = mine or not Weapons.usable_by(player.stats.race, kind)
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
	if _mount_button == null:
		return
	if _rebind_mount:
		_mount_button.text = "말 소환/내리기: 키를 누르세요…"
	else:
		_mount_button.text = "말 소환/내리기: %s  — 키 변경" % player.movement.mount_key_label()
	if _jump_button == null:
		return
	if _rebind_jump:
		_jump_button.text = "점프: 키를 누르세요…"
	else:
		_jump_button.text = "점프 (보류 중): %s  — 키 변경" % player.movement.jump_key_label()


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

