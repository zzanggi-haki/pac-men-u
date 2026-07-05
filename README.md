<p align="center">
  <img src="docs/icon.png" width="128" alt="PAC-MEN-U icon">
</p>

<h1 align="center">PAC-MEN-U</h1>

<p align="center">
  맥 메뉴바 아이콘을 팩맨이 <b>먹었다 뱉었다</b> 하는 메뉴바 정리 앱<br>
  <i>A macOS menu bar organizer where a pixel pacman eats (hides) and spits out (shows) your menu bar icons.</i>
</p>

<p align="center">
  <img src="docs/menubar.png" alt="PAC-MEN-U in the menu bar">
</p>

## 사용법

- **팩맨 클릭** — 구분점(`⋮`) 왼쪽의 아이콘들을 챱챱 먹어서 숨깁니다. 다시 클릭하면 뱉어서 보여줍니다.
- **팩맨 우클릭** — "팩미의 뱃속": 숨겨진 메뉴들이 `[앱 아이콘] 이름` 리스트로 나오고, 클릭하면 그 메뉴가 열립니다.
- **⌘ + 드래그** — 메뉴바 아이콘을 `⋮` 왼쪽/오른쪽으로 옮겨서 먹힐 아이콘을 정합니다.

## 설정 (우클릭 → ⚙️)

| 설정 | 설명 |
|---|---|
| 로그인 시 자동 실행 | macOS 로그인 항목에 등록 |
| 먹은 상태 기억하기 | 재실행/재부팅 시 먹은 상태 그대로 복원 |
| 뱉은 뒤 자동으로 다시 먹기 | 끄기 / 30초 / 1분(기본) / 2분 / 5분 |

## 설치 / 빌드

```sh
./build.sh        # swiftc 빌드 → 서명 → /Applications 설치
open /Applications/PAC-MEN-U.app
```

- macOS 13+, 별도 의존성 없음 (Swift 단일 파일, `main.swift`)
- 서명 identity는 `build.sh`에서 본인 인증서로 바꿔주세요 (ad-hoc `-s -`도 되지만 재빌드마다 아래 권한을 다시 켜야 합니다)

### 권한

뱃속 리스트(숨긴 메뉴 이름 읽기/클릭 전달)에 **손쉬운 사용(Accessibility)** 권한이 필요합니다.
시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 PAC-MEN-U를 켜주세요.
권한 없이도 먹기/뱉기 자체는 동작합니다.

## 동작 원리

- 숨김은 구분자 `NSStatusItem`의 length를 10,000pt로 확장해 왼쪽 아이콘들을 화면 밖으로 밀어내는 방식 (Hidden Bar와 같은 트릭, 프라이빗 API 없음)
- 뱃속 리스트는 Accessibility API로 각 앱의 메뉴바 아이템 이름/위치를 읽고, 클릭 시 `AXPress`를 전달
- 팩맨은 12×12 도트 그리드를 코드로 그린 템플릿 이미지 — 다크/라이트 메뉴바 톤을 시스템이 자동으로 맞춰줍니다

---

*"맥에서 쓰는 간단한 앱 20개 만들기" 프로젝트의 1호입니다.* 🕹️
