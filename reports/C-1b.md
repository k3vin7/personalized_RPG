# C-1b 보고 — 검 평타 4 (찌르기·횡베기·종베기·흘리기)

- 날짜: 2026-11-03
- 엔진: Godot 4.7.2.stable.official.ed1daf0bf (`C:/Users/kevin/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe`). 모든 검사 로그 첫 줄로 확인.
- 지시서: `docs/전투_뼈대_작업_지시서_v1.md` §4 C-1b
- `project.godot` diff: **비어 있음**
- 사전 변경(사용자 지시, C-1a 보고 뒤): 허수아비 HP 상수 60 → `Tuning.server.dummy_max_hp` 300. 직선 던지기의 `apply_hit`은 HP가 있는 대상(사람·허수아비)에만, 돌은 `send_force`만.

## 1. 만든 것 / 바꾼 파일

### 데이터
- `data/skills/thrust.tres`, `side_cut.tres`, `overhead_cut.tres`, `parry.tres` **(신규)** — 기술 표 4행. 숫자는 전부 `Tuning.server`의 `thrust_*`, `side_cut_*`, `overhead_cut_*`, `parry_*` 슬라이더(윈드업·후딜·쿨·사거리·폭·피해 계수·넉백·스태미나·각도). 범위 표시 모양은 C-0 데이터대로 직선(LINE)·수평 부채꼴(FAN)·좁은 직사각형(RECT)·없음(NONE). 검 막대 호·잔상 4개.
- `data/skills.gd` — 4개 경로 등록. `data/weapon_def.gd` — `skill_ids`(주손 4칸에 들어갈 기술). `data/weapons/sword.tres` — `["thrust","side_cut","overhead_cut","parry"]`. `data/weapons.gd` — `def_for_kind()`.
- `data/skill_def.gd` — 필드 3개 추가: `skip_airborne`(횡베기: 발이 땅에서 뗀 대상 제외), `vertical_angle_deg`(종베기: 수직 부채꼴, 0이면 기존 높이 띠), `speed_bonus`(찌르기). 슬라이더 접미사 `_angle`, `_vertical_angle`, `_speed_bonus`.
- `data/physics_tuning.gd` — 그룹 Sword 33개 슬라이더 + Skills 그룹에 `dummy_max_hp` 300.

### 서버 (`scripts/world/server_authority.gd`)
- `_rule_skill`: 무기 기술은 서버가 아는 손의 무기(`weapon_of`)와 WeaponDef의 kind가 맞아야 함(`no_weapon` 거부). 스태미나 0이면 거부(`no_stamina`). `"parry"`는 `_rule_parry`로. `speed_bonus > 0`이면 **의도 시점**에 `observed_h_speed()`(호스트 몸은 자기 velocity, 원격은 이동 감시 샘플 `h_speed`)로 `mult = 1 + bonus × v / base_move_speed`를 정해 예약에 실음.
- `_rule_strike`: FAN이면 반지름 reach·각도 검사, 아니면 기존 직사각형. `vertical_angle_deg > 0`이면 수직 부채꼴(대상 중심이 피벗에서 `tan(각/2) × 거리 + 대상 반높이` 안). `skip_airborne`이면 공중 대상 제외(플레이어: 복제된 AIRBORNE 상태, 허수아비: `is_on_floor()`). 대상이 플레이어이고 흘리기 창이 열려 있으면 `_parry_turns`로 넘기고 명중 없음. `ctx.mult`로 피해 배율. `last_strike`에 `parried`, `skipped_airborne`, `mult`.
- 흘리기: `_rule_parry`가 피어별 창(`parry_window` 0.25s)을 연다. `_parry_turns`: 창 안 + 공격자가 흘리기 부채꼴(reach 1.2 + 공격자 반지름, 90°) 안이면 성공. 공격자에게는 M-7 잡기와 같은 경로(`catch_stun` 힘 이벤트 → STUNNED, 새 상태 없음), 허수아비는 `apply_catch_stun`. 경직 길이 = **그 공격의 후딜**(강타 0.5, 찌르기 0.3). 성공 시 흘린 쪽의 `_skill_lock`을 풀고 `parry_result` RPC(호스트는 직접 호출)로 후딜을 즉시 끝냄. 창이 비면 `parries_failed`.
- `_rule_throw`: 돌에는 `apply_hit` 없이 `send_force`.

### 클라 (`scripts/player/player_skills.gd`)
- `fill_slots`: 한손 무기면 WeaponDef의 `skill_ids`가 1~4칸, 맨손 4가 5~8칸. 방패만/맨손은 기존대로.
- `press_slot`: 범위 표시가 없는 기술(흘리기)은 스마트키와 무관하게 누르는 순간 시전.
- `cast_slot`: 스태미나 0이면 무시(`no_stamina`), 아니면 `stamina_cost`를 자기 풀에서 차감(돌진 비용과 같은 방식). `stamina_spent` 카운터.
- `on_parry_result(true)`: 흘리기 후딜 중이면 `_finish()`.

