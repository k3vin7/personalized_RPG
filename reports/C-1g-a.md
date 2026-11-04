# C-1g-a 보고 — 쓸고 가는 판정 (횡베기 240° · 종베기 수직 120°)

2026-11-04. 지시서 `docs/C-1g_작업지시서.md` 소단계 a. 전제: C-1 + f-2(9ef2755) + 시전 스텝(1c1b6fc).
조작·선후딜·체인·기술 종류·피해 계수·스태미나는 건드리지 않았다.

## 1. 바꾼 파일·함수

- `data/skill_def.gd` — `arc_sweep_deg` 삭제 → `arc_deg`(호 크기, `value()`로 서버 슬라이더 참조, `TUNING_SUFFIX` "arc_deg") + `arc_reversed`(방향) + `arc_centred`(조준 중심 대칭) + `judge_by_sweep`(쓸기 판정 여부). `vertical_angle_deg` 삭제. 새 함수 `arc_degrees()` `arc_start()` `arc_end()` `arc_sign()` `is_thrust_motion()` `swing_eased(p)`(정적) `swing_angle_deg(p)` — 연출과 판정이 같은 식으로 같은 시각에 같은 각을 읽는다.
- `data/physics_tuning.gd` (Sword 묶음) — `side_cut_arc_deg` 240, `overhead_cut_arc_deg` 120, `swing_arc_margin_deg` 20 추가. `overhead_cut_vertical_angle`(40) 삭제. `side_cut_angle`(120)은 바닥 범위 표시용으로 남김(§4).
- `data/skills/*.tres` 13개 — `arc_sweep_deg` → `arc_deg`/`arc_reversed` 이관(발차기 70, 방패 찍기 110↓, 허수아비 내려치기 100↓, 흘리기 30; 나머지 0). `side_cut.tres`: `arc_start_deg` 삭제, `arc_reversed` `arc_centred` `judge_by_sweep` = true(호 값은 서버). `overhead_cut.tres`: `vertical_angle_deg` 삭제, `arc_reversed` `judge_by_sweep` = true, `arc_start_deg` 90 유지(호 값은 서버).
- `scripts/world/server_authority.gd` — `_run_pending_strikes`: `judge_by_sweep`이면 `_rule_strike` 대신 `_begin_sweep`. 새 `_active_sweeps` `_run_sweeps`(매 물리 틱) `_sweep_tick` `sweep_in_progress` `last_sweep` `sweeps_started/cancelled`. `_rule_strike`의 대상별 꼬리(들린 돌·공중 제외·흘리기·아군 띄우기·넉다운 요청·`apply_hit`)를 `_land_strike`로, 집계·`last_strike`·`PLAYGROUND_SKILL` 출력을 `_finish_strike`로 뽑아 즉시 판정과 쓸기 판정이 공유. C-1b 수직 부채꼴 분기 삭제.
- `scripts/player/player.gd` — `_pose_swing`: `def.swing_angle_deg(p)` / `def.is_thrust_motion()` 사용(각 식 자체는 SkillDef로 이동).
- `scripts/player/character_visual.gd` — `_attack_clip_for`: 찌르기 판별을 `is_thrust_motion()`으로.
- `scripts/debug/debug_panel.gd` — 기술 연출 슬라이더: `arc_sweep_deg` → `arc_deg`(0~360), 서버 행이 있는 검 기술은 로컬 `arc_deg` 슬라이더를 만들지 않음(서버 튜닝 > 검 4기술 묶음에만), 대칭 호인 기술은 `arc_start_deg` 슬라이더 생략. 한글 라벨 3개 추가, 1개 삭제.
- `scripts/world/dummy.gd` — 하네스 훅 `harness_pin(at, seconds)`(호스트 전용: 중력·귀환 없이 공중 고정). 머리 위 허수아비 검사용.
- `scripts/tests/c1g_checks.gd` (신규, `--auto-only=C1g`, `--shot=<dir>`로 창 모드 스크린샷) + `scripts/world/playground.gd` 디스패치.
- `scripts/tests/c1b_checks.gd` — 80° 허수아비 검사: "120° 부채꼴 밖" → "240° 쓸기에 맞는다". 종베기 수직 40° 기대 → 호 120°. 종베기 모션 데이터 검사는 `arc_start()/arc_end()`로.
- `scripts/tests/c0_checks.gd` — 스키마 검사가 `arc_start()/arc_degrees()`를 읽음.

