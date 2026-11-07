# Tripo 인간 캐릭터 변환·통합 보고 (2026-11-06)

사용자 결정(2026-11-06): 원본 12클립 보존, 의미가 다른 대체 매핑 금지, 4K 원본 보존 + 2K 게임용,
42.9k 삼각형 유지, 메시/애니 GLB 분리, Godot 4.7.2 macOS 별도 설치. 아트 금지 규칙의 예외는
이 캐릭터 1개(변환·리깅 수정·클립 정리·임시 무기 장착점·테스트 씬)뿐이다.

## 만든 것

### 환경
- Godot 4.7.2 stable(`ed1daf0bf`)를 `~/Applications/Godot_4.7.2.app`에 설치(SHA512 공식 합계와 일치).
  `~/Downloads/Godot.app`(4.7.1)은 그대로 둠. 첫 스캔·T1a 프로브 통과.
- Blender 5.2.3 LTS(`/Applications/Blender.app`).

### Blender 빌드 (`tools/blender/tripo_human_build.py`)
factory-startup에서 매번 zip을 다시 읽어 같은 출력을 낸다(두 번 빌드해 sha256 동일 확인).
1. `assets/characters/tripo_human/source/tripo_convert_….zip` 보존(sha256 `e5a0356e…`), `.gdignore`.
2. FBX 임포트 → 검증: 아마추어 1·메시 1, 본 65(전부 `mixamorig:`), 21,682 vert / 22,426 face / 42,893 tri,
   영향 본 ≤4, 미가중 0, 스케일 1, 24 fps, rest 키 0.9995, 발바닥 z 0, 정면 -Y, 액션 12개 이름·프레임 범위.
3. 이름 정리: 아마추어 `Rig_Tripo`, 메시 `TripoHuman`, 본 접두 `mixamorig:` 제거(fcurve 경로 7,150개 재작성),
   액션 `Armature|x.001` → `x`. 아마추어 오브젝트 레벨 location/rotation/scale 채널(전부 상수) 제거.
4. `handslot.r`/`handslot.l` 추가: RightHand/LeftHand 자식, 손바닥 중앙(손목→중지 0.55), +Y = 새끼→검지
   너클 방향(주먹의 엄지 쪽, 칼날이 나가는 쪽), +Z = 손등 쪽. deform 아님.
5. 파생 클립(원본은 손대지 않음): `run_looped` = run f11–26, 마지막 프레임을 첫 프레임으로 덮어 이음새 0.0001
   (0.625 s, 15프레임 주기); `chop_single` = chop f30–56(1.083 s, 들어 올려 내려치기까지, 이후 홀드).
   이름에 `_loop` 접미를 쓰지 않은 이유: Godot 에디터 임포터가 접미를 떼어 `run`과 충돌한다(스캔 로그로 확인).
6. 텍스처: 4K JPG는 zip 안에 보존, 2K JPEG(q92, 1.05 MB) `tripo_human_albedo_2k.jpg` 생성 후 GLB에 내장.
7. 모든 액션을 NLA에 stash → `tripo_human.glb`(메시+스킨, 클립 없음, 3.2 MB),
   `tripo_human_anims.glb`(스킨 + 14클립, 1.5 MB). 애니 GLB에는 Hips에 스킨된 3정점 프록시 삼각형이 들어 있다.
8. 재검증: 두 GLB를 다시 임포트해 본 67·클립 14·길이·키·텍스처 2048 확인, GLB JSON에서 두 스킨의 관절
   순서 동일·루트 `Rig_Tripo` 확인.

### Godot 통합
- `scripts/player/character_visual.gd`: 팩별 상수를 `PROFILES`("kaykit", "tripo")로 묶음. `DEFAULT_PROFILE = "tripo"`,
  `--model=kaykit`으로 한 프로세스만 되돌리거나 `DEFAULT_PROFILE` 한 줄로 전체 롤백.
  슬롯 아래 `Grip` 노드가 모델 스케일을 되돌려 소품이 주문 크기(검 1.2 m)로 그려짐.
  `setup_preview()`(Player 없는 미리보기). 빠진 그림은 ""로 두고 이전 클립이 남는다(대체 없음).
- `scripts/tests/c1f2_checks.gd`: 본 수 기대값을 프로필에서 읽음, 소품 부모 검사가 Grip을 지나 BoneAttachment를 찾음.
- `scenes/tests/tripo_visual_test.tscn` + `scripts/tests/tripo_visual_test.gd`: 독립 테스트 씬(37검사, 창 모드면 스크린샷).
- 입력·물리·서버 권위·판정 코드는 손대지 않음.