### 기타
- `scripts/world/dummy.gd` — `max_hp()`. `scripts/ui/range_shapes.gd` — 부채꼴 각도를 `value()`로(슬라이더 반영). `scripts/debug/debug_panel.gd` — Sword 절, 한글 라벨. `scripts/world/playground.gd` — `--auto-only=C1b`.
- `scripts/tests/c1b_checks.gd` **(신규)** 40항목, 2피어.

## 2. 검사 결과 (4.7.2, 2피어, 지연 0)

| 검사 | 호스트 | 클라 |
|---|---|---|
| C1b | 40 / 0 | 0 / 0 (host_failures=0) |
| 회귀 | (아래 표) | |

| 회귀 검사 | 호스트 | 클라 | 비고 |
|---|---|---|---|
| E | 111 / 0 | 4 / 0 | |
| M | 103 / 0 | 0 / 0 | 1차 1 실패 → M-1 슬롯 기대값을 C-1b 배치로 갱신 후 재실행 통과 |
| M7 | 30 / 0 | 0 / 0 | |
| N | 60 / 0 | 0 / 0 | |
| C (H-3 포함) | 100 / 0 | 4 / 0 | |
| C0 | 47 / 0 | 0 / 0 | 1차 1 실패(클라 하네스 순간이동 79 m/s가 용서 RPC보다 먼저 샘플됨, `no_move_warnings`) → 재실행 통과. C-1b 코드와 무관한 레이스 |
| C1a | 39 / 0 | 0 / 0 | |
| DK | 26 / 0 | 23 / 0 | |
| DT / RD | 27 / 0, 38 / 0 | 호스트 전용 | |
| TH | 13 / 0 | 9 / 0 | |

audit: PASSTHROUGH 0줄, 중력 22 일치. 다른 객체 velocity 직접 쓰기 0건. HP 쓰기는 `apply_hit`→`server_damage`·`Dummy.take_damage` 외 스폰·리셋 채우기뿐.

### C1b 실측 (호스트 로그, run d)
- 표 로드: 찌르기 0.15/0.30/0/2.2/계수1.0/넉백3/스태8, 횡베기 0.20/0.35/0/1.8/1.2/4/10, 종베기 0.25/0.40/0/1.8/1.4/3/10, 흘리기 0/0.4/1.0/1.2/0/0/6. 모양: LINE 폭 0.5 / FAN 120° / RECT 폭 0.4·수직 40° / NONE 90° 창 0.25.
- 슬롯: 맨손 [shove, grab, punch, kick, -, -, -, -]. 검 [thrust, side_cut, overhead_cut, parry, shove, grab, punch, kick]. 검 없이 보낸 찌르기 의도는 서버 거부.
- 사거리: 찌르기 2.4m 명중 10.0 / 3.3m 빗나감. 횡베기 1.5m 명중 12.0 / 2.6m 빗나감 / 1.5m에서 80° 벗어난 대상 빗나감. 종베기 1.5m 명중 14.0 / 2.6m 빗나감.
- 공중: 허수아비를 9 m/s로 띄워(임팩트 시점 공중, 최고 y 2.78) 횡베기 → 명중 0, `skipped_airborne=1`. 같은 조건 종베기 → 명중 1, 피해 14(피벗 위 1.11m).
- 찌르기 속도 보정: 정지 mult 1.000 피해 10.00. 의도 틱에 6.0 m/s → mult 1.300 피해 13.00 (식 1 + 0.3 × 6/6 = 1.3). 실제로 걸어가며(6.00 m/s) 눌러도 mult 1.300, 피해 13.00.
- 흘리기 vs 허수아비 강타(선딜 0.8, 후딜 0.5): 임팩트 0.119s 전에 누름 → 성공, HP 손실 0, 허수아비 `stunned` 0.50s, 흘린 쪽 후딜 0.129s에 종료. 0.590s 전에 누름 → 창 만료(실패), 강타 명중 HP −10, 후딜 0.400s, 허수아비 경직 0.
- 스태미나: 찌르기 시전에 101.50 → 93.92(8 − 틱 동안 회복). 0에서 누르면 무시(`no_stamina`), 의도를 강제로 보내면 서버 거부.
- 2피어: 클라가 검을 집고(서버 승인·클라 보고 둘 다 확인) 호스트를 찌름 → 서버 판정, 호스트 HP 105 → 95, 호스트 화면에서 클라의 `strike` 단계·휘두르기 표시. 클라 스태미나 8 소모 보고. 호스트의 찌르기를 클라가 임팩트 0.118s 전에 흘림 → 성공, 클라 HP 변화 0, 호스트 STUNNED 0.29s(찌르기 후딜 0.3).

## 3. 테스트 방법

```
G="C:/Users/kevin/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe"
"$G" --headless --path . -- --auto-host --auto-smoke --auto-only=C1b --auto-port=7964 --auto-quit=300
"$G" --headless --path . -- --auto-join --auto-smoke --auto-only=C1b --auto-port=7964 --auto-quit=300
```
호스트 먼저, 4초 뒤 클라. 회귀는 포트 둘(7971/7972)로 두 레인 순차.

## 4. 멈추고 물은 것

