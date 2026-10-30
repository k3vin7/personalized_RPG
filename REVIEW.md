# physics_playground 코드 리뷰 — 2인 네트워크 검증 전 현황

기준 커밋: `4748639` (H-2 후속까지). 코드는 고치지 않았고, 아래는 전부 파일을 읽고 grep한 결과다. 읽지 않고 미룬 판단은 **(추측)** 으로 표시했다.

적용하려는 규칙: **외부 힘(밀림·넉백·던지기)을 받거나 잡힌 순간부터 착지(또는 놓임)까지 그 캐릭터의 위치는 서버가 정하고, 그 외엔 자기 클라이언트가 정하며 서버는 속도·거리만 검사한다.**

---

## 0. 한눈에

| 항목 | 지금 |
| --- | --- |
| 위치 권한 | **항상 그 몸의 소유 클라.** `scenes/player.tscn`의 `Synchronizer`(권한 = 피어 id)가 `sync_position/sync_yaw/sync_state/sync_jumped/sync_weapon/sync_knock`를 복제. 서버가 플레이어 위치를 쓰는 경로는 없다. |
| 힘을 받은 뒤 | 서버가 **판정**(명중·피해·경직·허용치)만 하고, **속도 적용과 비행·착지 시뮬레이션은 전부 맞은 쪽 클라**(`player.gd:apply_force_event`). 서버는 그 뒤 1.5초 동안 이동 검사 허용치를 넓힐 뿐(`_remember_force`). |
| 잡힌 몸 | 보유 관계(`_holds`)는 서버 표지만, **잡힌 몸의 위치는 잡힌 클라가 자기 화면의 보유자 손 위치로 직접 쓴다**(`player_grab.gd:283-289`, 주석 "Our own position is still ours to write"). |
| 서버 이동 검사 | `_check_move`: 0.1초 표본, 속도 상한 초과 시 **경고 로그만**(`PLAYGROUND_MOVE_WARN`). 되돌리기·거부 없음. |
| 서버가 위치를 정하는 패턴이 이미 있는 곳 | 돌(`rock.gd:184-199`)과 허수아비(`dummy.gd:191-199`): 호스트가 시뮬레이션하고 0.05초마다 `push_state` RPC, 클라는 "보여주기만". |

---

## 1. 동작 목록

완성도: 완료 / 부분 / 뼈대만 / 없음. 판정 주체: 입력한 클라 / 맞은 쪽 클라 / 서버 / 공용 코드 / 없음. 공식: 데이터(`PhysicsTuning` 슬라이더) / 코드(상수·리터럴) / 혼합.

