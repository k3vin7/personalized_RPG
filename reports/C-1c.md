# C-1c 보고 — 방패 4 (들기·밀기·던지기·찍기)

- 날짜: 2026-11-03
- 엔진: Godot 4.7.2.stable.official.ed1daf0bf (`C:/Users/kevin/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe`). 모든 검사 로그 첫 줄로 확인.
- 지시서: `docs/전투_뼈대_작업_지시서_v1.md` §4 C-1c. 기획서 v0.6 287행(자세 완성도), 306~313행(방패 절).
- `project.godot` diff: **비어 있음**
- 앞선 사용자 지시 반영: 스태미나 서버 소유([C-1b'] ee63b27), 흘리기 거리 조건 제거(같은 커밋), 방패 던지기 물체는 `Rock`에서 파생.

## 1. 만든 것 / 바꾼 파일

### 양손 모델
- `scripts/player/player.gd`, `scenes/player.tscn`: `sync_offhand`(Vitals, 서버 소유)와 `offhand`, 왼손 메시 `_apply_offhand`, 올린 자세 `show_block`. `sync_blocking`(자세 동기화, 소유자)으로 다른 화면에 올린 방패를 보여줌.
- `scripts/world/server_authority.gd` `_rule_weapon`: 방패는 보조 손, NONE은 양손 비움, 나머지는 주손. `offhand_of`, `holds_weapon(peer, WeaponDef)`(손 요구에 따라 주손/보조 손 검사).
- `scripts/player/player_skills.gd` `fill_slots`: 주손 무기 4 / 맨손 4 + 보조 손 방패 4 / 맨손 4 / 빈 4. 검+방패 = 검 4 + 방패 4, 방패만 = 맨손 4 + 방패 4, 검만 = 검 4 + 맨손 4.

### 데이터
- `data/skills/shield_raise.tres`, `shield_bash.tres`, `shield_throw.tres`, `shield_slam.tres` **(신규)**. `data/weapons/shield.tres` `skill_ids`. `data/skills.gd` 등록.
- `data/skill_def.gd`: `InputMode.HOLD_BLOCK`(누르는 동안 유지), `Outcome.THROW_WEAPON`(판정이 타격이 아니라 보조 무기 던지기), `height_bonus`, `usable_airborne`, `launches_airborne_ally`, `circle_radius_value()`(슬라이더 `_radius`).
- `data/physics_tuning.gd` 그룹 Shield 33개: 들기 `shield_raise_time` 0.2 / `shield_posture_time` 0.6 / `shield_raise_recovery` 0.1 / `shield_raise_angle` 180 / `block_stamina_mult` 0.5 / `block_tolerance_mult` 1.0(임시) / `block_recover_fraction` 0.25(임시), 밀기·던지기·찍기의 표 열, `shield_weight` 5(임시), `shield_slam_height_bonus` 0.2.

### 들기(막기) — 서버 창
- `Intent.BLOCK {on}`: 올림 요청. `_rule_block`은 서 있고·보조 손에 방패·잠금 아님일 때만 연다. `block_posture(peer)`: 누른 뒤 0.2초까지는 안 올라옴(−1), 0.2→0.6초에 0→100%.
- `apply_hit`: 대상이 플레이어이고 `_block_guards`(방패 올라옴 + 공격자가 몸의 전방 180° 안)이면 HP 0, `_block_absorbs`가 (방어력 뒤 피해)×0.5를 스태미나에서 깎음. 스태미나가 0이 되면 그 자리에서 창을 닫고 `_block_lockout`에 넣고 `block_result(false)`로 소유자 방패를 내림. 잠금은 스태미나가 최대의 25% 이상이 되면 `_tick_blocks`가 푼다.
- 밀림: 힘 이벤트는 그대로 나가고(`blocked`, `block_posture` 표시) `_rule_knockback`이 허용치에 (1 + 자세 × `block_tolerance_mult`)를 곱해 `ForceSystem.judge_knockback`(새 인자 `tolerance_mult`)에 넘긴다. 기획서 287행: 0%는 맞은 것과 같은 밀림, 100%는 더 버팀. `ForceSystem.tolerance_for`에 H 단계가 남긴 "막기 보정 자리"가 바로 이것.
- 소유자: `_block_press`(바쁘거나 공중이거나 후딜 0.1 중이거나 스태미나 0이면 무시) → BLOCK on → 올린 포즈. 키를 떼거나 다른 기술을 누르거나 공중에 뜨거나 죽으면 `end_block`. 서버가 거부하면(`intent_refused`/`_refuse`) 내린다.

### 밀기
- 타격 def(RECT 1.5×1.4, 계수 0.5, 넉백 9) → `_rule_strike` → `apply_hit` → `send_force`. 놀이터 밀치기와 같은 힘 문. `launches_airborne_ally`면 공중 파티원을 밀치기와 같은 각도·스프링으로 띄움(`_rule_strike` 안, 밀치기 코드와 같은 식). 돌진 조합은 C-1d.

### 던지기
- `scripts/world/shield.gd` **(신규)** `class_name Shield extends Rock`: 다른 점은 메시(판자)·무게(`shield_weight`)·명중 정의(`_hit_def` = shield_throw, `_hit_power` = 표 넉백 6)뿐. `rock.gd`는 `_build_visual`, `_hit_def/_hit_power/_hit_damage` 훅으로 정리.
- `_rule_weapon_throw`(예약 판정이 `THROW_WEAPON`이면): 보조 손 비움, `Shield_n`을 손 위치에 스폰하고 `spawn_shield` RPC로 모든 피어에 같은 이름으로 생성(코드 노드는 복제 안 됨, CLAUDE.md 1). 속도 = 사거리 / sqrt(2·손높이/중력)(수평 던지기가 사거리에서 땅에 닿는 속도; 손 2.6m, 중력 22 → 16.46 m/s). 힘 이벤트 THROW로 발사(돌이라 `apply_hit` 없음). 이후 위치는 `Rock.push_state`.
- 줍기: 잡기 키로 `Shield`를 가리키면 `_rule_grab` → `_pick_up_shield`: 보조 손이 비어 있고 `can_grab`이면 보조 손 = 방패, `despawn_shield` RPC로 물체 제거. 보조 손이 차 있으면 돌처럼 든다.

### 찍기
- CIRCLE: 앞 1.3m 중심 반지름 1.0 원(`_rule_strike`에 CIRCLE 분기). 공중 시전: `usable_airborne` → 소유자는 AIRBORNE 상태를 유지한 채 의도만 보내고(`PLAYGROUND_AIR_CAST`) 윈드업 끝에 휘두르기 표시, 서버는 `_rule_skill`에서 공중 허용. 높이 보정: 판정 시 서버의 낙하 감시 `peak − y`로 `mult *= 1 + 0.2 × 낙하 m`(`PLAYGROUND_HEIGHT_BONUS`).

### 기타
- `scripts/tests/c1c_checks.gd` **(신규)** 42항목, 2피어. `scripts/tests/m_checks.gd` 방패만 든 슬롯 기대값을 C-1c 배치로. `scripts/tests/c1b_checks.gd` 귀환 대기에 HP 리필 대기 추가.
- `scripts/world/playground.gd` `--auto-only=C1c`. `scripts/debug/debug_panel.gd` Shield 절·라벨. `scripts/ui/range_shapes.gd` 원 반지름 슬라이더 반영.

## 2. 검사 결과 (4.7.2, 2피어, 지연 0)

| 검사 | 호스트 | 클라 |
|---|---|---|
| C1c | 42 / 0 | 0 / 0 (host_failures=0) |

| 회귀 검사 | 호스트 | 클라 | 비고 |
|---|---|---|---|
| C1b | 40 / 0 | 0 / 0 | |
| C1a | 39 / 0 | 0 / 0 | |
| C0 | 47 / 0 | 0 / 0 | 두 레인 동시 실행에서 1차 1 실패(`no_move_warnings`: 클라 하네스 순간이동 79 m/s가 용서 RPC보다 먼저 샘플) → 단독 재실행 통과 |
| C (H-3 포함) | 100 / 0 | 4 / 0 | |
| E | 111 / 0 | 4 / 0 | |
| F | 35 / 0 | 1 / 0 | 480초 |
| M | 103 / 0 | 0 / 0 | 1차 1 실패: M-1 "방패만" 검사가 검을 든 채 방패를 집어 검+방패가 됨 → 손 비우고 집도록 검사 수정, 재실행 통과 |
| M7 | 30 / 0 | 0 / 0 | |
| N | 60 / 0 | 0 / 0 | |
| D | 55 / 0 | 0 / 0 | 1차 1 실패(C0과 같은 클라 순간이동 레이스, 21.9 m/s) → 단독 재실행 통과 |
| DK | 26 / 0 | 23 / 0 | |
| DT / RD | 27 / 0, 38 / 0 | 호스트 전용 | |
| TH | 13 / 0 | 9 / 0 | |

클라 순간이동 레이스(C0·D): 하네스의 `client_park`가 `harness_forgive_move` RPC와 위치 쓰기를 같은 틱에 보내는데, 두 레인을 동시에 돌려 부하가 걸리면 호스트의 0.1초 이동 샘플이 용서보다 먼저 닫힌다. 게임 코드 문제가 아니라 하네스 순서 문제이며, 이번 단계 변경과 무관(C-1a 이후 네 번 중 두 번 나타남). 고치려면 클라 하네스가 용서 RPC 뒤 한 틱 기다렸다가 위치를 써야 한다 — 다음 하네스 손질 때.

audit: PASSTHROUGH 0줄, 중력 22 = 돌 6개. 다른 객체 velocity 직접 쓰기 0건. HP·스태미나 쓰기는 `server_set_hp/stamina`·`Dummy.take_damage` 외에 스폰·리셋 채우기와 옛 호스트 전용 단계 4 스모크(`playground.gd` 666행 `stamina = 8`)뿐.

### C1c 실측 (호스트 로그, run c)
- 표 로드: 밀기 0.15/0.40/1.0/1.5/계수0.5/넉백9/스태12, 던지기 0.30/0.50/0/8/0.8/6/10, 찍기 0.30/0.50/1.5/1.3/1.5/5/14, 들기 0/0.1/0. 모양 NONE/RECT 1.4/LINE/CIRCLE 1.0, 찍기 공중 가능.
- 슬롯: 맨손 [shove grab punch kick - - - -], 방패만 [맨손 4, raise bash throw slam], 검+방패 [thrust side_cut overhead_cut parry, raise bash throw slam]. NONE이면 양손 비움.
- 자세: 누른 뒤 0.1초 −1(안 올라옴), 0.3초 0.31, 0.7초 1.00. 소유자·서버 양쪽에 창이 서고 떼면 양쪽에서 닫힘.
- 강타(검사 중 힘 10으로) vs 막기: 안 막음 → HP −10, 튕김, 4.40 m 밀림. 100% → HP 0, 스태미나 −5.0(10×0.5), 허용치 7.2→14.4라 미끄러짐, 2.30 m. 0.23초 전 올림(자세 2.75%) → HP 0, 스태미나 −5, 허용치 7.56 < 9.70이라 튕김, 4.40 m(안 막은 것과 같음). 뒤에서 맞으면 안 막힘(HP −10).
- 스태미나 3으로 막고 강타(힘 8) → 스태미나 3→0, 창 깨짐(`broken 1`), 소유자 방패 내려감, 서버 잠금. 0에서 다시 올리면 서버 거부 → 안 올라감. 회복 25/s로 1.03초 뒤 34.0(≥25.4) → 잠금 풀림, 올라감.
- 밀기 1.2 m: 피해 3.0(0.5×6), 허수아비 8.72 m 밀림(힘 문 경유).
- 던지기: `Shield_1` 스폰 속도 16.46 m/s(손 y 2.6), 5.5 m 앞 허수아비 명중 피해 4.8(0.8×6), 보조 손 맨손·5~8칸 맨손 4로. 클라도 `Shield_1`을 봄. 잡기 키로 줍기 → 보조 손 방패, 노드 제거(클라도), 5~8칸 방패 4로.
- 찍기: 지상 9.0(1.5×6, mult 1.0). 2.2 m 위에서 떨어지며 시전(AIRBORNE에서 의도 송신) → mult 1.271(낙하 1.35 m), 피해 11.44 = 9 × 1.271.
- 2피어: 클라가 방패를 들고(서버 승인·클라 보고) 막는 동안 호스트 찌르기 → 클라 HP 0 손실, `blocked` 자세 1.0, 서버가 클라 스태미나 5.0 차감. 클라가 방패를 던져 호스트 명중 → 호스트 HP 105→100.2(4.8), 호스트 화면에 `Shield_2` 존재.

## 3. 테스트 방법

```
G="C:/Users/kevin/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe"
"$G" --headless --path . -- --auto-host --auto-smoke --auto-only=C1c --auto-port=7993 --auto-quit=360
"$G" --headless --path . -- --auto-join --auto-smoke --auto-only=C1c --auto-port=7993 --auto-quit=360
```
회귀는 포트 둘로 두 레인 순차(8001: C1c·C1b·E·M·F·DK, 8002: N·C·M7·C0·C1a·D·DT·RD·TH). F는 480초.

## 4. 멈추고 물은 것

없음. 표·기획서에 없어서 임시 슬라이더로 둔 값:
- **`block_tolerance_mult` 1.0**: 자세 100%가 허용치를 두 배로. 기획서는 "늦게 잡을수록 더 밀린다"만 말하고 계수는 없다. 손맛 때 정할 값.
- **`block_recover_fraction` 0.25**: "회복 전까지 못 든다"의 '회복'을 최대의 25%로 읽음.
- **`shield_weight` 5 kg**: 던진 방패의 물체 무게(들기 한계·돌 규칙에 쓰임).
- 들기 중 이동은 막지 않았다(기획서·지시서에 제한 없음). 다른 기술 키를 누르면 방패가 먼저 내려간다.
- 공중 시전은 찍기만. 공중에서는 소유자 상태를 CASTING으로 바꾸지 않고(중력 처리가 상태별이라) 의도만 보낸다. 후딜 잠금은 착지가 대신한다.

## 5. 지시서·기술 표와 다르게 한 것

- 던지기 속도는 표의 사거리 8에서 유도(손 높이·중력). 표에 속도는 없다.
- 밀기의 공중 아군 띄우기는 `_rule_shove`를 그대로 부르지 않고 `_rule_strike` 안에서 같은 식(각도·스프링)을 쓴다. 밀치기는 자기 사거리·쿨·반동 슬라이더에 묶여 있어 함수 재사용이 어려웠다. 힘 문(`apply_hit`→`send_force`)은 같다.
- 막기 성공 화면 피드백 없음(로그·자세·스태미나만).
- 기획서의 "방패 들어올리면 아군 발판" "방패 강화 지면강타"는 지시서 C-1c 범위 밖이라 하지 않았다.

## 6. 알려진 문제 · 하네스에서 배운 것

- **허수아비 마크 리필 레이스**: 허수아비는 귀환 뒤 2초가 지나면 HP를 최대로 채운다. 위치만 보고 다음 측정을 시작하면 피해 − 리필이 읽힌다(실측: 찍기 9가 4.2로). 검사는 서버 판정값(`last_hit.dealt`)을 읽고 HP 차이는 메모로만 남긴다.
- 허수아비가 마크에서 0.2~0.5 m 떨어져 서는 일이 있다(귀환 루프는 0.2 m 안에서 멈추고 리필도 그 안에서만). 원인 미조사. 하네스는 0.3 m·3.5초 상한으로 기다린다.
- 강타 힘 8의 밀림(7.76)이 인간 허용치(7.2)와 너무 가까워 자세 8%로도 버틴다. 0%/100% 차이를 재려고 검사는 힘 10으로 올려 잰다. 실제 손맛에서는 `block_tolerance_mult`와 같이 볼 값.
- 던진 방패를 피어가 늦게 접속하면 못 본다(스폰 RPC는 접속 중인 피어에게만). 늦은 접속 처리는 아직 없다(돌도 같은 상황).
- 지연 100/200ms 검사는 안 돌렸다(네트워크 코드 변경 없음). 막기 창은 서버 시계라 지연이 커도 "올린 뒤 0.2초"는 서버 기준이다.

## 7. 다음 단계(C-1d) 전에 결정이 필요한 것

- `block_tolerance_mult`, `block_recover_fraction`, `shield_weight` 임시값(4절).
- 돌진 조합(C-1d) 창 0.15초를 "돌진 알림 수신 시각" 기준으로 잴지, 소유자가 보낸 간격 값을 믿을지. 지시서는 "창은 내 클라 입력 간격, 서버는 그 간격만 검사"라 소유자가 간격을 보내는 쪽이다.
- 맨손 4 스태미나는 이미 서버에서 빠지고 있다(C-1b'). C-1d에서는 검사만 하면 된다.
