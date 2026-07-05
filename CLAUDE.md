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

## 디버그 (CLI에서 실행 중인 앱 조작)
- 토글: DistributedNotification `com.zzanggi.pacmenu.toggle`
- 상태 덤프: `com.zzanggi.pacmenu.dump` → `/tmp/pacmenu-dump.txt`

## 남은 것 (v1.1 후보)
전역 단축키, 사운드(와카와카), 조는/볼록해지는 애니메이션, 고스트 모드 — 기획서 4-2절.