| 동작 | 구현 파일·함수 | 완성도 | 지금 누가 판정 | 공식 위치 |
| --- | --- | --- | --- | --- |
| 이동 (우클릭, 내비 경로) | `player_movement.gd` `_click_to_target`(1009) → `set_target`(229) → `_query_path`(1101) → `_ground_step`(384) → `_desired_velocity`(1055). 속도식 `player.gd:get_move_speed`(371) | 완료 | **입력한 클라**. 서버는 `server_authority.gd:_check_move`(1345)로 속도만 검사(경고) | 혼합: `base_move_speed`, `ratio_k_speed`, `ratio_ref`, `ratio_mult_*`는 데이터; `race_move_mult`는 서버 표; 경로 상수(`ARRIVE_TOLERANCE 0.3`, `PATH_LOOKAHEAD 0.75`, `DRAG_RETARGET_INTERVAL 0.1`)는 코드 |
| 점프 (커서 지점 / 제자리) | `press_jump`(118) → `_launch_jump`(642) → `jump_launch_velocity`(665) → `jump_plan`(546) / `_launch_for`(538). 상한 `player.gd:leap_speed_cap`(351) | 완료 | **입력한 클라**. 의도 RPC 없음. 서버 검사는 `move_allowance`(1303)의 수직 상한 | 혼합: `base_jump_height`, `jump_inplace_radius`, `jump_min_hop_height`, `jump_ledge_margin`, `jump_aims_at_cursor`, `jump_aim_deadzone`, `ratio_k_jump`는 데이터; `JUMP_BUFFER 0.1`, `COYOTE_TIME 0.1`, 정점 비율 `reach*0.25`(605), 최적각 `PI/4 + atan2/2`(623)는 코드 |
| 돌진 | `request_dash`(875) → `_dash_step`(901) → `_end_dash`(925). 거리 `dash_plan`(860) = `leap_max_range()` | 완료 | **입력한 클라** | 혼합: `dash_min_distance`, `dash_speed_mult`, `dash_cooldown`, `stamina_dash_cost` 데이터; 돌진 중 점프 분배 `cap/√2`(671) 코드 |
| 밀치기 | 입력 `movement.shove`(694) → `Intent.SHOVE` → `server_authority.gd:_rule_shove`(534: 쿨다운·직사각형 명중·아군·발사) → `send_force`(984) → 대상 `apply_force_event` | 완료 | **서버**가 명중·아군·피해·경직·허용치 판정. **속도 대입은 맞은 쪽 클라**(`player.gd:620`) | 혼합: `shove_power/up_bias/range/width/recoil/damage/stun_time/cooldown/ally_launch_angle_deg`, `k_push`, `tolerance_per_strength`, `launch_min_up_speed`, `knock_lift_angle_deg`, `force_slide_time/friction` 데이터; `intersect_shape(params, 8)`(566), `BODY_RADIUS` 보정 코드 |
| 아군 발사 (공중 아군 밀치기 = 발판) | `_rule_shove` 내 `recently_airborne`(273) → `event["spring"]=true`; 적용은 `player.gd:654-663` (`velocity.y = get_jump_velocity()`) | 완료 | 서버 판정, 적용은 맞은 쪽 클라 | 데이터(`shove_ally_launch_angle_deg`) + 코드(`AIRBORNE_MEMORY 0.3`) |
| 잡기 | 입력 `player_grab.gd:grab`(57: 커서 아래 대상 선택은 **클라**) → `Intent.GRAB` → `_rule_grab`(819)/`can_grab`(776)/`lift_limit`(806)/`weight_of`(827) → `_take_hold`(245) → `_holds` 표 → `push_holds`(351) | 완료 | **서버** (보유 관계·들기 한계·거리). 잡힌 몸의 **위치는 잡힌 클라**가 씀 | 혼합: `grab_range`, `grab_cursor_radius`, `lift_per_strength`, `grab_one_hand_strength_mult`, `one_hand_weapon`, `stamina_hold_per_sec` 데이터; `INTENT_RANGE_SLACK 1.5`, `HOLD_GRACE 0.6`, `HOLD_SETTLE 0.6`, `HOLD_LOST_GRACE 0.25`, `VIEW_HEARTBEAT 0.5` 코드 |
| 놓기 | `drop`(179) → `Intent.DROP` → `_rule_drop`(921) | 완료 | 서버 | — |
| 던지기 (포물선) | `press_throw`(113)/`release_throw_key`(121)/`throw`(151) → `Intent.THROW`(`target`=커서 지점, `charge`) → `_rule_throw`(850) → `_arc_to`(901) → `send_force(target)` | 완료 | **서버**가 속도 벡터를 품(발사 속도·각). 적용은 대상 소유자(돌·허수아비 = 서버, 사람 = 그 클라) | 혼합: `throw_arc_max_range_base`, `throw_hold_threshold`, `throw_charge_max`, `stamina_charge_per_sec`, `ratio_k_jump`(차용) 데이터; 최적각 식(915), `maxf(charge,0.1)`(907), 거리 0일 때 `sqrt(2g·0.5)`(906), 조준점 없을 때 `direction*3.0`(872) 코드 |
| 던지기 (직선, Shift) | 같은 경로, `line=true` → `throw_line_power_base × max(charge,0.2) × ratio_mult` (864-869) | 완료 | 서버 | 혼합 (`maxf(charge, 0.2)` 코드). 피해 `shove_damage × charge` |
| 탈출 (잡힌 상태 Space 연타) | `escape_press`(187) → `Intent.ESCAPE` → `_rule_escape`(933) → `_end_hold` + `send_force(KNOCKBACK, escape_recoil_power)` | 완료 | 서버 | 데이터(`grabbed_escape_presses/window`, `escape_recoil_power`, `stamina_escape_press`) |
| 등반 (벽 잡기·오르내리기·옆면 규칙·턱 넘기) | `player_movement.gd:order_climb`(785)/`_try_attach_climb`(835)/`try_air_catch`(807) → `player_climb.gd:attach`(59)/`_physics_process`(158)/`_check_ends`(211)/`_mantle_step`(240)/`detach`(148) | 완료 (F) | **입력한 클라**. 서버 `_check_move`는 CLIMB/MANTLE 상태를 **검사에서 제외**(1377-1378) | 혼합: `climb_speed`, `climb_attach_distance`, `stamina_climb_drain` 데이터; `HANG_DISTANCE 0.35`, `MANTLE_TIME 0.3`, `DETACH_PUSH 2.0`, `VERTICAL_LIMIT 0.3`, `SIDE_FACE_LIMIT 0.7`, `EDGE_PROBE 0.45`, `CATCH_REACH 0.3` 등 코드 |
| 낙하 피해 | 소유 클라 `player.gd:_update_fall_tracking`(299)/`_resolve_fall_damage`(321) → `Intent.FALL(peak, land)` → `_rule_fall`(1185: 서버가 `_fall_watch` 정점과 대조, 차이 1.5m 초과면 서버 값 사용) → `server_damage` | 완료 | **서버** (보고는 클라, 대조는 서버) | 데이터(`fall_damage_min_height/per_meter/enabled`, `ally_fall_death`) + 코드(`FALL_REPORT_TOLERANCE 1.5`, `FALL_PEAK_HOLD 0.6`) |
| 머리 밟기 (발판) | `player_movement.gd:_stand_on_head`(459)/`_floor_body`(498)/`_clear_head_stand`(452); `player.gd:_ready`의 `platform_on_leave = ADD_VELOCITY`(200) | 완료 (D) | 입력한 클라 (밟는 쪽) | 데이터(`head_stomp_time`) + 코드(법선 `> 0.5`(503), 탐침 `+0.3`(507)) |
| 경직 | 서버 `_rule_hurt`(1027)가 `stun_apply` 결정 → 소유 클라 `_apply_stun`(709), `_stunned_step`(679) | 완료 | 서버 판정, 상태 전환·타이머는 소유 클라 | 데이터(`shove_stun_time`, `ally_ground_stun`) + 코드(경직 중 마찰 `10.0*delta`(681)) |
| 사망·리스폰 | `server_damage`(1098)/`server_kill`(1108)/`server_respawn`(1133)/`_watch_vitals`(1220: 킬 플레인·리스폰 타이머) → 소유 클라 `enter_dead_now`(521)/`apply_respawn`(551); R키 `respawn`(533) → `Intent.RESPAWN` | 완료 | **서버** (HP·사망 플래그·타이머). **리스폰 위치는 소유 클라**가 `_free_spawn_point`(573)로 고름 | 데이터(`kill_plane_y`, `respawn_delay`) + 코드(`RESPAWN_ECHO_GRACE 0.5`, 스폰 간격 `1.2`(584)) |
| 막기 | **없음.** 자리만 주석: `force_system.gd:130-131` ("막는 중이면 여기서 보정한다") | 없음 | 없음 | — |
| 넉백 허용치 (미끄러짐/튕겨나감) | `force_system.gd:judge_knockback`(146) ← `server_authority.gd:_rule_knockback`(1059) → 이벤트에 `knock_*` 기록 → `player.gd:apply_force_event`가 결과대로 적용 | 완료 (H-2) | **서버** 판정, 적용은 맞은 쪽 클라 | 데이터(`tolerance_per_strength`, `launch_min_up_speed`, `knock_lift_angle_deg`) + 서버 표(`race_tolerance_mults`) |
| 돌 (들기·던지기·맞기) | `rock.gd`: `apply_force_event`(253, 던져질 때 속도 대입), `_on_body_entered`(278, 속도 ≥ 3.0이면 `send_force(KNOCKBACK)`), `push_state`(191, 0.05초), 보유 시 손 위치 추종(170-181) | 완료 (E) | **서버**(권한 1, 호스트 시뮬) | 코드: `HIT_SPEED 3.0`, `HIT_COOLDOWN 0.5`, `HIT_POWER_PER_SPEED 0.6`, `HIT_DAMAGE 4.0`, `THROWER_GRACE 0.3`, 반지름 `0.3 + 0.012×무게`(137), 중력은 `Tuning.gravity`로 덮음(`_apply_gravity` 129) |
| 허수아비 | `dummy.gd`: `apply_force_event`(96), `_physics_process`(120: 귀환·보유 추종), `push_state`(196) | 완료 | 서버 | 코드: `WEIGHT 12.0`, `MAX_HP 60`, `RETURN_DELAY/SPEED 2.0`, 마찰 `12.0*delta`(172-173), 캡슐 0.4/1.8(68-76) |
| 무기 선택대 | `weapon_rack.gd:interact`(45) → `player.set_weapon`(594, **로컬 호출, 서버 승인 없음**) → `sync_weapon` 복제 | 완료 (로컬 승인) — v4 H-4에서 서버 승인으로 바꿀 예정 | **입력한 클라** | 코드(`SPACING 2.2`, 구역 크기 등) |
| 능력치 디버그 슬라이더 (근력·무게·장비) | `debug_panel.gd:_ask_stats` → `Intent.STATS` → `_rule_stats`(669, 클램프) → Vitals 복제(`sync_*_override`, `sync_gear_weight`) | 완료 (H-1) | 서버 | 범위는 코드 상수(`DEBUG_STRENGTH_RANGE 1~150`, `DEBUG_WEIGHT_RANGE 20~200`, `DEBUG_GEAR_RANGE 0~80`) |
| 종족 배수 슬라이더 | `_ask_race_mult` → `Intent.RACE_MULT` → `_rule_race_mult`(699) → `push_race_mults`(393) | 완료 (H-2 후속), 값은 전 종족 1.0 자리만 | 서버 | 범위 코드 상수(`DEBUG_RACE_MULT_RANGE 0~3`) |
| 스태미나 | `player.stamina` (소유 클라 변수). 소모: 돌진(`request_dash`), 등반(`player_climb.gd:167`), 들기·충전(`player_grab.gd:263-269`), 탈출(190). 회복 `player.gd:445` | 완료 (v3) | **입력한 클라**. **복제되지 않는다** (어느 `SceneReplicationConfig`에도 없음) | 데이터(`stamina_max/climb_drain/regen/dash_cost/hold_per_sec/charge_per_sec/escape_press`) |
| 예측 표시 (누름 즉시 모션) | `player.gd:begin_predicted`(841)/`clear_predicted`(852); 서버 거부 시 `intent_refused`(486) | 완료 (C) | 로컬 표시, 서버가 취소 | 코드(`PREDICT_SHOW 0.8`) |
| 원격 바디 표시 | `player.gd:_physics_process` 457-480: 2m 넘으면 스냅+충돌 끔 0.2초, 아니면 `lerp(1-exp(-18·dt))` | 완료 | 공용 코드 (각 피어가 자기 화면) | 코드(`TELEPORT_STEP 2.0`, `TELEPORT_BLIND 0.2`, 18/20) |
| 종족 선택대 | **없음** (H-4) | 없음 | — | — |
| 지구력 → HP·스태미나 | **없음** (H-3). `CharacterStats.max_hp = 100.0` 고정, `Tuning.stamina_max = 100.0` | 없음 | — | — |
| 카메라·HUD·투명화·디버그 패널 | `quarter_camera.gd`, `status_bars.gd`, `occlusion_fader.gd`, `debug_panel.gd`, `aim_indicator.gd` | 완료 | 로컬 | 코드(카메라 55°/18m 등) |

