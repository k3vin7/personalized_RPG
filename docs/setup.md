# 새 머신 설치 절차

2026-11-04 (T-1a). 사용자가 관리하는 문서. 에이전트는 사용자 지시가 있을 때만 고친다.

## 1. 엔진
- Godot **4.7.2** (stable, `ed1daf0bf`)만 쓴다. 4.7.1 이하로 열지 않는다.
- 콘솔 실행 파일을 쓴다(오류가 보인다): `Godot_v4.7.2-stable_win64_console.exe`.
- 물리는 Jolt(프로젝트 설정에 들어 있음), 120 Hz.

## 2. 저장소
```
git clone <repo>
cd personalized_RPG
```
`addons/terrain_3d/`(Terrain3D v1.1.0-stable, 59 MB)는 저장소에 통째로 들어 있다. 따로 받을 것 없다.

## 3. 첫 스캔 (헤드리스만 돌리는 머신도 반드시 한 번)
```
godot --headless --path . --editor --quit
```
- 16초쯤. 이게 `.godot/extension_list.cfg`에 Terrain3D GDExtension을 등록하고 임포트 캐시를 만든다. `.godot/`은 git에 없으므로 클론마다 한 번 필요하다.
- 이걸 건너뛰면 헤드리스 실행에서 `Terrain3D` 클래스가 없다.
- 새 `class_name`을 추가했을 때도 같은 명령으로 클래스 캐시를 갱신한다.

## 4. 확인
```
godot --headless --path . --script scripts/tests/t1a_probe.gd
```
`T1A_PROBE_RESULT loaded=true`와 `version=1.1.0`이 나오면 된다.

## 5. 검사 돌리기 (2피어)
```
godot --headless --path . -- --auto-host --auto-smoke --auto-only=C1g --auto-port=7901 --auto-quit=240
godot --headless --path . -- --auto-join --auto-smoke --auto-only=C1g --auto-port=7901 --auto-quit=240
```
- 호스트를 먼저 띄우고 4초 뒤 클라. 단계마다 포트를 다르게.
- 한 쌍이 약 670 MB(모델·클립 포함). 편집기가 열려 있으면 **한 쌍씩만**.
- 지연 검사는 `tools/udp_delay_proxy.py`(CLAUDE.md 참고). 이 머신의 `python3`는 Store 스텁이므로 `python`을 쓴다.

## 6. Terrain3D 업데이트
릴리스 zip의 `addons/terrain_3d`를 덮어쓰고 3번 스캔을 다시 한다. 플러그인 파일은 수정하지 않는다.
