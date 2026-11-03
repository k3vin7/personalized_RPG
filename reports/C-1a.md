# C-1a 보고 — 능력치·HP·스태미나 재편 + 무기 공격력·방어력 + 피해 공식

- 날짜: 2026-11-03
- 엔진: Godot **4.7.2.stable.official.ed1daf0bf** (`C:/Users/kevin/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe`). 이 보고의 검사는 전부 4.7.2로 돌렸다. `--version` 출력과 각 로그 첫 줄로 확인. 4.7.1 → 4.7.2 전환은 사용자 지시(11-03).
- 지시서: `docs/전투_뼈대_작업_지시서_v1.md` §4 C-1a
- `project.godot` diff: **비어 있음** (4.7.2 에디터로 한 번 열어 클래스 캐시를 갱신한 뒤에도 비어 있음)

## 1. 만든 것 / 바꾼 파일

### 데이터
- `data/race_data.gd` — 다섯째 능력치 `vitality` 추가. 종족 4개 tres에 체력 열 추가(임시 = 지구력: 인간 70, 엘프 70, 드워프 100, 오크 80).
- `data/character_stats.gd` — `points`(5칸, 서버 소유, 전부 0) + `point_bonus()`; 근력·지구력·민첩·지능·체력 = 종족 값 + 포인트 × `stat_point_weight`. `max_hp = vitality × k_hp`, `max_stamina = endurance × (1 + stamina_alpha)`. `base_agility()`, `clear_points()`.
- `data/physics_tuning.gd` — Vitals: `hp_per_endurance`/`stamina_base`/`stamina_per_endurance` 제거 → `k_hp` 1.5, `stamina_alpha` 0.45, `stat_point_weight` 0.5. 새 그룹 Combat: `weapon_attack_sword` 10, `weapon_attack_shield` 6, `weapon_attack_bare` 1, `armor_player` 0, `armor_dummy` 0, `armor_flat_pct` 0.05, `crit_base` 0.05, `crit_mult` 1.5, `crit_per_agility` 0.001. Skills: `punch_stamina` 3, `kick_stamina` 7, `shove_stamina` 6, `grab_stamina` 2.
- `data/weapon_def.gd` **(신규)**, `data/weapons.gd` **(신규)**, `data/weapons/{bare,sword,shield}.tres` **(신규)** — WeaponDef: id·label·kind·hands·attack_field. 공격력은 `Tuning.server` 슬라이더에서 읽는다.
- `data/skill_def.gd` — `weapon_id`(기본 "bare"), `stamina_cost`, `stun_on_hit`, `attack_tag`(PHYSICAL/MAGIC), `holy` 추가. `stamina_cost`는 `<id>_stamina` 서버 슬라이더로 연결.
- `data/skills/*.tres` 5개 — `weapon_id = "bare"`.

### 서버 판정 (`scripts/world/server_authority.gd`)
- **`apply_hit(attacker, target, def, ctx)`** — 피해 함수 하나. 계수 × 무기 공격력 → `ctx.mult`(속도·높이 보정 자리, C-1b/c) → 치명타 → 방어력 → 아군 규칙 → HP 차감(`server_damage` / `Dummy.take_damage`) → 넉백은 기존 `send_force`로. 밀치기·타격(주먹·발차기·허수아비 강타)·던지기·돌 명중이 전부 이걸 거친다.
- `damage_after_armor(attack, armour)` = max(0, attack − armour × armor_flat_pct) × 100 / (100 + armour). `armor_of()`, `crit_chance()`, `_roll_crit()`.
- `send_force()`가 `apply_hit`를 거치지 않은 damage>0 이벤트를 받으면 damage를 0으로 지우고 `PLAYGROUND_HIT_BYPASS`를 찍는다. 이 함수 밖에서 HP를 깎는 코드는 낙하 피해(`server_damage(…, "fall")`)뿐이다.
- `server_damage()`에 힛 id. `_rule_hurt()`는 경직·넘어짐만 남김(피해 반은 `apply_hit`로).
- 하네스 전용: `harness_pin_crit(peer, -1/0/1)`, `harness_set_points()`. `--auto-smoke`에서는 기본 "치명타 안 뜸"으로 고정.
- `last_hit`, `hits_applied` 검사용 읽기.