---

## 2. 힘 이벤트 함수

### 2.1 구조 (사실)

하나의 문이 **두 겹**이다.

1. **서버 쪽 깔때기** — `scripts/world/server_authority.gd:984`
   ```gdscript
   func send_force(target: Node, event: Dictionary) -> void
   ```
   하는 일(순서대로): `force_history` 기록(최근 64개) → `_rule_knockback`(대상이 Player면: `judge_knockback` 호출, 결과를 `event["knock_h_speed" | "knock_tolerance" | "knock_launched" | "knock_judged"]`에 기록) → 튕겨나감이면 보유 표에서 `_end_hold`(대상이 들려 있으면 `target_pushed`, 대상이 들고 있으면 `holder_pushed`) → `_rule_hurt`(HP를 서버가 쓰고 `event["stun_apply"]` 결정; 미끄러짐이면 0) → `_remember_force`(이동 검사 허용치 1.5초) → `_note_flight_source`(낙하 피해의 아군 여부) → `ForceSystem.send`.

2. **전달과 적용** — `autoload/force_system.gd`
   ```gdscript
   static func make_event(kind: int, direction: Vector3, base_power: float,
       source_strength: float, source_peer: int, is_ally_source: bool,
       damage: float = 0.0, stun_time: float = 0.0) -> Dictionary
   func send(target: Node, event: Dictionary) -> void          # 대상의 권한 피어로 라우팅
   @rpc("any_peer", "call_remote", "reliable")
   func receive_force(path: NodePath, event: Dictionary)       # valid_sender: 보낸 피어가 1이어야 함
   func power_for(event, total_weight) -> float                # base_power × ratio_mult(source_strength / total_weight, k_push); source_strength 0이면 배율 없음
   func change_for(event, total_weight) -> Vector3             # direction × power
   func tolerance_for(target_strength, race_mult) -> float     # target_strength × tolerance_per_strength × race_mult  (막기 보정 자리 주석)
   func lift_angle_deg(event) -> float
   func judge_knockback(event, total_weight, target_strength, race_mult, grounded) -> {h_speed, tolerance, judged, launched}
   ```
   이벤트 사전 필드: `id`(서버 프로세스의 `static var _next_id`), `at`(만든 기계의 `Time.get_ticks_msec`), `kind`(SHOVE/THROW/KNOCKBACK/RECOIL/DEBUG), `direction`(정규화), `base_power`, `source_strength`, `source_peer`, `is_ally_source`, `damage`, `stun_time` + 서버가 덧붙이는 `stun_apply`, `knock_*`, `spring`(아군 발사).

   **받는 쪽이 계산한다.** 무게(`stats.total_weight()` = 종족 무게 + 장비 + 든 것)는 받는 쪽이 자기 것을 넣는다. 수신 함수는 세 개뿐: `player.gd:620 apply_force_event`, `rock.gd:253`, `dummy.gd:96`.

   `player.gd:apply_force_event`(620-692)의 적용 규칙: 미끄러짐이면 `change.y = 0`; 튕겨나감이고 지상이면 `velocity = change`, `velocity.y`를 `launch_min_up_speed` 이상으로, `AIRBORNE`, 그 뒤 `stun_apply`만큼 `STUNNED`; 이미 공중이면 `velocity += change`; `spring`이면 `velocity.y = get_jump_velocity()`로 **대체** 후 더함; 등반 중이면 `climb.detach(0)`; 튕겨나감이면 `grab.on_force_received()`(잡혀 있던 몸을 풀어 보유자 옆에 놓음); 항상 `movement.note_pushed()`(지상 미끄러짐 창 `force_slide_time`).

### 2.2 문을 거치는 것 (호출처 grep, 테스트 제외)

| 출처 | 파일:줄 | kind | source_strength |
| --- | --- | --- | --- |
| 밀치기 대상 | `server_authority.gd:609` | SHOVE | 미는 쪽 근력 |
| 밀치기 반동 (미는 쪽) | `server_authority.gd:621` | RECOIL | 미는 쪽 근력 |
| 던지기 (돌·허수아비·사람) | `server_authority.gd:882` | THROW | **0** (근력은 `_arc_to`/직선식에 이미 들어감) |
| 탈출 반동 | `server_authority.gd:969` | KNOCKBACK | 0 |
| 날아가는 돌에 맞음 | `rock.gd:300` (`_on_body_entered`, 속도 ≥ `HIT_SPEED` 3.0) | KNOCKBACK | 0 |
| 하네스 | `playground.gd:456,471,699,1336,1449,1460`, `scripts/tests/*` | THROW/SHOVE 등 | 임의 |

### 2.3 문을 거치지 않는 속도·위치 변화 (사실 + 이유)

규칙은 "남의 속도를 쓰지 말 것(자기 자신·자기 부모만 허용)"이고, 아래는 전부 **자기 몸에 쓰는 것**이라 감사(hazard 6)에는 걸리지 않지만, "위치를 서버가 정한다"는 새 규칙에서는 전부 **클라가 스스로 위치·속도를 바꾸는 경로**다.

| 동작 | 위치 | 왜 문 밖인가 |
| --- | --- | --- |
| 등반 놓기 | `player_climb.gd:148-155 detach`: `player.velocity = wall_normal * push` (`DETACH_PUSH 2.0`, 스태미나 소진 시 `0.5`) | 자기 몸의 자발 동작으로 취급. 힘 이벤트 아님 |
| 등반 붙기 | `player_climb.gd:77-81`: 벽면으로 **위치 대입** (`HANG_DISTANCE 0.35`) | 한 스텝 배치. `_check_move`가 CLIMB을 제외하는 이유 |
| 잡힌 몸의 손 추종 | `player_grab.gd:287-289`: `player.global_position = holder.hand_position()` 매 스텝 | 잡힌 **클라**가 자기 화면의 보유자 위치로 씀 |
| 잡힘에서 풀릴 때 | `player_grab.gd:211-237 _leave_held`: 보유자 옆(`BODY_RADIUS*2.2`)으로 **위치 대입** | 힘이 아니라 배치. 그 뒤 반동은 문을 거침 |
| 머리 밟기 후 미끄러짐 | `player_movement.gd:459-497 _stand_on_head` (`floor_snap_length = 0` 등) | 자기 몸. `send_force` 호출 없음 |
| 발판의 속도 상속 | `player.gd:200 platform_on_leave = PLATFORM_ON_LEAVE_ADD_VELOCITY` | **엔진**이 더한다. 머리 위에 선 몸이 보유자 이동 속도를 받는 경로 |
| 느린 돌·몸 접촉 | 돌은 속도 < 3.0이면 `_on_body_entered`가 무시. 물리 솔버의 접촉 밀림은 그대로 일어남 | 엔진 접촉. 크기는 **(추측)** 작지만 측정 안 함 |
| 원격 바디 스윕 | `player.gd:466-473` (2m 이하 lerp) | 표시용 보간이지만 충돌체가 함께 움직여 옆 몸을 민다(hazard 4). 2m 초과는 스냅+충돌 끔 |
| 허수아비 귀환 | `dummy.gd:177-184` | 서버가 자기 바디에 씀 |
| 리스폰·R | `player.gd:551 apply_respawn`: `global_position = _free_spawn_point()` | 소유 클라가 위치 대입. 서버는 HP·플래그만 |
| 하네스 배치 | `playground.gd` 다수 (`local.velocity = ...`, `rock.linear_velocity = 0`) | 검사용 |
| 무기 선택 | `weapon_rack.gd:51` → `set_weapon` | 힘 없음. 서버 승인도 없음(H-4 예정) |

