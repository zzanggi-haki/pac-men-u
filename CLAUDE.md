# PAC-MEN-U

맥 메뉴바 아이콘을 팩맨(팩미)이 먹었다(숨김)/뱉었다(표시) 하는 메뉴바 정리 앱.
전체 기획은 `기획서.md` 참고.

## 구조
- `main.swift` — 앱 전체 (단일 파일, AppKit)
- `build.sh` — 빌드 → 서명 → `/Applications/PAC-MEN-U.app` 설치까지 한 번에
- `gen-icon.swift` — 앱 아이콘(.icns) 생성기 (메뉴바 팩맨과 동일 드로잉)

## 빌드/실행
```sh
./build.sh && open /Applications/PAC-MEN-U.app
```

## 주의사항
- **서명은 반드시 "Apple Development: zzanggi1206@naver.com (6GWWF97289)" 유지.**
  ad-hoc(`-s -`)으로 바꾸면 재빌드마다 손쉬운 사용 권한이 풀린다.
- 뱃속 리스트(AX 스캔)는 손쉬운 사용 권한 필요. 먹기/뱉기 토글은 권한 없이 동작.
- 구분점(⋮) 왼쪽 아이콘들이 먹히는 영역. 위치는 `NSStatusItem Preferred Position`
  (defaults domain `com.zzanggi.pacmenu`)에 저장됨.
- 노치 판정 기준선은 `NSScreen.auxiliaryTopRightArea.minX`(이 맥은 956pt).
  아이콘 프레임의 왼쪽 끝이 이 선보다 왼쪽이면 노치에 가려진 것으로 본다.
  자동 구출은 **먹을 게 있을 때만**(구분점 왼쪽에 아이콘이 남아 있을 때만) 동작한다.

## 디버그 (CLI에서 실행 중인 앱 조작)
- 노치 기준선 위조(노치 없는 맥/외장 모니터에서 테스트용):
  `defaults write com.zzanggi.pacmenu debugNotchEdgeX -float 1120` → 재실행. 지울 땐 `defaults delete`.
- 토글: DistributedNotification `com.zzanggi.pacmenu.toggle`
- 상태 덤프: `com.zzanggi.pacmenu.dump` → `/tmp/pacmenu-dump.txt`
- 팩미 바 열기: `com.zzanggi.pacmenu.bar`

## v0.2 — 노치 구출 (Notch Rescue)
노치에 가려서 안 보이던 메뉴바 아이콘 문제 해결.
- `Notch.edgeX()` — 카메라 하우징이 끝나는 x. 노치 없는 맥에선 nil.
- `AXScanner.snapshot()` — 모든 메뉴바 엑스트라를 프레임+구역(`visible`/`notch`/`offscreen`)으로 반환.
- 4초 주기 `checkNotch()` (뱉은 상태에서만 동작) → ① 툴팁에 가려진 개수 표시
  ② 우클릭 메뉴 "🕳️ 노치에 가려짐" 섹션에서 AXPress로 직접 열기 ③ 자동으로 먹어서 구출.
- 개수를 팩맨 옆 title로 띄웠더니 상태 아이템 폭이 늘어 메뉴바 전체가 밀렸다(v0.4에서 제거).
  `NSStatusItem.squareLength` + 툴팁 유지할 것.
- 설정: "노치에 가리면 자동으로 먹기"(기본 켜짐). 수동 뱉기 후 10초는 유예.

## v0.3 — 팩미 바 (PacBar)
"노치를 건너뛰어 왼쪽에 보여준다"를 실제로 구현한 것. **왜 자체 패널이어야 하는지:**
NSStatusItem은 화면 오른쪽 끝에서 왼쪽으로만 쌓이고, 노치 왼쪽은 프론트 앱 메뉴 영역이라
서드파티가 아이콘을 놓을 수 없다(좌표 지정 API 자체가 없고, Preferred Position은 픽셀이
아니라 순서값이라 시스템이 오른쪽 영역 안으로 클램프한다). 실측에서도 macOS는 넘치는
아이콘을 노치를 건너뛰지 않고 그 아래로 밀어넣었다. 그래서 메뉴바 밑에 우리 창을 직접 그림.