### 판정 방식
- 임팩트 시각(선딜 끝, 기존 즉시 판정과 같은 시점)에 쓸기가 시작된다. 서버 시계로 진행도 p = 경과/`arc_duration`, 날 각 = `arc_start() + sign × arc × swing_eased(p)`(연출과 동일 식). 매 틱 "시작 각 ~ 현재 각" 구간을 누적하고, 구간에 처음 들어온 몸을 그 틱에 `_land_strike`. 한 휘두름에 같은 몸은 1회(`hit` 집합).
- 중심은 **임팩트 순간 몸이 선 자리**(`origin`). 시전 스텝이 휘두르는 동안 몸을 더 밀어도 각은 origin 기준이다(즉시 판정이 임팩트 위치를 읽는 관례와 같음. "날이 지나간 각 구간을 누적"은 고정 중심을 전제한다).
- 수평(횡베기): 몸 중심의 방위각(좌 +)이 구간 안, 거리 ≤ reach + 반지름, 높이 띠는 기존 `strike_band`("낮게" 그대로). C-1b 부채꼴과 같이 **중심각**으로 본다(반지름 보정 없음 — 130°에 선 몸은 반지름을 더하면 115°가 되어 "안 맞아야" 하는 검사와 어긋난다).
- 수직(종베기): 전방 거리 ≤ reach, 좌우 ≤ width/2 + 반지름(폭 0.4 그대로), 몸의 피치 구간 [atan2(dy−반높이, 전방), atan2(dy+반높이, 전방)]이 쓴 피치 구간과 겹치면 명중(C-1b 수직 부채꼴이 반높이를 더하던 관례 유지).
- 캐스터가 쓸기 중 기절·넉다운·잡힘·사망이면 남은 쓸기 취소(`PLAYGROUND_SWEEP_CANCELLED`).
- 잡기(M-7 catch)는 임팩트까지만이라 변화 없음. 찌르기·흘리기·맨손 4개·방패 4개·허수아비 내려치기는 `judge_by_sweep` false → 기존 즉시 판정 그대로.

## 2. 슬라이더와 기본값

| 슬라이더 | 위치 | 기본 | 범위 | 읽는 곳 |
|---|---|---|---|---|
| `side_cut_arc_deg` 횡베기 호(좌우 합) | 서버 튜닝 > 검 4기술 | 240 | 0~360 | 판정(쓸기), 연출 피벗, 궤적 잔상, 클립 선택 |
| `overhead_cut_arc_deg` 종베기 수직 호 | 서버 튜닝 > 검 4기술 | 120 | 0~360 | 같음 |
| `swing_arc_margin_deg` 판정−애니 허용 여유 | 서버 튜닝 > 검 4기술 | 20 | 0~80 | 검사(C1g·b에서 실측 비교). 아무것도 클램프하지 않음 |
| `side_cut_angle` 횡베기 부채꼴(바닥 표시) | 서버 튜닝 > 검 4기술 | 120 | 0~480 | `RangeShapes` FAN(스마트키 꺼짐 표시)만. **c에서 `arc_deg`로 통합 예정** |
| `<기술>.arc_deg` | 기술 연출(이 컴퓨터) | 각 tres 값 | 0~360 | 서버 행이 없는 기술(발차기·방패 찍기·흘리기·허수아비)만 |
| `<기술>.arc_start_deg` | 기술 연출(이 컴퓨터) | tres 값 | −180~180 | 대칭(`arc_centred`) 기술은 숨김 |

종베기 시작각 90°(머리 위)는 `overhead_cut.tres`의 `arc_start_deg`(데이터, 로컬 슬라이더 있음). 서버 슬라이더는 아님 — 지시서가 "머리 위에서 시작"을 고정으로 적어 호 크기만 서버 값으로 뺐다.

