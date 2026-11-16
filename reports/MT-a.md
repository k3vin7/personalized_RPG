# MT-a 보고 — 말 타기 1차, 소단계 a (소환·타기·내리기)

2026-11-16. 채팅 지시 "말 타기 1차 구현 (이동 전용)"의 [a]. 스크린샷은 찍지 않았다.
b(속도·가속·회전), c(제한·낙마), d의 나머지는 아직 손대지 않았다. 커밋하지 않았다.

## 1. 만든 것

- **요청과 판정**: `Intent.MOUNT {on}`. 키는 요청이고, 서버가 소환 시계(`mount_summon_time`)를 돌린 뒤
  `Player.sync_mount`(NONE / SUMMONING / MOUNTED)를 쓴다. Vitals 동기화기가 나른다(무기와 같은 방식).
  내리기(`on=false`)는 즉시. 소환 중에 같은 키를 누르면 취소.
- **서버 규칙** (`ServerAuthority._rule_mount`, `_tick_mounts`):
  누를 때는 죽음·들고 있음·잡혀 있음만 본다. "서 있는가(IDLE/MOVE)"는 시계가 끝날 때 본다
  (상태는 왕복 지연 뒤에 오므로 소환 1초가 유예창 역할 — CLAUDE.md 2번). 죽으면 말에서 내려진다.
- **말** (`scripts/player/player_mount.gd`, 신규 `PlayerMount`): 모든 피어에서 `sync_mount`를 보고 코드로 만든다.
  몸통·머리·다리 4개 박스. 몸의 자식이라 동기화기가 따로 필요 없다. 길이 2.2 m, 등 높이 1.5 m, 폭 0.7 m.
- **충돌체**: 탄 동안 캡슐을 끄고 말 크기 박스(0.7 × 1.5 × 2.2)를 켠다. 모든 피어에서 같다.
  몸 원점 높이는 걸을 때와 같다(바닥 + half_height) — 네비·그림자·조준 표시가 그대로 맞는다.
- **앉은 위치**: 탄 사람 그림(`_visual`)과 머리 위 글자를 등 위로 올린다(인간 0.85 m, 오크 1.16 m). 그림만 올린다.
- **내린 뒤**: 말은 그 자리에 `mount_linger_time`(3초) 서 있다가 사라진다. 남은 말은 그림뿐이다(충돌 없음).
- **오크**: 종족 데이터 `large_mount`(오크만 true)인 종족은 같은 말을 `mount_large_scale`(1.3)배로.
- **키**: `LocalTuning.mount_key` 기본 Z. 디버그 패널 "조작 키"에 버튼. 한 키는 한 뜻(슬롯·돌진과 서로 비운다).

## 2. 검사 결과 (2피어, 0 ms)

`--auto-only=MT`, 호스트 45개 통과 / 실패 0. 클라는 호스트의 요청에 답하는 쪽이라 자체 검사 0개.

| 항목 | 실측 |
|---|---|
| 호스트 소환 → 탑승 | 누른 뒤 0.017 s에 SUMMONING, 0.5 s 시점엔 아직 캡슐·말 없음, 이후 0.500 s에 MOUNTED |
| 클라 소환 → 탑승 (서버 시계) | SUMMONING 확인 뒤 1.000 s |
| 탄 뒤 충돌체 | (0.7, 1.5, 2.2), 캡슐 꺼짐 — 호스트 화면·클라 화면 동일 |
| 말 위치 | 호스트 (0, 0, 11) / 클라가 본 호스트 말 (0, 0, 11). 4.75 m 탄 뒤에도 양쪽 차이 0.00003 m |
| 내리기 | 0.017 s. 캡슐 복귀, 그림 높이 0 |
| 말 남는 시간 | 호스트 3.02 s, 클라 화면 3.00 s, 위치 같음 (그동안 몸은 4.45 m 걸어감) |
| 클라의 말이 호스트 화면에서 | 내린 자리에 남고 3.00 s 뒤 사라짐 |
| 소환 중 다시 누름 | NONE으로 취소, 탑승 승인 0 |
| 소환 끝에 공중 | 취소, 사유 `not_standing` |
| 오크 | 충돌체 (0.91, 1.95, 2.86), 말 배율 1.30 — 양쪽 화면 동일, 바닥 위 |
| 키 | Z로 소환·취소. X로 바꾸면 Z는 안 먹고 X가 먹음. 슬롯·돌진 키와 서로 비움 |
| 이동 경고·보정 | 0 / 0 |

그 밖에:
- 레이어 감사(`--auto-only=audit`): `PLAYGROUND_AUDIT_PASSTHROUGH` 0줄, 돌 중력 effective 22 = tuned 22.
- `maps/world_finimes.tscn --walk-check`(1인): 착지·점프·이동 기존대로 동작.
- **돌리지 않은 것**: 전체 회귀, 100/200 ms 지연. 전체 회귀는 마지막 소단계 보고 직전에 한 번 돌릴 예정.
  `server_authority.gd`를 바꿨으므로 지연 검사 대상이다 — c(피격·낙마)까지 끝난 뒤 함께 돌리는 것을 제안한다.