- `PacBar` — `NSPanel`(borderless/nonactivating, `.statusBar` 레벨) + `NSVisualEffectView(.menu)`.
- **위치**: 오른쪽 끝을 `barAnchorX`(= 아직 보이는 아이콘 중 가장 왼쪽 것의 minX, 즉 노치가
  줄을 잘라먹은 지점)에 맞추고 왼쪽으로 자란다. 가려진 아이콘들이 원래 있었을 자리와 겹치게
  하려는 것. 스캔 결과가 없으면(먹은 상태의 뱃속 바) 팩맨 왼쪽 끝으로 폴백.
- 내용물: 먹은 상태면 뱃속, 아니면 노치에 가려진 것들 (`barItems()`).
- 여는 시점: **뱉을 때**(`barAfterSpit` 플래그 → 뱉고 1초 뒤 `checkNotch()`가 스캔을 마치고
  띄움. 뱉기 직후엔 아이콘 위치가 아직 안 잡혀서 즉시 띄우면 안 된다) + 우클릭 메뉴/CLI로
  명시적 열기. 둘 다 sticky — 아무 데나 클릭하면 닫힌다(글로벌 마우스다운 모니터).
- 호버 열기는 v0.5에서 제거. 참고로 NSTrackingArea는 쓰면 안 된다 — NSStatusBarButton이
  자기 트래킹 영역을 다시 만들면서 덮어쓴다. 굳이 하려면 포인터 폴링.
- 아이콘 그림은 `NSRunningApplication.icon`(앱 아이콘)이다. 진짜 상태 아이콘 픽셀(배터리 %,
  시계 모양)을 쓰려면 ScreenCaptureKit + 화면 기록 권한이 필요 — 2026-08-18 논의에서 보류.

## v0.9 — 스캔 성능
`AXScanner.snapshot()`은 실행 중인 앱 전부(~180개)에 AX 질의를 날려서 **한 번에 ~500ms**가
든다. 뱉은 직후 이걸 그대로 돌리면 바가 1.5초쯤 늦게 뜬다.
- `extrasPIDs` — 메뉴바 아이콘을 실제로 가진 앱(10개 안팎)의 pid 캐시. `snapshot(limitTo:)`로
  이것만 재질의하면 **~80ms**. 여러 큐에서 스캔하므로 `cacheLock`으로 보호.
- 뱉은 직후: 0.25초 대기 후 fast 스캔 → **뱉기~바 표시 340ms** (이전 ~1500ms).
- 주기 스캔: 4초마다 fast, 8틱(32초)마다 full. 새 앱이 뜨면(`didLaunchApplication`) full 1회.
- 먹은 상태에선 checkNotch가 아예 안 도니, 첫 뱉기를 위해 실행 1.5초 뒤 `warmCache()`로 캐시만
  채운다(뱉은 상태면 checkNotch가 채우므로 생략 — 풀스캔 2개가 겹치면 1.8초까지 늘어난다).
- 측정값은 덤프의 `spitToBar` / `lastScan` 참고.

## v1.0 — 뱉었는데 바가 안 뜨던 버그
`barAfterSpit`(bool) 방식은 **뱉기 직후 주기 타이머(4초)가 먼저 도는 경우** 깨졌다. 그 스캔은
아이콘이 아직 제자리로 안 돌아온 상태를 보고 "가려진 것 없음"으로 판정하면서 플래그를
소진해버린다. 0.25초 뒤 제대로 된 스캔이 3개를 찾아내도 플래그는 이미 꺼져 있어 바가 안 뜬다.
→ `barPendingAfter: Date?`로 바꿔서, **스캔이 시작된 시각**이 이 시점 이후일 때만 소진한다.
(완료 시각이 아니라 시작 시각으로 비교해야 한다.)

## v1.1 — 타이머 두 개가 충돌하던 문제
`뱉은 뒤 자동으로 다시 먹기`(설정)와 노치 자동 구출(하드코딩 10초 유예)이 각각 `eat()`을
불러서, 가려진 아이콘이 있으면 설정값(1분)을 무시하고 10초에 먹어버렸다.
→ 유예를 `scheduleAutoEat()` 한 곳에서만 잡고 `autoEatSeconds`를 그대로 쓴다. 설정이 '끄기'일
때만 노치 구출이 자체 10초 유예로 단독 동작. 설정 기본값도 60 → **10초**, 선택지에 10초 추가.

## v1.2 — 자동 먹기 끄기 옵션 제거
"뱉은 뒤 자동으로 다시 먹기"를 끌 수 있게 해뒀더니 노치 자동 구출과 유예 계산이 갈라지는
근본 원인이었다(v1.1에서 통합은 했지만 '끄기' 분기가 남아 있었음). → 상시 켜짐으로 고정.
선택지는 10초/30초/1분 세 가지만 남기고 기본값 10초. 예전에 '끄기'(0)로 저장돼 있던 값은
getter에서 10초로 보정해서 읽는다.