### MODEL_HEIGHT 결정
캡슐은 `BODY_HALF_HEIGHT` 0.9 × 2 = 1.80 m(인간). Tripo 메시 키는 모델 단위 1.000(Blender 0.9995, Godot AABB 1.000)
→ profile height 1.0, model_scale = 1.80 / 1.0 = **1.800**. 측정 키 1.799 m, 발 y −0.900(캡슐 바닥), 머리 y 0.899.
KayKit는 2.4 → 0.750 그대로.

### 보행 속도 기준
빌드 스크립트가 접지 중인 발의 후진 속도를 측정: walk 0.582, run_looped 1.942 (모델 단위/s) × 1.8 → `walk_speed` 1.05,
`run_speed` 3.5 m/s. (KayKit는 기존 1.6 / 4.5 유지.)

### 걷기 기본 (사용자 요청, 같은 날 추가)
걷기/달리기 분기는 C-1f-2 때부터 코드 상수 2.5 / 1.2 m/s였고, 이동 속도가 6 m/s 하나라 걷기 클립이 출발·정지
순간에만 보였다. `LocalTuning`에 `visual_run_speed` 9.0, `visual_walk_back_speed` 7.0, `visual_stride_max` 2.0을
두고(디버그 패널 "조작 설정" 슬라이더) `CharacterVisual._state_key`가 이를 읽는다. 기본 6 m/s는 걷기, 배율로
9 m/s를 넘는 몸만 달리기. 걷기 클립 고유 속도가 약 1 m/s라 6 m/s에서는 배속 상한 2.0에 걸려 발이 미끄러진다
(상한 슬라이더로 조절 가능; 걷기 속도 자체를 서버에 두는 것은 이동 규칙 변경이라 이번 범위 밖).

### idle = standing_relax (사용자 요청, 같은 날 추가)
idle을 `wait`(손을 허리에 얹음, 6 s)에서 `standing_relax`(팔을 내리고 서서 쉼, 17.6 s, 이음새 0.026)로 바꿨다.
검은 허리 옆에서 앞·아래로(피치 +24°, 팔뚝과 95°, 정면과 27°), 방패는 왼손 옆. 스크린샷 갱신.
C-1f-2 2피어 tripo 재실행: 같은 15 실패, idle 관련 검사(서기·정지 복귀·기상·리스폰) 통과. 첫 실행 한 번은 렌더
프레임 83 ms 급등으로 dash 클립 읽기와 overhead_cut 타이밍이 더 실패했는데(17), 바로 다음 단독 실행에서 15로 돌아왔다.

## 테스트 결과

| 검사 | 결과 |
|---|---|
| Blender 빌드 재검증 | 통과. 두 번 빌드 sha256 동일 (`tripo_human.glb` 0a539a3b…, `tripo_human_anims.glb` b3ecc55d…) |
| Godot 4.7.2 GLB 검사(런타임 GLTFDocument) | 메시 GLB: Skeleton3D 67본, 경로 `Rig_Tripo/Skeleton3D`, 키 1.000. 애니 GLB: 14클립, 트랙 670개 전부 `Rig_Tripo/Skeleton3D:<본>` |
| 단일 GLB 비교(스크래치패드) | 트랙 수·경로 동일. 분리 파일로 확정 |
| tripo_visual_test (tripo, 창) | 37/37 통과. 텍스처 2048², VRAM 텍스처 +21.5 MB / 비디오 +24.3 MB |
| tripo_visual_test (kaykit) | 36/36 통과(헤드리스, 기준선; 스크린샷은 idle 임계 수정 전 창 실행분) |
| C-1f-2 2피어, kaykit (`--model=kaykit`) | 호스트 40/40, 클라 host_failures 0. 걷기 기본 적용 후 재실행도 40/40 (moving: `Walking_A` x2.00, 6.00 m/s) |
| C-1g-b 2피어, kaykit | 3클립 측정 |
| C-1f-2 2피어, tripo (기본) | 호스트 40검사 **15 실패**, 전부 클립이 없는 그림: jump/fall 1, side_cut(slash_h) 4, thrust 4, 클라 side_cut 복제 3, hit 1, down 1, death 1. 모델·보행·대시·overhead_cut·복제 걷기/대시·이동 경고 0은 통과. 걷기 기본 적용 후 단독 재실행: 같은 15 실패, moving `walk` x2.00 (6.00 m/s), 복제 `wait → walk`. kaykit 쌍과 동시에 돌린 한 번은 렌더 프레임 69 ms로 overhead_cut 타이밍 검사가 하나 더 실패(16) — 부하 탓, 단독 3회는 통과 |
| C-1g-b 2피어, tripo | 1클립 측정(overhead_cut ← chop_single). side_cut·thrust는 클립 없음 |