## 3. 테스트 방법

```
godot --headless --path . -- --auto-host --auto-smoke --auto-only=MT --auto-port=7911 --auto-quit=120
godot --headless --path . -- --auto-join --auto-smoke --auto-only=MT --auto-port=7911 --auto-quit=120
```
직접 보려면 `maps/world_finimes.tscn`을 F6으로 열고 Z. 엔진: `Godot_v4.7.2-stable_win64_console.exe`.

## 4. 바꾼 파일

| 파일 | 내용 |
|---|---|
| `scripts/player/player_mount.gd` (신규) | 말 모델, 충돌체 교체, 앉은 높이, 내린 뒤 남는 말 |
| `scripts/player/player.gd` | `sync_mount`, `mount`, `is_mounted()`, `on_mount_changed()`, 그림·글자 높이, 글자에 "말 소환 중/기마" |
| `scenes/player.tscn` | Vitals 동기화 목록에 `sync_mount` |
| `scripts/world/server_authority.gd` | `Intent.MOUNT`, `_rule_mount`, `_mount_refusal`, `_set_mount`, `_tick_mounts` |
| `scripts/player/player_movement.gd` | "mount" 액션, `press_mount`, `rebind_mount`, 키 비우기 정리 |
| `scripts/debug/debug_panel.gd` | "말 타기" 묶음 이름, 한글 라벨 6개, 말 키 버튼 |
| `data/physics_tuning.gd` | `Mount` 묶음 6개 |
| `data/local_tuning.gd` | `mount_key` |
| `data/race_data.gd`, `data/races/orc.tres` | `large_mount` |
| `scripts/tests/mt_checks.gd` (신규), `scripts/world/playground.gd` | 검사와 디스패치 |

## 5. 추가한 변수와 기본값

| 변수 | 어디 | 기본값 | 뜻 |
|---|---|---|---|
| `mount_summon_time` | 서버 튜닝 (슬라이더) | 1.0 s | 키 → 탑승 |
| `mount_linger_time` | 서버 튜닝 (슬라이더) | 3.0 s | 내린 뒤 말이 남는 시간 |
| `mount_length` | 서버 튜닝 (슬라이더) | 2.2 m | 말 길이 |
| `mount_back_height` | 서버 튜닝 (슬라이더) | 1.5 m | 등 높이 |
| `mount_width` | 서버 튜닝 (슬라이더) | 0.7 m | 말 폭 (지시에 없어 정함) |
| `mount_large_scale` | 서버 튜닝 (슬라이더) | 1.3 | 큰 말 배율 |
| `large_mount` | 종족 데이터 | 오크만 true | 큰 말을 타는 종족 |
| `mount_key` | 로컬 설정 (패널 버튼) | Z | 소환·내리기 키 |

## 6. 지시와 다르게 했거나 지시에 없어 정한 것

1. **소환 1초 동안 움직일 수 있다.** 지시에 없었다. 걷던 채로 타진다. 끝나는 순간 공중·기절·시전 중이면 취소.
2. **오크 배율을 "오크면 1.3"으로 코드에 쓰지 않았다.** 종족 데이터의 `large_mount`와 서버 튜닝의 배율 숫자로 나눴다
   (종족 규칙은 종족 데이터로, 숫자는 슬라이더로).
3. **말 폭 0.7 m**는 내가 정한 값이다.
4. **내린 뒤 남은 말은 충돌이 없다.** 각 화면이 자기 시계로 3초를 센다(시간 값은 서버 튜닝).
5. 앉은 높이 보정 `SEAT_ABOVE = 0.25`는 그림 전용 상수로 코드에 있다(판정에 안 쓰임).

## 7. 알려진 문제

- **a만으로는 탄 채 점프·돌진·기술이 그대로 나간다.** 막는 것은 c다. 속도도 아직 걷는 속도다(b).
- **긴 박스 충돌체의 위험** (측정 전): 네비 메시는 반지름 0.45 m로 구웠는데 말은 반길이 1.1 m다.
  모퉁이에서 걸릴 수 있다. b의 360 m 주행 검사에서 실측해 보고한다.
- 사람·돌 바로 옆에서 타면 박스가 겹친 채 생긴다. 이 경우는 재지 않았다.
- 탄 사람의 몸통(등 위)은 충돌체 밖이다(충돌체는 말 크기, 높이 1.5 m). 타격 판정은 c에서 잰다.

## 8. 다음 단계 전에 결정이 필요한 것

1. 소환 1초 동안 **이동 허용** 그대로 둘지, 서 있어야 하는지(움직이면 취소).
2. 충돌체를 지시대로 **말 크기 박스**로 유지할지. b에서 모퉁이 걸림이 실측되면 다시 묻겠다.
