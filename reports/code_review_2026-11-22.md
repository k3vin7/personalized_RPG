# 코드 리뷰 2026-11-22 (커밋 안 된 mt-riding 변경분)

- 범위: 커밋 안 된 변경분만 봤다(막기·완벽 막기·피칭머신 등). 전체 폴더 구조 리뷰는 아직 안 했다.
- 상태: 하나도 고치지 않았다. 리뷰가 찾은 내용이고, 직접 재현해 확인하지 않았다.
- 줄 번호는 2026-11-22 기준이다.

## 오류 날 만한 곳 (전부 `scripts/world/server_authority.gd`, 막기)

1. **속임수 구멍 (~2655, `_rule_block` 내림 처리)**
   - 막기를 들지 않았어도 "막기 내림" 요청을 받으면 `forgive_move`와 `speed_over` 초기화가 매번 돈다.
   - 그래서 조작한 클라가 내림 요청을 계속 보내면 속도 검사가 꺼진다.
   - 고칠 방향: `_blocks.has(peer)`가 참일 때만 돌린다.
2. **던진 돌을 완벽 막기하면 던진 사람이 기절한다 (~1750, `apply_hit` → `_perfect_guard`)**
   - `_perfect_guard`에 돌(`from_node`)이 아니라 던진 사람(`attacker`)이 넘어간다.
   - 그래서 거리와 상관없이 던진 사람이 0.8초 기절하고 2.5만큼 끌려온다. 돌이 너무 무거워 되받아치지 못하는 경우에도 그렇다.
3. **내린 직후·돌진 직후 막기를 들면 정상 플레이어가 보정당한다 (~2172, `move_allowance`)**
   - 막기 중에는 가로 속도 한도를 "걷기 × guard_move_mult"로 덮어쓴다.
   - 그 바람에 바로 위에서 계산한 말·돌진 허용치가 사라진다.
4. **다시 들기 쿨다운을 건너뛸 수 있다 (~2633, `_block_downs`)**
   - "내림" 요청이 왔을 때만 기록한다. 기술 시전, 지구력 소진, `_tick_blocks`로 막기가 끝나면 기록이 없다.
   - 그래서 막기 → 기술 → 바로 막기로 완벽 막기를 연타할 수 있다.
   - 고칠 방향: `_blocks[peer]`를 지우는 모든 곳이 함수 하나를 거치게 한다.
5. **완벽 막기 한 번에 튕겨냄과 막기 깨짐이 같이 난다 (~2741)**
   - 완벽 막기 분기에서도 `_block_absorbs`를 부른다.
   - 지구력이 낮으면 0이 되어 막기가 깨진다. 이때 클라는 on_block_result(false)를 받는다.
6. **서버와 클라의 막기 수치가 다르다 (~316)**
   - 서버는 `Skills.get_def(guard)`, 클라는 `Skills.for_holder(...)`를 쓴다.
   - 무기 보정(회복, 완벽 판정 시간, 각도)이 있으면 두 쪽 판정이 어긋난다.

**공통 원인:** 막기 상태를 바꾸는 곳이 여러 군데 흩어져 있다. 막기를 끝내는 곳을 하나로 모아 1~6을 같이 고치기를 권한다.

## 작은 것 / 유지보수

- `scenes/player.tscn` ~77
  - `sync_guard_perfects/breaks/deflects`는 처음 생길 때 값이 복제되는데, `_guard_*_seen`은 0에서 시작한다.
  - 그래서 늦게 들어온 사람 화면에서 예전 막기 동작이 다시 재생된다.
  - 고칠 방향: 생길 때 `_seen` 값을 복제된 값으로 맞춘다.
- `scripts/world/pitching_machine.gd` ~156, `_reload`
  - 돌의 위치와 속도를 직접 쓰고, 순간이동 처리가 없다. §4 #6·#9 위반이다.
  - 고칠 방향: Rock에 제자리 놓기 함수를 만들어 그걸 부른다.
- `server_authority.gd` ~439: `GUARD_RAISE_SLACK`은 동기화 상수이므로 `SyncRules`로 옮긴다(§4 #8).
- `scripts/player/character_visual.gd`가 3,485줄이다.
  - 굽기·연구용 코드(`_blade_study`, `_composed`, `baked_motion`, `_study_feet`)는 `tools/sword_animset`으로 분리한다.
  - `_nearest_person`이 `sword_dummy.gd`와 `pitching_machine.gd`에 그대로 복사되어 있다.
  - `wf_checks.gd`에 임시 `_thrust_probe`가 남아 있다.

## 결정 필요

- 위 항목을 고칠지 (고친다면 설계부터 낸다)
- 전체 폴더 구조 리뷰를 할지
