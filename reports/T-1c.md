# T-1c 보고 — 조각 경계 3종 + 두 영역 이음새

2026-11-04. 지시서 `docs/T-1_작업지시서.md` 소단계 c. 들어가기 전에 b의 미끄럼을 SLIDING 상태로 분리했다(§0). 스크린샷 없음.

## 0. b 후속 — SLIDING 상태 (사용자 결정 반영)

- `scripts/player/player.gd` — `State.SLIDING` 추가(enum 끝). `_update_fall_tracking`: SLIDING으로의 전이는 착지(공중에서 급경사에 닿으면 그 순간 낙하 정산), SLIDING 중에는 낙하를 추적하지 않는다. `is_sliding()`.
- `scripts/player/player_movement.gd` — `_on_steep_ground()`: 바닥(걷기 한계 이하)은 아니지만 `slide_max_deg` 이하 기울기의 접촉이면 급경사. 지상 스텝·공중 스텝에서 그 접촉을 만나면 AIRBORNE 대신 SLIDING. `_slide_step`: 중력만, 명령 없음, 평지에 닿으면 IDLE/MOVE(낙하 없음), 접촉이 2프레임 끊기면 AIRBORNE(거기서부터 낙하 추적 시작).
- `data/physics_tuning.gd` — `slide_max_deg` 75 (서버 튜닝 > 이동). 그보다 가파르면 면(面)이지 땅이 아니라 낙하.
- `scripts/world/test_terrain.gd` — 고원 테두리 1.5 → 1.0 m(1 m 격자에서 한 칸 8 m 낙차 = 83°, 전부 면). 고원 동쪽에 '활강로': 55° 미끄럼 2.1 m(8 → 5 m) 뒤 79° 1 m 면 — 미끄러지다 끊기는 경우.

### T1b 재실행 숫자 (32 / 0, 2피어)
| 상황 | 상태 열 | 낙하 기록 | HP |
|---|---|---|---|
| 51° 둑 2.5 m 위 | SLIDING → IDLE | 변화 없음 | 변화 없음 |
| 83° 테두리 4.8 m 위 | AIRBORNE → IDLE (SLIDING 없음) | 4.84 m | −7 (= (4.84−4)×8) |
| 55° 활강로 6.6 m 위, 5 m에서 끊김 (낙하 하한 1 m로 낮춰 측정) | SLIDING → AIRBORNE → IDLE | **4.31 m** | **−26.5** (끊긴 곳부터 = (4.31−1)×8; 꼭대기부터라면 44.8) |
| 30.5° 언덕면, 한계 25 | SLIDING → IDLE | 변화 없음 | 변화 없음 |

회귀(미끄럼 패치, 한 쌍씩): D 55/0, F 35/0, E 111/0, M 104/0, N 60/0, C1b 53/1(클라 화면 종베기 피치 최저 −26.95° vs 기준 −27.0°, 렌더 프레임 샘플링 흔들림 → c 레인에서 재실행).

## 1. 바꾼 파일·함수 (c)

- `scripts/world/boundary_pieces.gd` (신규, `class_name BoundaryPieces`) — 경계 3종. CSG로 만들고(`CSGBox3D`·`CSGCombiner3D` 빼기) 메시(`get_meshes()`)를 `create_trimesh_shape()`로 구워 `StaticBody3D`에 얹는다. CSG 노드는 그림, 베이크된 바디가 물리·네비·등반이 읽는 것. CSG 메시는 트리에 들어간 뒤 지연 호출로 만들어지므로 베이크도 `call_deferred`, 놀이터의 네비 베이크는 그 뒤로 다시 지연. (`bake_static_body()`는 이 빌드에 없다 — 1차 실행에서 확인.)
  - ① 잘린 산 단면: 6 m 단차 x 200~230·z 40~60, 남쪽 면이 절단면. 서쪽 절반 CLIMBABLE(등반 색 6f9a63), 동쪽 절반 WALL(매끈한 벽 색 555b62). 태그 meta `boundary` = `cliff_climb` / `cliff_slip`, 그룹 `boundary`.
  - ② 잘린 바위: 반지름 3 구에서 이음새 x = 192 동쪽을 빼 평평한 절단면이 이음새 평면에 선다. 바위라 CLIMBABLE.
  - ③ 갑자기 생기는 물: x 232~250·z 8~24 반투명 평판 + 같은 발자국의 보이지 않는 WALL 바디(높이 2). 물 규칙이 없어 **막힘**. 그룹 `water`, 태그 `water`.
- `scripts/world/test_terrain.gd` — 영역 2개(x 128~256, 위치 (2,0)·(3,0)), 이음새 x 192 위에 낮은 둔덕(반지름 10, 높이 2)을 걸쳐 놓아 이음새에 기울기가 있게 함.
- `scripts/world/playground.gd` — `BoundaryPieces.build(_region)`(네비 영역 아래), `_bake_navigation`을 `call_deferred`.
- `scripts/world/regions.gd` 주석. `scripts/tests/t1c_checks.gd` (신규, `--auto-only=T1c`, 2피어). `scripts/tests/t1b_checks.gd` 영역 2개 기대로 갱신.
- `scripts/world/server_authority.gd` — `harness_forgive_move()`(자동 검사 전용, `Net.auto_smoke` 게이트)가 주는 이동 용서를 2샘플 → 30샘플(`HARNESS_FORGIVE_REMOTE`, 원격 리스폰과 동일)로. 클라 순간이동이 왕복 + 클라 프레임 지연 뒤에 도착해 0.22 s로는 부하 아래서 모자랐다(D 137 m/s, C0 79 m/s). 판정 경로 아님.

