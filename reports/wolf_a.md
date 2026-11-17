# 늑대 a — 늑대 한 마리 (2026-11-17)

엔진: `C:/Users/kevin/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe`

## 만든 것
- `scripts/world/wolf.gd` + `scenes/wolf.tscn`: `Dummy` 상속. 판정은 전부 허수아비와 같은 함수(`apply_hit` → `send_force` → `judge_knockback`, 잡기 표, `schedule_strike`, 예고 장판). 늑대 것은 두뇌(대기·추격·물기·포기)와 죽음뿐.
- `scripts/world/wolf_corpse.gd`: `Rock` 상속 시체. 들기·던지기·충돌은 돌 규칙 그대로, `wolf_corpse_time` 뒤 사라짐.
- `data/skills/wolf_bite.tres`, `data/physics_tuning.gd`의 "Wolf" 묶음 17개 값, 디버그 패널 한글 이름.
- `maps/latvia.tscn`: `state_event/wolf_pack_9/wolf_3` 표시 자리(로컬 96, 44)에 `wolf_a` 한 마리. 표시 노드는 그대로.
- 공용 수정: `dummy.gd`(크기·몸·두뇌 훅, `push_state`에 방향), `rock.gd`(`body_radius()`), `server_authority.gd`(크기 훅 사용, `cancel_strike`, `drop_hold_of`), `player.gd`(`human_walk_speed()` 한 곳으로).

## 검사
`--auto-only=WF` 2피어: 0 ms 71/0, 200 ms(프록시 100 ms + 지터 10 ms) 71/0.
잰 것: 값이 서버 소유, 인식·추격 속도 7.20 m/s, 물기 시작 2.98 m, 선딜 0.53 s, 물기 피해 8(호스트·클라 몸 모두), 두 화면 장판·방향 일치, 피한 몸은 안 물림, 마지막 가해자 타깃, 찌르기는 버팀(경직 없음)·밀치기는 튕김 4.18 m, 포기 8.10 m에서 귀환, 찌르기 4대에 사망, 시체 두 화면 동기화·들기·던지기·소멸.
이동 느낌·서성임 모습은 검사하지 않음(직접 확인 대상).

## 지시서와 다르게 한 것 / 임시로 정한 값
- 표에 없는 값을 임시로 넣음: 근력 45(허용치 5.4 m/s — 검 3기술은 버티고 발차기·밀치기는 튕김), 물기 길 폭 1.0 m, 뛰는 시간 0.2 s, 서성임 반경 3 m·멈춤 2 s·속도 0.3배, HP 35.
- 물기 판정은 선딜이 끝나는 순간 길 전체(3.5 × 1.0 m)를 한 번에 본다. 뛰는 동작은 그 뒤의 그림.

## 알려진 문제
- 살아 있는 늑대도 허수아비처럼 들 수 있다(40 kg ≤ 인간 들기 한도 72 kg). 전용 예외를 두지 않은 결과.
- 귀환 중에는 맞아도 반응하지 않고, 귀환해도 HP는 안 찬다.
- 길찾기 없이 직선으로 쫓는다(나무 다각형에 걸릴 수 있음).
- 늦게 접속한 화면에는 이미 누워 있던 시체가 안 보인다(늑대는 숨겨짐).
- 클라 로그에 시체 소멸 순간 `Node not found: …corpse_0` 1줄(늦게 도착한 위치 패킷, 방패와 같은 종류).
- `world_finimes`는 혼자 걷는 씬이라 2인 확인은 놀이터에서만 했다.