### 클라·표시
- `scripts/player/player.gd`, `scenes/player.tscn` — `sync_points`, `sync_hit_ids`, `sync_hit_damages`(최근 4건 링) Vitals 동기화. 머리 위 라벨에 "HP n / max". 피드백은 HP 차이 추정이 아니라 서버가 적은 힛 id로 그린다.
- `scripts/world/dummy.gd` — `take_damage(amount, hit_id)`, 힛 링을 `push_state`로 복제.
- `scripts/ui/hit_feedback.gd` — 중복 제거를 시간창(0.25s)에서 **힛 id 기준**으로. id 0은 접지 않음.
- `scripts/world/rock.gd` — 돌 명중 피해가 `apply_hit`로. **추가 수정(아래 6절)**: 명중 속도·방향을 스텝 전 속도 `_flight_velocity`로 읽음.
- `scripts/debug/debug_panel.gd` — "전투 튜닝 (서버 승인)" 절, 체력·배분 표시.
- `autoload/force_system.gd` — `next_id()`(낙하 피해용 힛 id). `autoload/tuning.gd` — `armor_*` 슬라이더 범위 0~500.
- `scripts/world/playground.gd` — `--auto-only=C1a` 연결.

### 검사
- `scripts/tests/c1a_checks.gd` **(신규)** 39항목, 2피어.
- `scripts/tests/c_checks.gd`, `m_checks.gd` — H-3 생명력 검사를 새 공식으로. 스태미나 재충전 대기를 회복량 기반으로(101.5→145는 25/s로 1.74초).

## 2. 검사 결과 (전부 4.7.2, 2피어, 지연 0)

| 검사 | 호스트 | 클라 | 비고 |
|---|---|---|---|
| C1a | 39 / 0 실패 | 0 / 0 (host_failures=0) | 신규 |
| C0 | 47 / 0 | 0 / 0 | |
| C (H-3 생명력 포함) | 100 / 0 | 4 / 0 | 재실행 1회(아래 5절) |
| E | 111 / 0 | 4 / 0 | |
| M | 103 / 0 | 0 / 0 | |
| M7 | 30 / 0 | 0 / 0 | |
| N | 60 / 0 | 0 / 0 | |
| DK | 26 / 0 | 23 / 0 | |
| DT | 27 / 0 | (호스트 전용) | |
| RD | 38 / 0 | (호스트 전용) | |
| TH | 13 / 0 | 9 / 0 | |
| audit | PASSTHROUGH 0줄, 중력 tuned 22 = 돌 effective 22 ×6 | | |

`PLAYGROUND_RESULT_REJECTED rpc=push_server_tuning` 줄은 N-1 검사가 일부러 보내는 위조 요청이 거부된 것이다(정상).

### C1a 실측 (호스트 로그)
- 방어력 표: (10,0)=10.00 / (10,100)=2.50 / (10,400)=0.00 / (30,400)=2.00 / (20,400)=0.00 / (21,400)=0.20. 지시서의 4.75·4.4는 계산 실수로 확인(사용자 11-03), 기획서 공식 값으로 검사.
- 인간 HP 105.00 / 스태미나 101.50. 엘프 105/101.5, 드워프 150/145, 오크 120/116. 드워프 체력 열만 130으로 바꾸면 HP 195(지구력 100 그대로) → HP는 체력 열에서 나온다.
- 클라를 오크로: 서버 120/116, 클라 자기 계산 120/116.
- 포인트 [20,0,10,0,10] × 0.5: 근력 60→70, 민첩 70→75, 체력 75 → HP 112.5. 클라에서 본 호스트 근력 70, max_hp 112.5. 종족 선택 시 포인트 0으로.
- 주먹(계수 2 × 맨손 1) = 2.0, 맨손 공격력 3이면 6.0.
- 강제 치명타 2 × 1.5 = 3.0. crit_base 1.0 → 항상, 0.0 → 안 뜸. 민첩 +50 → 확률 0.05 + 50 × 0.001 = 0.100.
- 방어 100 vs 주먹 2: final 0, HP 변화 0, 숫자 표시 0개. 방어 20: 0.833 (캐릭터·허수아비 동일).
- 두 피어가 0.11초 안에 허수아비를 때림: id [9, 10], 호스트 화면 피드백 +2, 클라 화면 +2.
- 클라 9m 낙하: HP 105→65, 힛 id 11, 피해 40, 호스트 화면 피드백 +1.
- `apply_hit` 우회 50 피해 힘 이벤트: HP 변화 0, 이벤트 damage 0으로 지워짐, BYPASS 로그.
- 돌 직선 던지기(5m, 16.36 m/s) → 클라 명중: skill "", base 4.0 = `Rock.HIT_DAMAGE`, dealt 4.0.