스크린샷: `reports/tripo_human/*.png` (tripo/kaykit × rest·idle+검·방패·walk·run·chop 시작/중간/끝·손 클로즈업).

## 테스트 방법
```
/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup --python tools/blender/tripo_human_build.py
G=~/Applications/Godot_4.7.2.app/Contents/MacOS/Godot
$G --headless --path . --editor --quit
$G --path . res://scenes/tests/tripo_visual_test.tscn -- --model=tripo     # 창: 스크린샷
$G --headless --path . res://scenes/tests/tripo_visual_test.tscn -- --model=kaykit
$G --headless --path . -- --auto-host --auto-smoke --auto-only=C1f2 --auto-port=7921 --auto-quit=300
$G --headless --path . -- --auto-join --auto-smoke --auto-only=C1f2 --auto-port=7921 --auto-quit=300
```
롤백: `--model=kaykit`, 또는 `character_visual.gd`의 `DEFAULT_PROFILE`을 `"kaykit"`으로.

## 문서와 다르게 한 것
- 애니 GLB가 "스켈레톤만"이 아니라 3정점 프록시 메시를 품는다. Godot는 스킨이 있어야 Skeleton3D를 만들고, 없으면
  클립 트랙이 Node3D 경로로 떨어져 모델 스켈레톤에 닿지 않는다(실측). KayKit 애니 파일이 마네킹을 싣는 것과 같은 이유.
- 검·방패 크기: Grip 역스케일로 KayKit에서도 검이 0.9 m(0.75배)에서 주문대로 1.2 m가 됐다. C-1g-b의 tip 각도가
  그만큼 달라진다(이번 kaykit 측정값은 로그에 있음).

## 알려진 문제
- 빠진 그림 12개(jump, fall, slash_h, thrust, block, hit, death, down, carry, carried, climb, stunned): 이전 클립이 그대로
  남는다(예: 공중에서 run_looped가 계속 돈다). Mixamo 클립 보충 전까지 C-1f-2는 tripo 기본값에서 15개 실패한다.
- chop 클립은 소품 없이 만들어져 손목이 고정 자루와 맞지 않는다. 슬롯은 주먹 기하를 따르므로 들어 올릴 때는 칼날이
  위·뒤(맞음), 내려친 끝 프레임에서는 칼날이 위로 선다(blade·너클 0.98, 피치 +32°). 슬롯을 돌려서 둘 다 맞출 수 없다.
- 클립마다 트랙 수가 다르다(39~53: rest와 같은 채널은 익스포터가 쓰지 않음, 최적화 옵션과 무관). 다른 클립이 움직인
  본은 트랙 없는 클립에서 그 포즈가 남는다(주로 손가락).
- dash는 run_looped를 2배속으로 쓴다(KayKit도 달리기 클립을 썼다). 다른 뜻으로 보면 ""로 바꾸면 된다.
- 런타임 로드라 텍스처 압축이 없다: 2K가 VRAM 21.5 MB.
- `.godot/`는 git 밖. 에디터 임포트는 `gltf/embedded_image_handling=3`(내장 유지)으로 두어 텍스처 사본을 뽑지 않게 했다.

## 실제 플레이 화면에서 수동 확인할 것
1. 두 피어 모두 Tripo 모델이 보이고 종족별 키(드워프 1.5 / 오크 2.2 m)로 스케일되는지.
2. 걷기·달리기 보폭이 발 미끄러짐 없이 맞는지(`walk_speed` 1.05 / `run_speed` 3.5는 측정값, 눈으로 확인 필요).
3. 검·방패 위치·방향: 허리 손 idle에서 검이 뒤로 서는 모습, 찍기 끝 프레임의 칼날 방향(위 "알려진 문제").
4. 방패 면의 방향(슬롯 +Z = 손등 기준으로 둔 추정값).
5. 점프·피격·사망·쓰러짐에서 이전 클립이 남는 모습이 허용 범위인지.
6. 텍스처 밝기·거칠기(roughness 0.5, metallic 0)가 조명에서 어떻게 보이는지.
