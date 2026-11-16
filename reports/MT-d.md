# MT-d 보고 — 말 타기 1차, 소단계 d

2026-11-16. 브랜치 `mt-riding`. c는 `0caf6ef`로 커밋했다. d는 커밋하지 않았다. 스크린샷 없음.

## 1. 만든 것

1. **돌진 키·점프 키도 누르면 내린다** (결정 2). 돌진도 점프도 나가지 않고 내리기만 요청한다.
   서버가 탄 몸의 기술·밀치기·잡기·방패 요청을 거부하는 것은 그대로다.
2. **탄 동안 맞는 판정 = 탄 상태 캡슐 전체** (결정 3). 서버 판정 세 곳(즉시 판정, 휘두르기 판정, 밀치기)이
   탄 사람의 반지름을 0.6 m(`mount_radius` × 종족 배율)로, 높이를 발끝~머리(2.65 m)로 본다.
   `ServerAuthority.body_radius`, `mounted_lift`, `height_off`.
3. **이동 검사 경고 상세 로그** (결정 4). 경고가 나면 `PLAYGROUND_MOVE_WARN_DETAIL`에 표본 간격, 앞·뒤 위치 3점,
   이동 거리, 직전 표본 속도, 탄 상태를 찍는다. 판정은 바꾸지 않았다.
4. 소환 취소의 "막힘"에 벽·지형은 넣지 않았다 (결정 1, 그대로).

## 2. 검사 결과

MT 2피어 0 ms: **110 / 0**, 이동 경고 0 / 보정 0, 스크립트 오류 0.

| 항목 (인간, 캡슐 반지름 0.60 / 높이 2.65, 걷는 몸 0.40 / 1.80) | 실측 |
|---|---|
| 점프 키 / 돌진 키 (탄 채) | 같은 프레임에 내림, 점프·돌진 없음, 스태미나 그대로 |
| 호스트가 탄 클라에게 낮은 공격 (발차기, 발 위 0.50 m) | 명중, HP -5, 내림 |
| 호스트가 탄 클라에게 머리 높이 공격 (주먹을 2.40 m로 올림) | 명중, HP -2, 내림 |
| 발 위 3.12 m 공격: 걷는 몸 / 탄 몸 | 빗나감 / 명중 |
| 발차기 2.10 m 거리 (사거리 1.60): 걷는 몸 / 탄 몸 | 빗나감 / 명중 |
| 클라가 탄 호스트에게 낮은 공격 / 머리 높이 공격 | 둘 다 명중, 내림 |

머리 높이 공격은 검사에서 주먹의 타격 높이를 임시로 올려서 쟀다(기존 기술 중 그 높이를 치는 것이 없다).
걷는 몸도 원래 발 위 2.70 m까지는 맞는다(몸 + 팔다리 여유 0.9 m). 탄 몸은 같은 여유로 3.55 m까지 맞는다.

### MT 지연 200 ms (왕복 400)

110 / 0, 이동 경고 0 / 보정 0, 스크립트 오류 0. 244초.

### 골라 돌린 회귀 (0 ms, 한 쌍씩, headless)

고른 이유: `body_radius`와 타격·휘두르기·밀치기의 높이 검사를 바꿨으므로, 그 세 판정을 직접 쓰는 단계만 골랐다.

| 단계 | 왜 | 결과 | 걸린 시간 |
|---|---|---|---|
| M | 주먹·발차기 높이 띠, 종족별 반지름 | 104 / 0 | 79 s |
| D | 밀치기 사각형 | 55 / 0 | 182 s |
| C0 | 타격 지점 계산(`body_radius`) | 47 / 0 | 43 s |
| C1b | 부채꼴·찌르기·패리 | 53 / 0 | 79 s |
| C1c | 원형 판정·방패 | 42 / 0 | 51 s |
| C1g | 휘두르기 판정 | 20 / 0 | 30 s |
| RD | 종족별 밀치기 (앞선 실행 결과, d 코드 상태) | 38 / 0 | — |

돌리지 않은 것(사용자 지시): 나머지 회귀, B-e 지연 검사, 100 ms 지연.
TH 13/0(클라 9/0), G 22/0은 앞선 실행에서 d 코드 상태로 통과했다.

### 낙마 표시 검사 반복 (`--mt-thrown=10`, 한 접속 안에서 10번씩)

| 실행 | 실패 |
|---|---|
| 1차 10번 | 2 (5번째, 6번째) |
| 2차 10번 (클라 시계 기록 추가) | 0 |

합계 20번 중 2번 실패. 실패 내용은 같다: 서버가 낙마시킨 0.3 s 뒤에 클라 자기 화면이 아직 "탑승"이다.
잠시 뒤에는 클라 화면도 내린 상태가 되고 말도 사라진다(다음 번 시도에서 사라진 횟수가 따라와 있다).