## 3. 테스트 방법

```
G="C:/Users/kevin/Downloads/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe"
"$G" --headless --path . -- --auto-host --auto-smoke --auto-only=C1a --auto-port=7945 --auto-quit=240
"$G" --headless --path . -- --auto-join --auto-smoke --auto-only=C1a --auto-port=7945 --auto-quit=240
```
호스트를 띄우고 4초 뒤 클라. 회귀는 포트 둘로 두 레인(7951: E·M·C0·DK·TH, 7952: N·C·M7·DT·RD) 순차. 12쌍 동시 실행은 클라가 검사 노드를 못 만들어 전부 실패하므로 하지 않는다(11-02 r2 실행이 그렇게 무효가 됐다).

## 4. 멈추고 물은 것

없음. 표에 없어서 가정한 값:
- 종족 체력 = 지구력(지시서가 임시라고 한 값 그대로).
- 치명타 민첩 보정은 "종족 기본 민첩보다 높은 만큼"으로, 포인트 × 가중치가 그 차이를 만든다.
- 허수아비 HP는 아직 상수 60(`Dummy.MAX_HP`). 방어력만 슬라이더. 허수아비 체력 열은 기술 표에 없다 → C-2 몬스터 표가 나올 때.
- 직선 던지기의 "던져진 몸에 주는 피해"(shove_damage × charge)는 돌에도 `apply_hit`를 거친다. 돌은 HP가 없어 dealt 0이지만 `PLAYGROUND_HIT` 한 줄이 찍힌다(id 소비). 규칙상 예외를 안 둔 결과이며, 거슬리면 사람에게만 보내도록 바꿀 수 있다.

## 5. 지시서·기술 표와 다르게 한 것

- 지시서 C1a 기대값 (10,100)=4.75 / (30,400)=4.4 대신 기획서 공식 값 2.5 / 2.0으로 검사(사용자 확인).
- 타격 피드백 중복 제거를 시간창에서 힛 id로 바꿈(지시서 범위 밖). 같은 몸에 두 몬스터가 한 프레임에 맞는 경우 두 번 그리기 위해.
- `stamina_cost`는 필드와 슬라이더만. 실제 소모·거부는 지시서대로 C-1b(검)·C-1d(맨손).
- C 검사의 스태미나 재충전 대기를 1.0초 고정에서 회복량 기반(2.24초)으로. 첫 회귀에서 이 한 항목이 실패했고(127.1/145), 공식 변경에 따른 하네스 시간 문제라 게임 코드는 손대지 않았다.

## 6. 알려진 문제 · 이번에 고친 기존 버그

- **돌 정면 명중이 한 번도 안 잡히던 버그**(C-1a 이전부터). `body_entered`는 물리 스텝 뒤에 오므로 그때의 `linear_velocity`는 충돌 후 값이다. 캡슐에 정면으로 맞아 멈춘 돌은 0.19 m/s로 읽혀 `HIT_SPEED` 3.0에 걸러졌다. 실측: 15.98 m/s로 날아가 x 4.34에서 멈췄는데 `PLAYGROUND_ROCK_HIT` 없음. 스텝 전 속도 `_flight_velocity`로 속도·방향을 읽게 고쳤고, 같은 던지기가 16.36 m/s 명중으로 잡힌다. 스치는 명중만 잡히던 이전 E 검사 기록(speed=4.99)과 일치한다.
- 직선 던지기는 손 높이(약 2.6m)에서 수평으로 나간다. 1m 옆 사람은 머리 위로 지나간다(CLAUDE.md 7번). 검사는 5m 거리에서 한다.
- 11-02 23:45 전체 회귀(r2)는 12쌍 동시 실행으로 무효였다. 이번 결과가 C-0 이후 첫 유효 회귀다.

## 7. 다음 단계(C-1b) 전에 결정이 필요한 것

- 허수아비 HP를 표로 뺄지(지금 상수 60). C-1b 검사에서 찌르기 정지/달리기 피해 차를 재려면 HP가 충분해야 한다.
- 직선 던지기의 돌 대상 `apply_hit` 호출을 그대로 둘지(위 4절).
- `docs/` 지시서의 4.7.1 표기와 C1a 기대값은 사용자가 고친다.