---

## 3. 캐릭터 상태 머신

### 3.1 상태 (`player.gd:8-19`)
`IDLE, MOVE, AIRBORNE, DASH, CLIMB, MANTLE, GRABBING, GRABBED, STUNNED, DEAD`

전환은 전부 `player.gd:271 change_state(new_state)` 하나. 거기서 `_update_fall_tracking`(공중 진입 시 정점 추적 시작, 착지 시 `Intent.FALL` 보고), `_update_hold`(GRABBED에서 벗어나면 `grab.clear_holder`), 색·라벨 갱신. `DEAD`에서는 `_respawning` 플래그 없이는 못 나간다(274-275).

### 3.2 누가 어떤 상태를 쓰는가 (전부 **소유 클라**에서, `is_local()` 가드 뒤)

| 상태 | 들어가는 곳 | 나가는 곳 |
| --- | --- | --- |
| IDLE/MOVE | `_ground_step`(426-429): 이동 명령 유무 | — |
| AIRBORNE | `_launch_jump`(659), `_ground_step` 바닥 상실(447), `request_dash`→`_end_dash`(931), `apply_force_event` 튕겨나감(677), `spring`(661) | `_air_step` 착지(744-745): 바닥이면 MOVE/IDLE. `_update_fall_tracking`이 착지 종류(IDLE/MOVE/DASH/GRABBING)에만 낙하 보고 |
| DASH | `request_dash`(893) | `_dash_step`(919-922) → `_end_dash` |
| CLIMB/MANTLE | `player_climb.attach`(81), `_check_ends`(211) | `detach`(148), `_mantle_step`(240) |
| GRABBING | `player_grab._physics_process`(313-314): 서버 표에 내 행이 있고 지상이면 | 행이 사라지면 IDLE(327) |
| GRABBED | `player_grab._physics_process`(283): 서버 표가 나를 대상으로 가지면 | 행이 사라지면 `_leave_held`(296) |
| STUNNED | `_apply_stun`(709): 서버의 `stun_apply`를 받은 튕겨나감 | `_physics_process`(438-441) 타이머 `_stun_left` 끝 → IDLE |
| DEAD | `enter_dead_now`(521): 서버 `sync_dead` 또는 `enter_dead` RPC | `apply_respawn`(551): 서버 `apply_respawn` RPC 또는 R키 |

복제: 소유 클라가 매 스텝 `sync_state = state`(449); 원격은 `change_state(sync_state)`(479). **서버는 원격 몸의 상태를 복제본으로만 안다.**

### 3.3 "외부 힘을 받았다"를 구분하는 것

전용 상태는 **없다.** AIRBORNE은 자기 점프·낙하·발사를 구별하지 않는다. 있는 플래그·기록:

| 이름 | 어디 | 의미 | 복제 |
| --- | --- | --- | --- |
| `_pushed_left` | `player_movement.gd:69`, `note_pushed`(114) | 지상에서 힘을 받은 뒤 `force_slide_time`(0.25s) 동안 이동 명령이 속도를 덮지 못함. 새 클릭이면 0으로 | 안 됨 (로컬) |
| `_jumped_this_flight` / `sync_jumped` | `player.gd:146, 83`, `note_jumped`(481) | 이 비행이 **자기 점프**임. 보유 표의 `_can_keep_holding`이 읽음 | 됨 (소유자 Synchronizer) |
| `sync_knock` | `player.gd:125`, `_show_knock`(695) | 마지막 힘의 `h_speed / tolerance 결과` 문자열, 2초 | 됨 (표시용) |
| `_move_watch[peer].h/v/hold` | `server_authority.gd:_remember_force`(1330) | 서버가 준 힘의 수평·수직 dv 최대값, 1.5초(`FORCE_MEMORY`) 동안 이동 검사 허용치에 더함 | 서버 전용 |
| `force_history` | `server_authority.gd:151` | 최근 64개 힘 이벤트(id, at, kind, target, source_peer, base_power) | 서버 전용 |
| `last_knock[peer]` | `server_authority.gd:154` | 마지막 허용치 판정 | 서버 전용 (하네스용) |
| `_flight_source[peer]` | `_note_flight_source`(1484) | 누가(아군인지) 이 비행을 시작했나. `source_peer == 0 또는 자기 자신`이면 기록 안 함 → 돌 맞음(`source_peer 1`)은 **호스트가 맞을 때는 기록되지 않는다** | 서버 전용 |
| `_fall_watch[peer].peak/air_at` | `_watch_vitals`(1220) | 서버가 본 정점, 마지막 공중 시각 | 서버 전용 |
| `holder_peer` | `player.gd:132`, `set_hold_display` | 보유 표의 읽기 전용 사본 (누가 나를 들고 있나) | `push_holds`로 전 피어 |

---

## 4. 능력치·종족 데이터

| 값 | 어디에 | 형태 |
| --- | --- | --- |
| 근력·지구력·민첩·지능·키·무게 | `data/races/{human,elf,dwarf,orc}.tres` (`RaceData` 리소스, `data/race_data.gd`) | 리소스. 인간 60/70/70/70/180/80, 엘프 50/70/90/60/170/60, 드워프 80/100/40/50/150/90, 오크 100/80/60/10/220/140 |
| 종족 id·로더 | `data/races.gd` (`Races.Kind`, `PATHS`, `DEFAULT = HUMAN`, `data_for` 캐시 `static var _cache`) | 스크립트 |
| 몸의 시트 | `data/character_stats.gd` (`CharacterStats`): `race`, `strength_override`, `weight_override`, `gear_weight`, `max_hp = 100.0`, `held_weight`. `strength/race_weight/endurance/agility/intellect/height_cm`은 **읽기 전용 파생 속성** | 리소스 스크립트. `data/default_stats.tres`는 비어 있음(기본값 사용). `player.gd:182`에서 몸마다 `duplicate(true)` |
| 서버 소유 복제 | `player.tscn` `Vitals` 동기화기(권한 1): `hp, sync_dead, sync_race, sync_strength_override, sync_weight_override, sync_gear_weight`. 적용은 `player.gd:_sync_stats`(399) | 씬 |
| 종족별 배수 | `server_authority.gd:164-165` `race_tolerance_mults / race_move_mults` (`PackedFloat32Array`, 전부 1.0), `push_race_mults` RPC | 스크립트 변수 (서버가 쓰고 복제) |
| 기준 비율 | `PhysicsTuning.ratio_ref = 0.75` → `Tuning.ratio_mult`(`tuning.gd:35`) | 데이터 |
| 들기 한계 | `PhysicsTuning.lift_per_strength = 1.2` | 데이터 |
| 키 → 캡슐 | **연결 안 됨.** `Player.BODY_HALF_HEIGHT 0.9 / BODY_RADIUS 0.4`는 `const`(player.gd:28-29), 캡슐·그림자·손 높이·판정 전부 이 상수 | 코드 |
| 허수아비 무게 | `dummy.gd:17 WEIGHT 12.0` 한 곳 (`ServerAuthority.DUMMY_WEIGHT`가 참조) | 코드 |
| 돌 무게 | `playground.gd:66` `[5, 10, 20, 40, 80, 120]` | 코드 |