## 3. 검사 결과 — C1g 호스트 20 / 0, 클라 0 / 0 (4.7.2, 2피어, 0 ms; 4차 실행, 결정 반영 뒤 헤드리스·창 모드 각 1회 더 20 / 0)

캐스터 (54, 0.9, 7)에서 북(−Z) 조준. 시전 스텝으로 임팩트까지 0.26 m(횡) / 0.22 m(종) 전진하므로 마크는 그 지점(origin) 기준.

| 검사 | 결과 | 실측 |
|---|---|---|
| 데이터 한 곳 | PASS | 횡 240(=`side_cut_arc_deg`) 120→−120 대칭·역방향·쓸기·수평 0.18 s. 종 120(=`overhead_cut_arc_deg`) 90→−30 폭 0.4 쓸기·수직 0.20 s. 찌르기 호 0·흘리기 30, 둘 다 쓸기 아님 |
| 여유 규칙 | PASS | margin 20. 판정 호 240/120 = 피벗이 그리는 호 240/120 (차 0). **모델 클립이 실제 그리는 각은 b에서 실측** |
| 완화 식 공유 | PASS | `swing_eased(0.5)` = 0.75 |
| 횡베기 정면·좌 110°·우 110° (1.5 m) | PASS | hits 3, 각 12.0 피해 1회씩. 도달 순서 좌(110.4°) 12 ms → 정면 53 ms → 우(−110.4°) 144 ms — 즉시 부채꼴이면 같은 틱 |
| 횡베기 좌 130°·우 130° | PASS | hits 0, hit id 변화 없음 |
| 슬라이더 240→180 | PASS | 같은 배치에서 hits 1(정면만). 복원 후 def 240 |
| 종베기 정면 1.2 m·머리 위(중심 +2.0 m, 1.0 m 앞)·좌 45° | PASS | hits 2(위 → 정면, 26 ms → 82 ms), 피해 14.0. 위 허수아비 피치 구간 27°~67°. 참고: C-1b 40° 부채꼴은 그 거리에서 1.26 m까지만 닿아 못 맞췄을 것 |
| 종베기 우 45° | PASS | hits 2(정면·위), 우측 안 맞음 |
| 클라의 횡베기 (클라 (48,0.9,7), 호스트가 판정) | PASS | hits 3, 셋 다 hit id 증가. 복제본 위치가 조금 뒤여서 방위 105.3° |
| 이동 경고 / 보정 | PASS | 0 / 0 |

스크린샷 (`reports/C-1g-a/`, 창 모드 호스트 `--shot=`, 휘두르는 도중 저장):
- `a_side_cut_front_110_110.png` — 스윙 70 % 시점. 좌(110°)·정면에 12 피해가 떠 있고 우(−110°, 노란 종족 허수아비)는 아직 날이 닿기 전. 즉시 부채꼴이면 셋이 같은 프레임에 뜬다.
- `a_side_cut_130_130_missed.png` — 좌우 130°, 스윙 90 % 시점. 피해 숫자 없음.
- `a_overhead_front_above_45left.png` — 정면과 머리 위(핀 고정, 중심 +2.0 m)에 14, 좌 45°(노란)는 그대로.

### 판정 불변 회귀 (바뀐 코드가 닿는 단계, 한 레인씩)

| 검사 | 호스트 | 비고 |
|---|---|---|
| C1b | 53 / 0 | 80° 검사·종베기 데이터 검사 갱신 포함 |
| C0 | 47 / 0 | 1차 47 / 1(클라 화면이 허수아비 예고 장판 채움을 0.80까지만 샘플, 기준 > 0.8 — 클라 프레임 끊김). 편집기를 닫고 재실행해 0 |
| M | 104 / 0 | 즉시 판정 `_land_strike/_finish_strike` 리팩터 경로(주먹·발차기·넉다운·잡기) |
| M7 | 30 / 0 | 1차 25 / 12(클라 `_local` null, 몸이 뜨기 전에 `begin` 도착한 시작 레이스). 재실행 0 |
| C1f2 | 40 / 0 | 클립 선택 `is_thrust_motion` |
| C1c | 42 / 0 | 1차는 레인이 메모리로 끊겨 미실행. 재실행 0 |