원인으로 본 것(2차 실행의 클라 실시간 기록):
- 낙마하는 순간 클라의 물리 스텝 사이가 99~234 ms 벌어진다(정상 8 ms). 10번 모두 그랬다.
- 그 때문에 클라 화면이 서버 통지보다 113~273 ms 늦게 따라온다. 검사의 대기 시간이 300 ms라서
  여유가 27 ms까지 줄었고, 멈춤이 조금 더 길면 실패한다.
- 즉 탑승 상태 동기화가 틀린 것이 아니라, **맞아서 튕겨나가는 순간 클라가 0.1~0.23 s 멈추는 것**이다.
  무엇이 멈추게 하는지는 찾지 못했다(이전에 기록된 "클라 73 ms 멈춤"과 같은 계열로 보이나 확인 안 함).
  지시대로 고치지 않았다.

## 3. 테스트 방법

```
godot --headless --path . -- --auto-host --auto-smoke --auto-only=MT --auto-port=7942 --auto-quit=520
godot --headless --path . -- --auto-join --auto-smoke --auto-only=MT --auto-port=7942 --auto-quit=520
```

## 4. 바꾼 파일 (d, 미커밋)

| 파일 | 내용 |
|---|---|
| `scripts/world/server_authority.gd` | `body_radius`(탄 몸 = 캡슐 반지름), `mounted_lift`, `height_off`, 판정 3곳, 경고 상세 로그 |
| `scripts/player/player_movement.gd` | 탄 채 점프·돌진 키 → 내리기 |
| `scripts/tests/mt_checks.gd` | 검사 100 → 110, `--mt-thrown=N` 반복 검사 |
| `CLAUDE.md` | 검사 규칙 교체 (사용자 지시) |

d에서 새로 추가한 튜닝 값·동기화 변수는 없다.

## 5. 말 타기 전체에서 추가한 변수 (기본값)

서버 튜닝(`data/physics_tuning.gd`, 슬라이더 "말 타기" 묶음):

| 변수 | 기본값 |
|---|---|
| `mount_summon_time` | 1.0 s |
| `mount_linger_time` | 3.0 s |
| `mount_length` / `mount_back_height` / `mount_width` | 2.2 / 1.5 / 0.7 m |
| `mount_large_scale` | 1.3 |
| `mount_radius` | 0.6 m |
| `mount_seat_above` | 0.25 |
| `mount_speed_mult` | 3.3 |
| `mount_accel_time` / `mount_decel_time` | 0.8 / 0.5 s |
| `mount_turn_deg` | 180 도/초 |
| `mount_turn_slow_deg` / `mount_turn_min_ratio` | 0 / 0 |
| `mount_floor_snap` | 0.5 m |

그 밖: `mount_key` = Z (로컬, 키 변경 가능), 종족 데이터 `large_mount` (오크만 true),
동기화 `sync_mount`, `sync_mount_thrown`, 서버 `no_mount_zones` (빈 목록).
코드 상수로 남은 것: `MOUNT_SPEED_GRACE` 0.6 s (내린 직후 이동 검사 유예, `HOLD_GRACE`와 같은 종류).

전체 바꾼 파일: `autoload/net.gd`, `autoload/tuning.gd`, `data/local_tuning.gd`, `data/physics_tuning.gd`,
`data/race_data.gd`, `data/races/orc.tres`, `scenes/player.tscn`, `scripts/debug/debug_panel.gd`,
`scripts/player/player.gd`, `player_mount.gd`(신규), `player_movement.gd`, `player_skills.gd`,
`scripts/tests/mt_checks.gd`(신규), `scripts/world/dummy.gd`, `playground.gd`, `rock.gd`, `server_authority.gd`,
`world_walk.gd`(--ride-check).

## 6. 알려진 문제

- 낙마 표시 검사가 20번 중 2번 실패한다(2번 참고). 맞는 순간 클라가 0.1~0.23 s 멈춘다. 멈춤의 원인은 모른다.
- 첫 회귀 시도 때 "중단" 통지를 받은 백그라운드 스크립트가 실제로는 살아 있었고, 그 위에 다시 띄워 여러 쌍이 겹쳤다.
  그때 찍힌 C1f2 실패 10개는 겹친 상태의 결과라 믿을 수 없다. C1f2는 다시 돌리지 않았다.
- 이동 검사 경고는 다시 나오지 않았다(0건). 상세 로그는 아직 찍힌 적이 없다.
- 0.1 m 턱, N 검사 5개 실패, 탄 상태 전용 허용치는 그대로(별개 작업).

## 7. 결정이 필요한 것

1. 낙마 순간 클라 멈춤을 따로 조사할지.
2. 남은 회귀(C1f2, T1a~c, V1, 감사 등)와 B-e 지연은 "전체 검사" 때 돌린다.
