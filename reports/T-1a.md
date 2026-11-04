# T-1a 보고 — Terrain3D 설치·호환

2026-11-04. 지시서 `docs/T-1_작업지시서.md` 소단계 a. C-1g e(카메라 줌, 39de84e) 뒤 시작.

## 1. 고른 릴리스와 근거

| 항목 | 값 |
|---|---|
| 엔진 | Godot 4.7.2.stable (ed1daf0bf), Jolt |
| 선택 | **Terrain3D v1.1.0-stable** (2026-10-30, 최신) |
| 릴리스 노트의 지원 범위 | "Supports Godot 4.5-4.8+" — 4.7.2 포함 |
| 차선 | v1.0.2-stable (2026-05-19): "Supports Godot 4.4-4.7". 1.1과 API가 달라(토론 #756) 지금 1.0.2로 시작하면 곧 옮겨야 한다 |
| 파일 | `Terrain3D_v1.1.0-stable.zip` 45.7 MB (GitHub Releases) |
| `terrain.gdextension` | `compatibility_minimum = 4.5`, entry `terrain_3d_init` |

## 2. 설치

- 경로 `addons/terrain_3d/` (zip의 `addons/` 그대로, `demo/` 24 MB는 넣지 않음). 59 MB: `bin/` 47 MB(윈도·리눅스·맥·안드로이드·iOS·웹 전 플랫폼 바이너리), `brushes/` 12 MB(편집기 브러시 PNG), 나머지 0.4 MB.
- `project.godot`에 `[editor_plugins] enabled=("res://addons/terrain_3d/plugin.cfg")`.
- 헤드리스 편집기 스캔 한 번(`godot --headless --path . --editor --quit`, 16 s, 오류 0)으로 `.godot/extension_list.cfg`에 등록됐다. **새로 클론한 머신에서 헤드리스만 돌리려면 이 스캔이 한 번 필요하다**(`.godot/`은 git에 없음). 이후 헤드리스 실행은 편집기 없이 확장을 읽는다.
- 플러그인 파일은 손대지 않았다.

## 3. 헤드리스 로딩 확인 — 뜬다. 별도 레인 불필요

`scripts/tests/t1a_probe.gd`(`--headless --script`): `Terrain3D` `Terrain3DData` `Terrain3DRegion` `Terrain3DMaterial` `Terrain3DAssets` `Terrain3DCollision` `Terrain3DInstancer` 클래스 존재, `get_version()` = 1.1.0.

### T1a 검사 — 호스트 10 / 0, 클라 0 / 0 (2피어, 헤드리스)
`scripts/tests/t1a_checks.gd`(`--auto-only=T1a`). 두 피어가 각자 빈 `Terrain3D`를 놀이터 씬에 넣고 읽는다.

| 검사 | 호스트 | 클라 |
|---|---|---|
| 확장 로딩 / 버전 | true / 1.1.0 | true / 1.1.0 |
| 빈 지형 노드가 씬에 들어가 `data`·`collision` 객체를 만듦 | true / true | true / true |
| 빈 지형 높이 조회 `data.get_height()` | NAN (영역 없음) | NAN |
| 충돌 모드 5종 | DISABLED, DYNAMIC_GAME, DYNAMIC_EDITOR, FULL_GAME, FULL_EDITOR | 같음 |
| 충돌 기본값 | mode 1(DYNAMIC_GAME), shape_size 16, radius 64, layer 1, mask 1, priority 1.0 | 같음 |
| 이동 경고 / 보정 | 0 / 0 | |

헤드리스에서 카메라가 없으면 `Terrain3D`가 "Cannot find clipmap target or active camera" 오류를 찍는다. 검사에서는 `clipmap_target`을 로컬 몸으로 지정해 해결했다(전용 서버가 할 방식).

### 기존 검사 회귀 (Terrain3D 설치 상태, 한 쌍씩)

| 검사 | 호스트 | 비고 |
|---|---|---|
| C0 | 47 / 0 | 1차 47 / 1: 클라 순간이동 때 이동 경고 1건(79 m/s, 유예 만료 뒤 동기화된 알려진 하네스 레이스). 재실행 0 |
| C1b | 53 / 0 | |
| M | 104 / 0 | |
| C1g | 20 / 0 | |

## 4. 알려진 제한 (문서·API에서 읽은 것, b에서 실측)

- **충돌 생성 방식**: Dynamic 모드는 카메라(1.1: clipmap target) 주변 `radius`(64 m) 안에만 `shape_size`(16 m) 조각으로 만든다. Full 모드는 영역(region)마다 하나씩 전체를 만든다("큰 지형에서 메모리 많이 씀"). 영역이 없는 곳(WorldNoise 배경)에는 충돌이 없다.
- **서버 전용 모드는 따로 없다.** 전용 서버는 카메라가 없고 플레이어가 여럿이므로 Dynamic은 한 대상 주변만 덮는다 → 서버는 **FULL_GAME**(전 영역, 시작 시 한 번), 클라는 DYNAMIC_GAME(카메라 주변)이 자연스러운 조합. 서버와 클라가 같은 지형 데이터 파일을 읽으면 "지형 충돌은 같은 데이터" 규칙을 만족한다. 실제 서버 틱 비용은 f에서.
- 높이 조회: `data.get_height(pos)`(보간, 영역 밖·구멍은 NAN), `data.get_normal`, `get_intersection`(레이마칭/GPU). 문서는 적이 많으면 물리 대신 `get_height`를 권한다 — C-2 몬스터에 해당.
- 문서가 Godot Physics의 지형 충돌 신뢰도를 낮게 보고 Jolt를 권한다. 이 프로젝트는 이미 Jolt.
- 충돌 레이어 기본 1. 이 프로젝트의 `Layers.TERRAIN`에 맞추는 건 b.
- 편집기 플러그인(`src/editor_plugin.gd`)은 편집기에서만 돈다. 게임 코드는 `Terrain3D` 노드와 데이터만 쓴다.

## 5. 결정이 필요한 것

- **저장소 크기**: `addons/terrain_3d` 59 MB(현재 repo pack 0.4 MB). (a) 그대로 커밋(플러그인 무수정, 가장 단순) / (b) `bin/`에서 윈도·리눅스 x86_64만 남기고(≈16 MB) `terrain.gdextension`의 나머지 줄을 지움 / (c) 플러그인은 git에서 빼고 설치 스크립트로 받기. 권장 (a): 플러그인 업데이트가 zip 덮어쓰기 한 번으로 끝난다.
- 서버 충돌 모드 FULL_GAME, 클라 DYNAMIC_GAME 조합으로 b를 진행해도 되는지.

## 6. 정지. 다음 소단계(b)는 승인 뒤
