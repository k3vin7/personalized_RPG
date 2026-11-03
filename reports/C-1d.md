# C-1d 보고 — 돌진 조합 + 맨손 스태미나 + 발차기 결과

- 날짜: 2026-11-03
- 엔진: Godot 4.7.2.stable.official.ed1daf0bf. 모든 검사 로그 첫 줄로 확인.
- 지시서: `docs/전투_뼈대_작업_지시서_v1.md` §4 C-1d + 사용자 보강(돌진 조합 창은 소유자가 보낸 입력 간격 기준, 서버는 수신 간격과 비교해 치트만 거부).
- `project.godot` diff: **비어 있음**
- 그대로 둔 것(사용자 지시): `block_tolerance_mult` 1.0, `block_recover_fraction` 0.25, `shield_weight` 5, 들기 중 이동 허용. 손맛 때.

## 1. 만든 것 / 바꾼 파일

### 돌진 조합
- `data/skill_def.gd` `dash_combo: bool`. `punch.tres`, `thrust.tres`, `shield_bash.tres`에 true(지시서: 밀기·찌르기·주먹).
- `data/physics_tuning.gd` 그룹 Dash combo: `dash_combo_window` 0.15, `dash_combo_mult_max` 1.3(임시), `combo_jitter_allow` 0.05.
- `scripts/player/player_movement.gd`: 돌진 시작 시각 `last_dash_msec`, `seconds_since_dash()`.
- `scripts/player/player_skills.gd`: 조합 기술을 누를 때 소유자의 돌진 후 간격이 창 안이면 의도에 `dash_gap`을 실음(`_combo_payload`). 돌진 중(DASH)에도 조합 기술은 시전 가능 — 공중 찍기와 같은 "자유 시전" 경로(몸은 계속 돌진, 서버가 임팩트 시점에 판정).
- `scripts/world/server_authority.gd` `_rule_dash_combo`: 배율 = 1 + (max − 1) × (1 − 간격/창), 선형(간격 0에서 ×1.3, 창 끝에서 ×1.0). 거부 사유 셋: `outside_window`(창 밖), `no_dash`(최근 창+1초 안에 돌진 알림 없음), `gap_shorter_than_the_wire`(클라 간격 < 수신 간격 − 0.05). 수신 간격 = 돌진 알림 도착 → 평타 의도 도착. 지연 보정은 없다(치트 검사). 배율은 예약 판정의 `mult`에 곱해져 찌르기의 속도 보정과 함께 적용. `_shape_is_valid`가 `dash_gap` 타입 검사. 돌진 중 시전 허용(`dash_combo`인 def만).
- `_rule_shove`: 밀치기는 `Intent.SHOVE` 전용 문이라 `_rule_skill`의 스태미나 차감을 안 거쳤다 → 여기서 0 거부·6 차감(C-1b'의 누락, 이번에 잡힘).

### 맨손 스태미나·발차기
- 코드 변경 없음(C-1b'에서 이미 서버가 깎음). 검사만: 밀치기 6, 주먹 3, 발차기 7, 들기 중 초당 2. 발차기 넘어짐 `down_time` 1.0 + 기상 `getup_time` 0.3(M-2 그대로).

### 검사
- `scripts/tests/c1d_checks.gd` **(신규)** 24항목, 2피어. 0ms와 100ms 편도 프록시(왕복 200ms) 둘 다.
- `scripts/world/playground.gd` `--auto-only=C1d`. `scripts/debug/debug_panel.gd` 라벨.

## 2. 검사 결과 (4.7.2, 2피어)

| 검사 | 호스트 | 클라 |
|---|---|---|
| C1d 0 ms | 24 / 0 | 0 / 0 |
| C1d 100 ms 편도 프록시(왕복 200) | 24 / 0 | 0 / 0 |

| 회귀 검사 | 호스트 | 클라 |
|---|---|---|
| C1c | 42 / 0 | 0 / 0 |
| C1b | 40 / 0 | 0 / 0 |
| C1a | 39 / 0 | 0 / 0 |
| C0 | 47 / 0 | 0 / 0 |
| C (H-3 포함) | 100 / 0 | 4 / 0 |
| E | 111 / 0 | 4 / 0 |
| F (480초) | 35 / 0 | 1 / 0 |
| M | 103 / 0 | 0 / 0 |
| M7 | 30 / 0 | 0 / 0 |
| N | 60 / 0 | 0 / 0 |
| D | 55 / 0 | 0 / 0 |
| DK | 26 / 0 | 23 / 0 |
| DT / RD | 27 / 0, 38 / 0 | 호스트 전용 |
| TH | 13 / 0 | 9 / 0 |

이번 회귀는 두 레인 동시 실행에서도 1차에 전부 통과했다(C0·D의 클라 순간이동 레이스는 이번에 나타나지 않음).

audit: PASSTHROUGH 0, 중력 22 일치, 다른 객체 velocity 직접 쓰기 0건.

### C1d 실측 (0 ms, run c / 프록시 run lag2)
- 돌진 후 0.103초 주먹: 클라 간격 0.103, 서버 수신 간격 0.106, 배율 1.094(식 1 + 0.3 × (1 − 0.103/0.15)), 피해 2.18. 0.20초: 조합 요청 없음, 배율 1.000, 피해 2.0.
- 돌진 후 0.05초 찌르기(검): 조합 1.19 × 속도 보정 1.71(돌진 속도가 의도 시점 수평 속도로 읽힘) = 2.03, 피해 20.3.
- 돌진 후 0.105초 방패 밀기: 배율 1.09, 피해 3.27(3 × 1.09). 발차기는 조합 요청·승인 모두 0.
- 치트 검사: 돌진 없이 간격 0.05 주장 → `no_dash` 거부(수신 간격 2.9). 돌진 후 0.126초에 의도를 보내며 0.02 주장 → `gap_shorter_than_the_wire` 거부. 수신 간격 0.086에 0.05 주장 → 허용 오차 안이라 승인(×1.2).
- 스태미나: 밀치기 6.00, 주먹 3.00, 발차기 7.00 서버 차감. 돌 들고 1.0초 → 2.02.
- 발차기: 클라가 0.28초 뒤 DOWNED, 1.26초 누움(1.0 + 0.3), IDLE 복귀.
- 2피어 0ms: 클라가 돌진 후 0.104초 주먹 → 서버 수신 간격 0.105, 승인 ×1.092, 호스트 HP 105 → 102.8. 프록시 200ms: 클라 간격 0.103, 수신 간격 0.107, 승인 ×1.094 — 창 판정이 클라 간격 기준임을 지연 아래에서 확인.

## 3. 테스트 방법

```
G="C:/Users/kevin/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe"
# 0 ms
"$G" --headless --path . -- --auto-host --auto-smoke --auto-only=C1d --auto-port=8013 --auto-quit=300
"$G" --headless --path . -- --auto-join --auto-smoke --auto-only=C1d --auto-port=8013 --auto-quit=300
# 200 ms 왕복: 호스트 7777 → HOST_READY 뒤 프록시 → 클라 7901
python -I tools/udp_delay_proxy.py --listen 7901 --target 7777 --delay 100 --jitter 10
```
프록시는 호스트가 7777에서 듣기 전에 띄우면 첫 패킷의 ICMP 도달 불가로 죽는다(WinError 1234). `PLAYGROUND_HOST_READY`를 기다린 뒤 띄운다.

## 4. 멈추고 물은 것

없음. `dash_combo_mult_max` 1.3은 지시서의 "임시 ×1.0~1.3 선형" 그대로 슬라이더.

## 5. 지시서와 다르게 한 것

- 조합 기술은 돌진이 끝나기 전에도 누를 수 있다(DASH 상태에서 시전 허용). 지시서는 "돌진 시작 후 0.15초 안에 평타"라 상태 제한이 없으므로 이렇게 읽었다. 짧은 돌진(3m)은 0.1초 안에 끝나 누르는 시점이 DASH일 수도 IDLE일 수도 있고, 판정은 간격만 본다.
- 찌르기의 돌진 조합은 속도 보정과 곱이다(2.03배). 돌진 속도가 "시전 순간 수평 속도"로 읽히기 때문. 의도된 중첩인지 손맛 때 볼 것.

## 6. 알려진 문제

- `_rule_shove`가 C-1b'에서 스태미나를 안 깎고 있었다(전용 문). 이번에 잡음. 다른 전용 문(잡기)은 들기 중 초당 비용으로 처리된다.
- 허용 오차 0.05는 호스트 자체 틱(0.0083)과 같은 기계 두 프로세스 기준이다. 진짜 원격·지터 10ms에서도 통과했지만, 지터가 크면 정직한 클라의 조합이 거부될 수 있다. 거부는 조합만 빼고 평타는 그대로 나간다.

## 7. 다음 단계(C-1e) 전에 결정이 필요한 것

- 찌르기의 조합 × 속도 보정 중첩(5절).
- C-1e의 DEAD 상태는 이미 있다(B-d). 리스폰은 스폰 지점. 디버그 패널의 "전투 튜닝" 절은 Combat·Sword·Shield·Dash combo 그룹으로 이미 나뉘어 있다 — 한 절로 합칠지.