### v4 단계 H 적용 현황 (커밋 기준)

| 단계 | 상태 | 근거 |
| --- | --- | --- |
| H-0 조사 | 완료 | 코드 변경 없음 |
| 선행 `sync_jumped` 미복제 | 완료 | `47e572a` (tscn 선언 순서, `HOLD_LOST_GRACE`) |
| H-1 100점 스케일·종족 데이터·서버 소유·하네스 문·무거운 돌 | 완료 | `6b50ed3`, `9839422` |
| H-2 버티는 힘 삭제·넉백 허용치·`race_*_mult` | 완료 | `7c4186a`, `4748639`. `grep -rni brace` 0건 |
| H-3 지구력 → HP·스태미나 | **미착수** | `hp_per_endurance`, `stamina_base`, `stamina_per_endurance` 없음. `max_hp` 100 고정, `stamina_max` 100 고정, 스태미나 미복제 |
| H-4 종족 선택대·캡슐 가변·무기 선택대 서버 승인 | **미착수** | 선택대 없음, `BODY_HALF_HEIGHT` const, `set_weapon` 로컬 |
| 민첩·지능 | 값만 저장 (v4대로) | `CharacterStats.agility/intellect` 읽는 곳 없음 (grep) |

---

## 5. 튜닝 값

### 5.1 슬라이더로 빠진 것 (데이터)

- **`data/physics_tuning.gd`의 모든 `@export` float/int/bool** — `debug_panel.gd:124-145`가 속성 목록을 돌며 자동으로 슬라이더/체크박스를 만든다 (범위는 `numeric_limits`: 0~값×4, 최소 1). 그룹별:
  - Movement: `gravity 22`, `base_move_speed 6`, `base_jump_height 1.6`, `move_intent_timeout 1.5`, `jump_inplace_radius 0.8`, `jump_min_hop_height 0.2`, `jump_ledge_margin 0.4`, `jump_aims_at_cursor`, `jump_aim_deadzone 1.2`
  - Strength to weight: `ratio_ref 0.75`, `ratio_k_jump 0.35`, `ratio_k_speed 0.30`, `ratio_mult_min 0.7`, `ratio_mult_max 1.3`
  - Dash: `dash_min_distance 1.2`, `dash_speed_mult 2.0`, `dash_cooldown 1.0`
  - Climb: `climb_speed 2`, `climb_attach_distance 0.6`, `stamina_max 100`, `stamina_climb_drain 15`, `stamina_regen 25`, `stamina_dash_cost 10`
  - Force: `shove_power 7`, `shove_up_bias 0.25`, `throw_power 11`, `throw_up_angle_deg 35`, `grab_range 1.5`, `lift_per_strength 1.2`, `grab_one_hand_strength_mult 2`, `one_hand_weapon`, `throw_hold_threshold 1`, `throw_charge_max 1.5`, `throw_arc_max_range_base 10`, `throw_line_power_base 12`, `grab_cursor_radius 1`, `stamina_hold_per_sec 5`, `stamina_charge_per_sec 8`, `stamina_escape_press 3`, `grabbed_escape_presses 5`, `grabbed_escape_window 2`, `shove_damage 3`, `shove_stun_time 0.4`, `shove_cooldown 0.6`, `shove_range 1.5`, `shove_width 1.2`, `shove_recoil 0.3`, `shove_ally_launch_angle_deg 50`, `k_push 0.35`, `tolerance_per_strength 0.12`, `launch_min_up_speed 2`, `knock_lift_angle_deg 60`, `head_stomp_time 0.5`, `force_slide_time 0.25`, `force_slide_friction 6`, `same_party`, `escape_recoil_power 4`, `server_speed_tolerance 1.25`, `ally_ground_damage`, `ally_ground_stun`
  - Controls: `smart_key_enabled`
  - Survival: `fall_damage_min_height 4`, `fall_damage_per_meter 8`, `fall_damage_enabled`, `ally_fall_death`, `kill_plane_y -20`, `respawn_delay 2`
- **주의:** `Tuning.values`는 **피어마다 로컬 사본**(`tuning.gd:26` "Duplicated on purpose"). 서버 판정에 쓰이는 값도 서버의 사본을 읽을 뿐, 클라와 맞춰 주는 장치는 "호스트 튜닝 받아오기" 버튼(`request_tuning`/`send_tuning`)뿐이다.
- `throw_power`, `throw_up_angle_deg`는 슬라이더에 있지만 **게임 판정이 읽지 않는다** — `_rule_throw`는 `throw_arc_max_range_base/throw_line_power_base`를 쓰고, 둘은 `playground.gd:1058-1062`(단계 8 하네스)만 읽는다 (grep 기준).
- 능력치: `strength / race_weight / gear_weight` 슬라이더 → 의도 RPC (범위 `debug_panel.gd:STAT_RANGES` + 서버 `DEBUG_*_RANGE`).
- 종족 배수 8개 → 의도 RPC (범위 `DEBUG_RACE_MULT_RANGE`).

### 5.2 코드에 박힌 숫자 (슬라이더 없음)

`const`와 인라인 리터럴 중 동작에 영향을 주는 것. 표시·색·메시 치수는 뺐다. 0/1/부호 반전/`maxf(x, 0.0)` 류 가드는 뺐다.