## 2. 슬라이더와 기본값

| 슬라이더 | 위치 | 기본 |
|---|---|---|
| `slide_max_deg` | 서버 튜닝 > 이동·점프 | 75 |

경계 조각의 크기·위치는 블록아웃 내용이라 상수(b의 지형 모양과 같은 이유).

## 3. 검사 결과 — T1c 호스트 22 / 0, 클라 0 / 0 (4.7.2, 2피어, 헤드리스; 최종 실행 포함 2회 22 / 0)

| 검사 | 실측 |
|---|---|
| 조각 4개, 레이어·태그 | 절벽(등반) 4=CLIMBABLE, 절벽(미끄럼) 2=WALL, 바위 4, 물 2. 호스트·클라 같은 자리·같은 레이어·같은 베이크 경로 |
| CSG 베이크 | 절벽 둘·바위 `trimesh`(ConcavePolygonShape3D), 물은 설계상 박스 |
| 바위 절단면 | 동쪽에서 쏜 레이 명중 (192.00, 1.5, 50), 법선 (1, 0, 0) |
| 두 영역 | `region_locations` [(2,0), (3,0)], 네비 폴리곤 469 |
| 이음새 높이 (z 20 둔덕, x 189~195) | `get_height` vs 모양 최대 차 0.037 — x 191.5·192.5에서 `get_height`가 영역 끝 칸을 보간하지 않고 정점값을 준다. 충돌은 아래처럼 정확 |
| 이음새 충돌 (0.5 m 간격 레이 x 188~196) | 빈 칸 0, 모양과 차 0.012 m |
| 호스트 이음새 횡단 (186 → 198 → 186) | 1.9 s / 1.9 s 도착, 상태 MOVE만, 바닥 간격 최대 0.021 m |
| 클라 이음새 횡단 | 2.08 s 도착, MOVE만, 간격 0.020 m, 클라 네비 폴리곤 469 |
| 등반 절벽 | attach 성공, CLIMB → MANTLE → IDLE, 2.3 s에 5.97 m 올라 꼭대기(207.5, 6.9, 40.4)에 섬 |
| 미끄러운 절벽 | attach 거부(레이어), 상승 0, 걸어 들어가면 면 앞 z 39.25에서 멈춤 |
| 잘린 바위 | 절단면에 attach 성공, 2 s에 2.33 m 상승(CLIMB) |
| 물 | 안으로 걸으면 가장자리 x 231.2에서 멈춤(가장자리 232), 안의 블록은 `water` 그룹 |
| 이동 경고 / 보정 | 0 / 0 |

### 회귀 (c 코드 전체, 한 쌍씩)
| 검사 | 호스트 | 비고 |
|---|---|---|
| T1b | 32 / 0 | 영역 2개 기대로 갱신 |
| C0 | 47 / 0 | 용서 변경 뒤 재실행도 47 / 0 |
| C1b | 53 / 0 | 미끄럼 레인의 1실패(피치 −26.95 vs −27)는 재실행에서 통과 — 샘플링 흔들림 |
| M | 104 / 0 | |
| F | 35 / 0 | 등반 |
| E | 111 / 0 | |
| D | 55 / 1 → 55 / 0 | 1실패 = 클라 순간이동 이동 경고 137 m/s(오늘 두 번째, 같은 자리). 하네스 전용 `harness_forgive_move`가 2샘플(0.22 s)만 용서하던 것을 원격 리스폰과 같은 30샘플로 맞춤(`HARNESS_FORGIVE_REMOTE`, 게임 경로 아님) |
| N | 60 / 0 | |
| DK | 28 / 0 | |

## 4. 결정이 필요한 것

- `Terrain3DData.get_height()`가 영역 가장자리 칸에서 보간하지 않는다(0.037 m). 충돌은 정확하므로 플레이어에겐 무관하지만, C-2에서 몬스터를 `get_height()`로 세우면 이음새 근처에서 수 cm 뜨거나 묻힌다. `get_surface_height()`나 레이 사용을 C-2 메모로.
- 물 "막힘"은 보이지 않는 벽이라 캐릭터가 물 가장자리에서 멈추는 모양이 어색할 수 있다. 수영 규칙이 들어올 때 블록을 뺀다.
- 등반 절벽 꼭대기는 WALL 절반의 윗면도 걸을 수 있다(플레이어 마스크가 WALL 포함). 의도대로인지.
- 경계 조각을 어디에 얼마나 둘지는 e의 블록아웃 규칙(`WALL_CLIMB_`/`WALL_SLIP_`/`WATER_`)으로 넘어간다. 이번 셋은 규칙의 견본.

## 5. 정지. 다음 소단계(d)는 승인 뒤