## v1.3 — 구분점 아이콘 교체 (‹)
"⋮"(세로 점 3개, 14pt 폭)를 왼쪽 쉐브론 "‹"(10pt 폭, 13pt heavy)로 교체. 방향성 있는 화살표가
"이 왼쪽은 먹힘"을 더 직접적으로 전달하고, 글리프가 얇아진 만큼 collapsedLength도 줄였다.

## v1.4 — 팩미 바에서 아이템 클릭 시 진짜 메뉴가 바로 닫히던 버그
뱃속(먹힌) 아이템을 클릭하면 `press()`가 `spit()`으로 뱉은 뒤 0.45초 뒤 AXPress로 진짜 메뉴를
연다. 그런데 `spit()`은 `barOnSpit`(기본 켜짐) 때문에 `barPendingAfter`를 세팅해서 0.2초 뒤
`checkNotch()`가 팩미 바를 다시 띄워버렸다 — 방금 연 진짜 메뉴를 덮어써서, 10초 자동 먹기와
무관하게 거의 즉시 닫히는 것처럼 보였다.
→ `press()`에서 `spit()` 직후 `barPendingAfter = nil`로 취소. 진짜 메뉴를 열 땐 바 재오픈을
건너뛴다.

## v1.5 — 진짜 메뉴를 닫자마자 바로 먹혀버리던 버그 (런루프 모드)
v1.4로 팩미 바가 진짜 메뉴를 덮어쓰는 건 막았는데, 그래도 "메뉴 열고 → 다른 곳 클릭해서
닫으면 → 그 순간 바로 먹힘"이 남아 있었다. 원인은 `Timer.scheduledTimer`가 기본적으로
런루프의 `.default` 모드에만 등록된다는 것 — `NSMenu`가 열려 있는 동안 런루프는
`.eventTracking` 모드로 도는데, 이 모드는 `.default` 에 없으니 그 사이엔 `notchTimer`/
`autoEatTimer`가 아예 멈춘다. 메뉴를 열어둔 시간만큼 밀렸다가, 메뉴를 닫아서 `.default`
모드로 돌아오는 순간 밀린 타이머가 "지금 당장" 몰아서 발화 — 실제 10초가 지났든 안 지났든
클릭해서 메뉴를 닫는 그 타이밍에 즉시 eat()이 터졌다.
→ 두 타이머 모두 `Timer(...)` + `RunLoop.main.add(timer, forMode: .common)`으로 바꿔서
메뉴 트래킹 중에도 정확히 스케줄대로 흐르게 했다. 이제 10초는 메뉴가 열려 있든 없든 실제
10초다.

## v1.6 — 노치 아이콘 클릭이 유예를 갱신 안 하던 문제
v1.5로도 재현됐다: `.notch`(먹히지 않고 그냥 가려지기만 한) 아이콘은 `press()`에서 `spit()`을
안 타고 바로 AXPress만 하는데, 이 경로는 `scheduleAutoEat()`을 다시 안 불렀다. 그래서 유예는
"바가 처음 열린 시점"부터 계속 흐르고 있었고, 사용자가 고르는 데 시간이 걸리면(30초로 늘려도
바 연 뒤부터 카운트라 무관하게) 클릭하는 순간 이미 유예가 끝나 있어 다음 4초 스캔에서 바로
eat()이 터졌다.
→ `.notch` 분기에서도 AXPress 전에 `scheduleAutoEat()`을 호출해서, 클릭한 그 순간부터 새
유예가 시작되도록 했다.

## 남은 것 (v1.1 후보)
전역 단축키, 사운드(와카와카), 조는/볼록해지는 애니메이션, 고스트 모드 — 기획서 4-2절.

## 릴리스

```sh
./scripts/release.sh v1.2.3 --notes-file notes.md
```

DMG 빌드 → GitHub 릴리스 생성 → [Snackbar](https://github.com/zzanggi-haki/snackbar) 사이트 갱신 신호까지 한 번에 한다.
릴리스 노트 첫 문단이 사이트 "최근 업데이트"에 요약으로 실린다. 웹에서 직접 릴리스를 만들면
신호가 안 가니 이 스크립트를 쓴다.