| 파일:줄 | 값 | 용도 |
| --- | --- | --- |
| `player.gd:28-29` | `BODY_RADIUS 0.4`, `BODY_HALF_HEIGHT 0.9` | 캡슐·손 높이·밀치기 직사각형 보정·머리 발판 높이 (6파일 20곳이 참조, H-0 집계) |
| `player.gd:32` | `HAND_HEIGHT 0.8` | 손 = 중심 + 0.9 + 0.8 |
| `player.gd:46-47` | `TELEPORT_STEP 2.0`, `TELEPORT_BLIND 0.2` | 원격 바디 스냅 기준·충돌 끔 시간 (rock/dummy에도 같은 값이 **각각** 선언됨: `rock.gd:32-33`, `dummy.gd:25-26`) |
| `player.gd:110` | `_default_snap 0.3` | 바닥 스냅 길이 |
| `player.gd:129` | `KNOCK_SHOW_TIME 2.0` | 허용치 표시 시간 |
| `player.gd:144` | `RESPAWN_ECHO_GRACE 0.5` | 리스폰 결과와 플래그 패킷 순서 유예 |
| `player.gd:472-473` | `18.0`, `20.0` | 원격 위치/회전 lerp 계수 (rock/dummy도 18) |
| `player.gd:584` | `1.2` | 스폰 지점이 비었다고 보는 반경 |
| `player.gd:753` | `turn_speed 16.0` | 몸 회전 속도 |
| `player.gd:831` | `PREDICT_SHOW 0.8` | 예측 표시 유지 시간 |
| `player_movement.gd:10-29` | `DRAG_RETARGET_INTERVAL 0.1`, `ARRIVE_TOLERANCE 0.3`, `PATH_LOOKAHEAD 0.75`, `PATH_QUERY_RETRIES 4`, `UNREACHABLE_DISTANCE 0.5`, `JUMP_BUFFER 0.1`, `COYOTE_TIME 0.1`, `CATCH_BUFFER 0.3`, `CATCH_REACH 0.3`, `CATCH_PROBES 8` | 이동·점프 입력 창, 공중 벽잡기 탐침 |
| `player_movement.gd:430, 683` | `-0.5` | 바닥에 눌러 두는 수직 속도 (dummy.gd:171도 같은 값) |
| `player_movement.gd:503, 507` | `0.5`, `0.3` | 머리 발판 판정 법선 임계·아래 탐침 길이 |
| `player_movement.gd:605` | `0.25` | 최대 사거리 점프의 정점 = reach × 0.25 |
| `player_movement.gd:623`, `server_authority.gd:915` | `PI/4 + atan2/2` | 최적 발사각 (점프와 던지기에 **두 벌**) |
| `player_movement.gd:671` | `/ sqrt(2)` | 돌진 점프의 45° 분배 |
| `player_movement.gd:681-682` | `10.0` | 경직 중 지상 마찰 |
| `player_movement.gd:780` | `TOP_SURFACE 0.6` | 설 수 있는 면의 법선 y |
| `player_movement.gd:790` | `0.4` | 벽에서 떨어져 서는 거리 (= `climb_attach_distance` 0.6과 **별개 숫자**) |
| `player_movement.gd:958, 1014` | `200.0`, `500.0` | 커서 레이 길이 |
| `player_movement.gd:1081, 1095` | `0.05`, `0.01` | 경로 스텝·방향 최소 길이 |
| `player_grab.gd:19` | `FREED_GRACE 0.4` | 힘으로 풀린 뒤 표의 옛 행을 무시하는 시간 |
| `player_grab.gd:229-231` | `BODY_RADIUS × 2.2` | 풀릴 때 보유자 옆 거리 |
| `player_climb.gd:12-30` | `HANG_DISTANCE 0.35`, `EDGE_ON_LIMIT 0.35`, `ARRIVE 0.25`, `MANTLE_TIME 0.3`, `DETACH_PUSH 2.0`, `EDGE_PROBE 0.45`, `VERTICAL_LIMIT 0.3`, `SIDE_FACE_LIMIT 0.7` | 등반 기하·규칙 |
| `player_climb.gd:169` | `detach(0.5)` | 스태미나 소진 시 밀어내는 속도 |
| `player_climb.gd:196-227` | `0.05`, `0.1`, `+0.4`, `+0.15`, `1.2` | 벽 연속·턱 탐침 |
| `server_authority.gd:47-113` | `INTENT_TIMEOUT 1.0`, `HOLD_GRACE 0.6`, `HOLD_LOST_GRACE 0.25`, `HOLD_SETTLE 0.6`, `VIEW_HEARTBEAT 0.5`, `INTENT_RANGE_SLACK 1.5`, `FALL_REPORT_TOLERANCE 1.5`, `FALL_PEAK_HOLD 0.6`, `AIRBORNE_MEMORY 0.3`, `MOVE_SAMPLE 0.1`, `FORCE_MEMORY 1.5`, `MOVE_FORGIVE_SAMPLES 2` | 서버 판정의 유예·표본·허용 |
| `server_authority.gd:154` | `FORCE_HISTORY_MAX 64` | 힘 이력 길이 |
| `server_authority.gd:166, 659-664` | `DEBUG_RACE_MULT_RANGE 0~3`, `DEBUG_STRENGTH_RANGE 1~150`, `DEBUG_WEIGHT_RANGE 20~200`, `DEBUG_GEAR_RANGE 0~80` | 슬라이더 범위(서버가 강제) |
| `server_authority.gd:289, 294` | `× 0.5`, `+ 0.5` | "밟고 있던 것을 집었다" 판정 |
| `server_authority.gd:566` | `8` | 밀치기 질의 최대 충돌 수 |
| `server_authority.gd:867, 872, 906, 907` | `max(charge, 0.2)`, `direction * 3.0`, `sqrt(2g·0.5)`, `max(charge, 0.1)` | 던지기 하한·기본 조준·제자리 던지기 |
| `server_authority.gd:1144` | `30` | 원격 리스폰 뒤 이동 검사 용서 표본 수 |
| `server_authority.gd:1209` | `hp - 1.0` | 아군 낙하 사망 금지 시 남기는 HP |
| `server_authority.gd:1321` | `× 2.0` | 수직 허용치에 더하는 중력 표본 수 |
| `rock.gd:15-22` | `HIT_SPEED 3.0`, `HIT_COOLDOWN 0.5`, `HIT_POWER_PER_SPEED 0.6`, `HIT_DAMAGE 4.0`, `THROWER_GRACE 0.3`, `STATE_INTERVAL 0.05` | 돌 피격·복제 |
| `rock.gd:78, 82, 137, 262, 294` | `angular_damp 2`, `friction 1`, 반지름 `0.3 + 0.012w`, 회전 `±4`, `direction.y ≥ 0.15` | 돌 물리·피격 방향 하한 |
| `dummy.gd:9-21` | `RETURN_DELAY 2`, `RETURN_SPEED 2`, `MAX_HP 60`, `WEIGHT 12`, `STATE_INTERVAL 0.05` | 허수아비 |
| `dummy.gd:68-76, 172-173, 180` | 캡슐 0.4/1.8, 마찰 `12.0`, 귀환 임계 `0.2` | 허수아비 몸·귀환 |
| `weapon_rack.gd:11, 41, 82` | `SPACING 2.2`, 구역 크기 | 선택대 배치 |
| `net.gd:6-7, 84` | `DEFAULT_PORT 7777`, `MAX_PEERS 4`, 클라 접속 지연 `1.5`s | 네트워크 부트스트랩 |
| `playground.gd:25-28, 66, 1823-1833` | `THROW_LANE`, `AGENT_RADIUS 0.45`, `CELL_SIZE 0.25`, 돌 무게 배열, 등반 링 좌표 | 맵·내비 |
| `quarter_camera.gd:7-8` | `55°`, `18 m` | 카메라 |
| `project.godot:90-91` | `physics_ticks_per_second 120`, Jolt | 엔진. 기본 중력 9.8은 돌이 `_apply_gravity`로 `Tuning.gravity`(22)로 덮음 |

중복 선언(한 숫자가 두 곳): `TELEPORT_STEP/TELEPORT_BLIND`(player/rock/dummy), lerp 계수 18(player/rock/dummy), 바닥 누름 `-0.5`(movement/dummy), 최적 발사각 식(movement/server_authority), `STATE_INTERVAL 0.05`(rock/dummy), 캡슐 치수(player const / dummy 리터럴).

---

## 6. 네트워크 관점: 새 권한 규칙을 적용할 때 바꿔야 할 곳 (상위 5개)