1차 레인은 사용자 편집기·실행 게임(약 1.1 GB)과 같이 돌다가 세션 도구가 메모리 부족으로 셸을 정리했다. 재실행은 편집기를 닫은 뒤 한 쌍씩. C0·M7이 재실행에서 통과해 a 이전 커밋과의 비교는 필요 없었다.

```
G="C:/Users/kevin/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe"
"$G" --headless --path . -- --auto-host --auto-smoke --auto-only=C1g --auto-port=8140 --auto-quit=240
"$G" --headless --path . -- --auto-join --auto-smoke --auto-only=C1g --auto-port=8140 --auto-quit=240
# 스크린샷: 호스트만 창 모드
"$G" --path . -- --auto-host --auto-smoke --auto-only=C1g --auto-port=8141 --auto-quit=240 --shot=reports/C-1g-a
"$G" --headless --path . -- --auto-join --auto-smoke --auto-only=C1g --auto-port=8141 --auto-quit=240
```

## 4. 숫자가 아직 코드에 박혀 있는 곳

- **중복 1건:** `side_cut_angle` 120(바닥 FAN 표시)과 `side_cut_arc_deg` 240(판정·연출). 지시서가 c에서 표시를 a 값으로 돌리라 해서 남겼다. c에서 `side_cut_angle`을 지우고 `RangeShapes`가 `arc_degrees()`를 읽게 하면 끝. 그때까지 바닥 부채꼴은 판정보다 좁다.
- `server_authority.gd _sweep_tick`: 후보 검색 반지름 `reach + 1.5`(판정값 아님, 검색 범위), 전방 하한 `maxf(along, 0.05)`(피치 계산 0 나눔 방지).
- `skill_def.gd swing_eased`: `1 − (1 − p)²` — 완화 곡선. 값이 아니라 식이고 연출·판정이 같이 쓰지만, 곡선 모양을 바꾸려면 코드다.
- `player.gd _pose_swing`: 찌르기 밀어내기 `0.6 × sin(πp)`(기존, 연출).
- `overhead_cut.tres arc_start_deg` 90, `strike_height` 0.6, `side_cut.tres strike_height` 0.4 — 데이터이고 로컬 슬라이더가 있다. 서버 값은 아니다.
- `dummy.gd harness_pin` — 하네스 전용.

## 5. 지시서와 다르게 한 것 / 알려진 문제

- 지시서 "건드리지 않는 것"에 "스마트키 기본 꺼짐"이 적혀 있으나 현재 기본값은 **켜짐**(fc1eb7c, 11-03 사용자 요청). 그대로 두었다.
- 쓸기 중심을 임팩트 순간 위치로 고정했다. 처음엔 매 틱 현재 위치로 재계산했는데, 시전 스텝 0.5 m 때문에 우측 110° 허수아비가 휘두르는 도중 124°로 밀려 안 맞았다(1차 실행). 지시서의 "각 구간 누적"은 고정 중심을 뜻하므로 그렇게 맞췼다.
- 수평은 몸 **중심각**, 수직은 **반높이 포함** — 각각 C-1b의 부채꼴·수직 부채꼴 관례를 이었다. 통일하려면 결정이 필요하다(§6).
- 허수아비 hp는 마크 위에서 2 s 뒤 자동 회복되어 한 캐스트 사이에 올라갈 수 있다. 검사는 hp 대신 hit id(단조 증가)로 "맞았는지"를 읽는다(2·3차 실행에서 잡힘).
- 연출 피벗이 그리는 호는 판정 호와 같은 수이지만, KayKit 클립(Interact/Throw 대체)이 실제로 그리는 각은 아직 측정하지 않았다 → b.

## 6. 결정 (2026-11-04, 사용자)

- 쓸기 중심 = 임팩트 순간 위치 고정 — 유지.
- 수평 중심각 / 수직 반높이 — 그대로, 통일하지 않음. `server_authority.gd` 쓸기 주석에 명시.
- `*_arc_deg` 슬라이더 범위 0~360 (`Tuning.limits_for`).
- 스마트키 기본값 켜짐 유지.
- `side_cut_angle` 삭제는 c에서.