없음. 표에 없어서 가정한 값(전부 슬라이더):
- **종베기 칼날 폭 0.4** (`overhead_cut_width`): 표의 '폭'은 수직 40°라서 좌우 폭이 없다. 좁은 직사각형 표시와 좌우 허용(폭/2 + 대상 반지름)에 쓴다.
- **흘리기 사거리 1.2는 공격자 중심까지 거리 ≤ 1.2 + 공격자 반지름**으로 읽었다. 찌르기(2.2)보다 짧아서 2m 밖에서 찌르는 상대는 흘릴 수 없다(실측: 1.85m에서 `PARRY_MISSED`). 의도한 것인지 확인 필요.
- 스태미나 0 기준: "0이면 거부"를 문자 그대로. 0보다 크면 비용이 풀을 넘어도 시전되고 0으로 깎인다.
- 흘리기 `stun_on_hit` 필드는 0으로 두었다. 경직 길이가 상대 공격의 후딜이라 고정값 필드로 표현되지 않는다.

## 5. 지시서·기술 표와 다르게 한 것

- **스태미나 소유**: 지시서는 스태미나도 서버 소유라고 하지만 기존 구조(H-3·N-2)에서 스태미나는 소유자가 쓰고(`sync_stamina`), 돌진 비용도 소유자가 깎는다. 이번에도 같은 방식: 소유자가 깎고 서버는 복제값으로 0 거부만 한다. 서버 소유로 바꾸려면 회복·돌진·들기 비용을 전부 서버로 옮기는 별도 작업이다. 결정 필요(7절).
- **맨손 4의 스태미나도 지금부터 빠진다.** `cast_slot`이 모든 PRESS_CAST 기술의 `stamina_cost`를 깎는다(밀치기 6·주먹 3·발차기 7). C-1d 항목이 먼저 들어간 셈이고, C-1d에서는 검사만 하면 된다. 잡기(HOLD_RELEASE)의 "들기 중 초당 2"는 아직 없음(C-1d).
- **흘리기 경직 시작 시점**: 서버는 공격 판정 순간 공격자에게 후딜 길이만큼 경직을 보낸다. 공격자 클라에서는 후딜이 이미 시작된 뒤 경직이 도착하므로 실제 멈춤은 원래 후딜 끝보다 한 왕복 정도 길다.
- **흘리기 성공 피드백 없음**: 로그·경직·후딜 종료만. 화면 표시는 손맛 때.
- 공중 판정의 "발이 땅에서 뗀 대상": 플레이어는 복제된 AIRBORNE 상태(지연만큼 늦음), 허수아비는 `is_on_floor()`.

## 6. 알려진 문제 · 하네스에서 배운 것

- 허수아비가 밀린 뒤 귀환하는 2초 사이에 다음 측정을 하면 빗나간다(run a: 횡베기 1.5m 명중 0, 찌르기 피해 0). 검사는 `_wait_dummy_home`으로 귀환·착지를 기다린다. 귀환 뒤에도 마크에서 0.49m 떨어져 서는 일이 있다(RETURN 루프가 0.2m 안에서 멈추지만 호스트 몸과 겹쳐 밀림 추정, 미조사).
- 허수아비 강타는 공격 방향(−Z)으로 8 넉백을 준다. 결투장 북쪽에서 흘리기를 검사하면 실패 사례에서 흘린 쪽이 북쪽 절벽으로 날아가 낙사했다(run c: `DIED cause=kill_plane`). 검사는 허수아비를 +Z로 돌려 놓고 한다.
- `dummy_attack_enabled`를 끄면 허수아비의 `stunned` 단계도 즉시 지워진다. 경직 길이를 재는 동안엔 끄지 말고 주기를 늘려야 한다.
- 클라의 무기 적용은 호스트 복제본보다 한 패킷 늦다. 호스트가 자기 복제본만 보고 바로 시전을 시키면 클라는 아직 맨손이라 밀치기가 나간다(run a: `spent 6`). 클라의 보고를 기다린다.
- 지연 100/200ms에서는 흘리기 창(0.25s)이 왕복 지연과 겹친다. 2피어 검사는 임팩트 0.2s 전에 명령을 보내 0ms에서 통과하지만, 지연 프록시에서는 "지연으로 빗나감" 분기를 허용한다. 지연 검사는 네트워크 코드를 바꾼 게 아니라 이번엔 돌리지 않았다.

## 7. 다음 단계(C-1c) 전에 결정이 필요한 것

- 스태미나를 서버 소유로 옮길지(5절). 옮긴다면 C-1c 전에 별도 소단계로.
- 흘리기 사거리 1.2가 찌르기 2.2보다 짧은 것(4절).
- 방패 던지기(C-1c)는 "돌과 같은 물체"로 날리므로 `_rule_throw`의 "HP 있는 대상만 `apply_hit`" 규칙이 방패에도 그대로 적용된다. 방패가 맞힌 상대는 `Rock._on_body_entered`와 같은 경로로 `apply_hit`를 타야 하므로 방패 물체 스크립트를 돌에서 파생할지 결정.