> **폐기된 안 (2026-10-30 결정).** "힘·잡힘 구간 위치 서버 소유" 규칙은 적용하지 않는다. 판정은 서버, 적용은 클라인 지금 구조를 유지하고, 대신 "검증 강화" 4개를 H-3 뒤 별도 단계 **N**으로 한다 (지시서는 H-3 보고 뒤). 아래 6.1~6.5는 그 결정 전에 쓴 분석으로 기록만 남긴다.

여기만 개선안이 들어간다.

### 6.1 플레이어 위치의 권한이 몸 단위로 고정돼 있고, 서버가 쓸 통로가 없다
- 사실: `player.gd:162 set_multiplayer_authority(name.to_int())`가 노드 전체(= `Synchronizer`)의 권한을 소유 피어로 둔다. `sync_position/sync_yaw/sync_state`는 소유 클라의 `_physics_process`(446-449)에서만 쓰이고, 다른 피어는 `466-479`에서 받아 lerp/스냅한다. 서버가 플레이어 위치를 쓰는 함수는 없다 (`server_respawn`조차 위치는 소유자가 고름).
- 규칙을 적용하려면: "서버 결정 구간" 동안 위치의 출처를 서버로 돌리는 통로가 필요하다. 이미 있는 패턴은 돌·허수아비의 `push_state` RPC(권한 1, 0.05초, 클라는 보여주기만). 플레이어에 같은 통로를 두고, **소유 클라가 그 구간엔 자기 시뮬레이션을 멈추고 받은 위치를 적용**하게 해야 한다. 구간의 시작(힘 수신·잡힘)과 끝(착지·놓임)을 **서버가** 선언해야 하고(아래 6.3, 6.5), 그 플래그는 `push_holds`처럼 서버→전 피어로 가야 한다(hazard 3).

### 6.2 힘의 적용과 비행이 맞은 쪽 클라에서 일어난다
- 사실: `ForceSystem.send`는 **대상의 권한 피어**로 보내고(`force_system.gd:50-59`), `apply_force_event`가 그 피어에서 `velocity`를 쓴다. 서버는 `judge_knockback`으로 dv의 수평 크기만 계산하고, 궤적은 시뮬레이션하지 않는다. 서버에 있는 원격 플레이어 바디는 "shown, not simulated"(`player.gd:474` 주석) — `move_and_slide`도 중력 적분도 돌지 않는다(`player_movement/_climb/_grab._physics_process`는 전부 `is_local()`에서 반환).
- 규칙을 적용하려면: 서버가 힘을 받은 몸을 **서버에서 적분**해야 한다(중력, 바닥 충돌, 미끄러짐 마찰). 그러려면 서버 쪽 원격 바디에 "서버 시뮬 모드"가 필요하고, `apply_force_event`의 속도 대입과 `_air_step/_ground_step`의 미끄러짐 부분(`_pushed_left`)이 서버에서도 실행 가능해야 한다. 지금 그 코드는 `PlayerMovement`에 있고 **소유 클라에서만 생성된다**(`player.gd:198-212`: `movement/climb/grab`은 `is_local()`일 때만 `new()`).

### 6.3 잡힌 몸의 위치를 잡힌 클라가 쓴다
- 사실: `player_grab.gd:283-289`. 보유 관계는 서버 표(`_holds`)이고 `push_holds`로 복제되지만, 위치는 잡힌 클라가 "자기 화면의 보유자 `hand_position()`"으로 매 스텝 쓴다. 보유자 위치 자체가 보유자 클라의 것이므로, 200ms에서 잡힌 몸은 보유자의 **옛 위치**를 따라간다. 돌·허수아비는 반대로 **서버**가 손 위치에 둔다(`rock.gd:170-181`, `dummy.gd:132-144`).
- 규칙을 적용하려면: 사람도 돌과 같은 쪽(서버)이 손에 두게 하면 된다 — 표가 이미 서버 것이라 6.1의 통로만 있으면 된다. 풀릴 때의 배치(`_leave_held` 211-237)도 서버로 옮겨야 "놓임까지 서버"가 된다.

### 6.4 서버 이동 검사가 경고뿐이고, 판정 숫자의 절반이 피어 로컬 `Tuning`에 있다
- 사실: `_check_move`(1345-1393)는 상한 초과를 `move_warnings += 1`과 로그로만 남긴다. 허용치(`move_allowance` 1303)는 `Tuning.values.server_speed_tolerance / gravity`와 `player.get_move_speed()/dash_speed()/leap_speed_cap()`을 쓰는데, `Tuning.values`는 **각 피어의 사본**이다(`tuning.gd:26`). 힘을 받은 뒤 소유 클라가 읽는 값도 로컬이다: `launch_min_up_speed`(`player.gd:676`), `force_slide_time/friction`(`player_movement.gd:115, 411`), `gravity`(`_air_step` 741), `shove_ally_launch_angle_deg`는 서버. 즉 클라가 슬라이더를 움직이면 **같은 힘 이벤트가 다른 궤적**이 된다. 서버로 옮긴 것은 능력치(H-1)와 종족 배수(H-2 후속)뿐.
- 규칙을 적용하려면: 위치를 서버가 정하는 순간 궤적은 서버 값으로 계산되므로 이 불일치는 **클라 표시가 서버 위치에 끌려가는 형태**로 드러난다. 따라서 (a) 검사를 "경고"에서 "서버 위치로 보정"으로 바꾸거나, (b) 최소한 궤적에 들어가는 Tuning 값(`gravity`, `launch_min_up_speed`, `force_slide_*`, `base_*`, `ratio_*`, `k_push`, `tolerance_*`)을 능력치처럼 서버 소유로 옮겨야 한다. `export_values/import_values`가 이미 있어 사전 하나로 복제하는 길은 있다.

### 6.5 "착지"와 "낙하"를 소유 클라가 판정한다
- 사실: 착지 전환은 `_air_step`(744)의 `is_on_floor()`, 낙하 보고는 `_update_fall_tracking`(299) → `Intent.FALL`. 서버는 `_fall_watch`로 정점만 보고 `FALL_REPORT_TOLERANCE 1.5m` 안이면 클라 보고를 믿는다. 서버에는 원격 바디의 바닥 접촉 정보가 없다(6.2).
- 규칙을 적용하려면: 서버 결정 구간의 **끝**(착지)을 서버가 알아야 하므로 서버 쪽 바닥 판정이 필요하다. 6.2를 하면 `is_on_floor()`를 서버에서 읽을 수 있다. 낙하 피해도 그때 서버 단독 판정으로 바꿀 수 있고 `Intent.FALL`은 없앨 수 있다.

### 6.6 서버에서 돌릴 수 없거나 피어마다 다른 코드 (지적)
| 종류 | 위치 | 비고 |
| --- | --- | --- |
| `Input` 직접 참조 (물리 스텝 안) | `player_movement.gd:386 Input.is_action_pressed("move_click")`, `player_grab.gd:132 Input.is_physical_key_pressed(KEY_SHIFT)` | 둘 다 `is_local()` 가드 뒤라 리슨 서버에선 문제 없음. **전용 서버에서 플레이어를 시뮬**하면 바로 걸림 |
| 커서·카메라 의존 | `player_movement.gd:955, 992, 1012` (`get_mouse_position` + `camera.project_ray_*`) → `cursor_direction/cursor_jump_target/_cursor_ground_point`. 점프·돌진 계획·밀치기 방향·잡기 대상 선택이 여기서 나온다 | 점프·돌진은 **의도 RPC가 없어** 서버가 재계산할 입력이 없다. 규칙상 이 둘은 클라 결정이므로 괜찮지만, 서버가 상한 외에 검사할 수 있는 건 없다 |
| `static var` (프로세스 전역) | `ServerAuthority.instance`(117), `ForceSystem._next_id`(23: 이벤트 id는 **만든 기계** 기준 — 서버만 만들므로 지금은 유일), `Races._cache`(25), `OcclusionFader._faded`(18) | 한 프로세스에 월드 하나일 때만 안전 |
| 기계 시각 | `Time.get_ticks_msec`: `force_system.gd:38`(event.at), `server_authority.gd:280, 1234, 1493, 1510`, `rock.gd:289`, `player.gd:845` | 전부 **같은 기계 안에서만 비교**한다(grep 기준). 서버가 만든 `at`을 클라가 비교하는 곳은 없다 |
| 씬 트리 전역 | `get_tree().current_scene`에 카메라·HUD·패널·조준 표시를 붙임(`player.gd:220-235`, `player_movement.gd:94`, `debug_panel.gd:252`) | 클라 전용. 서버 시뮬과 무관 |
| 피어 로컬 싱글톤 | `Tuning`(6.4), `Net.spawn_root/spawn_points` | — |
| 랜덤 | `rock.gd:262 randf_range` (던진 돌의 회전) | 서버에서만 실행. 시각만 다름 |
| 스태미나 미복제 | `player.stamina` | 서버가 돌진·등반·들기 비용을 검사하지 않는다. "속도·거리만 검사"엔 포함 안 되지만, 클라가 무한 스태미나로 돌진을 반복해도 서버는 쿨다운(`dash_cooldown`은 클라 로컬)·속도 상한 외엔 모른다 |

---

## 7. 테스트 방법

### 7.1 실행
- 엔진: `C:\Users\kevin\Downloads\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64_console.exe` (4.7.1 고정, `project.godot`은 CRLF 변환 M 상태로 두고 커밋하지 않음).
- 하네스 플래그 (`autoload/net.gd:59-84`): `--auto-host` / `--auto-join`(1.5초 뒤 127.0.0.1 접속) / `--auto-smoke` / `--auto-only=<단계>` / `--auto-port=N` / `--auto-quit=초`. 단계별 지연 라벨: `--d-latency=`, `--e-latency=`, `--be-latency=` 등(대기 시간을 늘리는 라벨일 뿐, 실제 지연은 프록시가 만든다).
- 2인 실행 (CLAUDE.md):
  ```
  godot --headless --path . -- --auto-host --auto-smoke --auto-only=D --auto-port=7901 --auto-quit=340
  godot --headless --path . -- --auto-join --auto-smoke --auto-only=D --auto-port=7901 --auto-quit=340
  ```
  호스트와 클라를 **동시에** 띄운다(호스트는 두 번째 플레이어를 최대 6초 기다린 뒤 `begin_smoke.rpc()`, `playground.gd:151-157`). 간격을 두면 `both_peers_present` 실패.
- 지연: `python tools/udp_delay_proxy.py --listen 7902 --target 7901 --delay 100 --jitter 10` (한 방향 100ms = 왕복 200ms), 클라는 프록시 포트로 접속.
- 파싱 검사: `godot --headless --path . --check-only --script <파일>` (오토로드 `Tuning/Net/ForceSystem/ServerAuthority` 미발견 오류는 정상). 새 `class_name`이 안 보이면 `godot --headless --path . --editor --quit`.

### 7.2 자동 검사 목록 (`playground.gd:_run_smoke` 165-275에서 분기)

| `--auto-only` | 파일 | 검사 수 (마지막 실행, 0ms 2인) | 다루는 것 |
| --- | --- | --- | --- |
| `B-a` | `scripts/tests/ba_checks.gd` | 31/0 | 결과 RPC 송신자 검증, 호스트 이탈 정리, 사망 덮어쓰기 금지 |
| `B-b` | `bb_checks.gd` | 27/0 | 의도 입구, 거부 |
| `B-c` | `bc_checks.gd` | 49/0 | 보유 표(E-5 예외 5개), 밀치기·잡기·던지기·탈출 서버 판정 |
| `B-d` | `bd_checks.gd` | 35/0 | 피해·HP·경직·사망·낙하·리스폰 서버 소유 |
| `B-e` | `be_checks.gd` | 25/0 | 이동 검사 경고, 재접속, 종료 |
| `C` | `c_checks.gd` | 64/0 | 점프·돌진·도약 한계·스태미나·스마트키 |
| `D` | `d_checks.gd` | 54/0 (200ms 54/0) | 힘 이벤트 형태, 직사각형 밀치기, 반동, **허용치·4×4표·각도·종족 배수 경로·위조 거부**, 아군 발사, 머리 발판, 5m 틈 |
| `E` | `e_checks.gd` | 110/0 (200ms 110/0) | 들기 한계(종족별), 한 키 던지기, 든 무게, 대상 ID, 허수아비 들기, 돌 vs 사람, 탈출, 예외, 들고 점프, 능력치 권한, **미끄러짐/튕겨나감 보유** |
| `F` | `f_checks.gd` | 34/0 | 면별 등반, 옆면 규칙, 닿는 높이 |
| `G` | `g_checks.gd` | 19/0 | 낙하·사망·아군 낙사 플래그·킬 플레인 |
| `audit` | `playground.gd:_run_audit` | 통과 쌍 0, 중력 전부 22.00 | 레이어 통과 쌍, 중력 일치 (호스트 단독) |
| `2`, `6`, `7`, `8` | `playground.gd:_run_stage*` | **집계 없음** (로그만) | v3 초기 스모크: 이동·점프·틈(2), 낙하 피해·리스폰(6), 돌 던지기·팀 던지기(7), 점프 게이트·등반·사람 던지기(8). 단계 8의 사람 던지기는 들고 던지지만 경계 위에 오르지 못한다(예측 정점 3.76/4.03 vs 필요 3.90) |
| (없음) | 전체 스모크 | — | 카메라 각도·복제 확인 뒤 위 단계를 순서대로 (분 단위) |

- 결과 읽기: 호스트 로그의 `<단계>_RESULT ... checks=N failures=M`, 항목별 `<단계>_CHECK PASS|FAIL <이름>`, 실측 `<단계>_NOTE`. 게임 로그는 `PLAYGROUND_*` 접두 (`PLAYGROUND_KNOCK`, `PLAYGROUND_FORCE`, `PLAYGROUND_MOVE_WARN`, `PLAYGROUND_HOLD_TAKEN/ENDED`, `PLAYGROUND_RESULT_REJECTED`, `PLAYGROUND_INTENT_REJECTED` 등).
- 하네스 전용 문: `ServerAuthority.harness_set_stats / harness_clear_stats / harness_set_race`(서버 로컬, `Net.auto_smoke`일 때만 동작, 아니면 경고+`PLAYGROUND_HARNESS_*_REFUSED`), `harness_forgive_move` RPC, `forgive_move`.
- 정책(CLAUDE.md): 작업 중엔 해당 단계만, 전체 회귀는 보고 직전 1회, 100/200ms는 네트워크·판정 코드를 바꿨을 때만, 독립 검사는 포트를 나눠 병렬.
- 알려진 하네스 취약점: `both_peers_present`는 두 프로세스의 시작 간격·CPU 부하·죽은 프록시 소켓에 민감하다(이번 세션에서 세 번 다 그 원인이었다).
