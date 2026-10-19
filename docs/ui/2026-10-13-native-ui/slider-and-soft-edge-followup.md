# 슬라이더 복원 및 사진 기준 상단 처리

## 추가 요청: 검색창 유지와 루트 헤더 스크롤 (2026-10-14)

이 추가 요청이 아래 초기 상단 정책보다 우선한다. 검색은 `.navigationBarDrawer(displayMode: .always)`로 고정하고 검색 탭에서는 탭 바 최소화를 끈다. Apple의 [always 문서](https://developer.apple.com/documentation/swiftui/searchfieldplacement/navigationbardrawerdisplaymode/always)는 스크롤 여부에 관계없는 검색창 표시를 명시한다.

홈·발견하기·보관함에는 공통 `cassetteScrollingRootHeader`를 적용했다. 콘텐츠가 맨 위를 벗어나면 기본 제목과 모든 루트 툴바 항목(프로필, 추가, 메뉴, 편집 완료)을 함께 제거하고, 맨 위로 돌아오면 복원한다. 버튼만 투명하게 만들어 Glass 배경이나 보이지 않는 터치 영역을 남기지 않는다. NavigationStack과 safe area는 유지하고, `.soft` 효과를 끄거나 상세 화면의 뒤로 가기 버튼을 숨기지 않는다. 검색 화면에는 이 헤더 숨김 정책을 적용하지 않는다.

검증: iOS Generic Device 빌드 성공, macOS 검색 회귀 25개 통과, 컴파일 오류/경고 0, `git diff --check` 통과. 로그는 `/tmp/cassette-root-scroll-search-ios.log`, `/tmp/cassette-root-scroll-search-mac.log`. 시뮬레이터는 사용하지 않았으며 실기기 스크롤·헤더 전환의 시각 검증은 하지 않았다.

## 앞선 슬라이더 복원 기록

사용자 후속 요청에 따라 다음을 실제 코드에 반영했다.

- `ProgressSlider`를 기존의 얇은 캡슐/드래그 시 두꺼워지는 디자인과 제스처로 복원했다. iOS 전체 플레이어 및 이를 공유하는 macOS 플레이어의 설정값도 복원했다. 현재 seek 작업의 세대 검사와 트랙 변경 보호는 유지했다.
- `SystemVolumeView`를 이전 디자인과 상대 드래그 방식으로 복원했다. 하드웨어 음량 관찰과 기존 MPVolumeView 연결 방식도 복원했다.
- 미니 플레이어 진행률 표시도 기존 3pt 캡슐 막대로 복원했다.
- 보관함은 `.inlineLarge`와 기존 `ToolbarItemGroup`을 유지하고 `ToolbarSpacer(.fixed, placement: .topBarTrailing)`로 프로필을 명시적으로 분리했다. 홈·찾아보기·검색 역시 공통 시스템 제목/프로필 툴바를 사용한다. 프로필 아이콘을 임의의 인물 사진이나 Memoji로 교체하지 않았다.
- 홈에서 scroll offset에 따라 title을 제거하던 별도 상태와 강제 투명 내비게이션 배경 설정을 제거했다. 제목/버튼의 스크롤 동작은 시스템에 맡긴다.
- iOS 26 이상 루트 탭, 앨범·아티스트·곡 목록 및 앨범·아티스트·플레이리스트·아티스트 정보 화면에 `.scrollEdgeEffectStyle(.soft, for: .top)`을 적용하고 top edge 숨김을 해제했다.
- 현대 시스템에서 상세 화면의 고정 검은 gradient/shadow scrim과 스크롤량에 따른 수동 내비게이션 색상 덮기를 제거했다. 구형 시스템의 대비 fallback과 상태 표시줄 글자 색상 처리는 유지했다. 전용 가사 화면의 경계 효과 정책은 변경하지 않았다.
- 커버 다운로드·재생 엔진·오류 복구 코드는 이번 복원에서 변경하지 않았다.

공식 [Scroll Edge Effect API](https://developer.apple.com/documentation/swiftui/view/scrolledgeeffectstyle(_:for:))와 [ToolbarSpacer](https://developer.apple.com/documentation/swiftui/toolbarspacer)의 SDK 가용성을 확인했다. `.soft`는 시스템이 콘텐츠와 주변 UI에 맞춰 결정하는 효과이며, 검은색 농도나 Apple Music의 전체 헤더 퇴장 타이밍을 픽셀 단위로 복제한 것은 아니다.

슬라이더 구조와 음량 파일은 전환 이전 구현과 일치하는지 비교했다. 시뮬레이터는 사용하지 않았다. macOS 회귀 테스트는 29/29 통과했다(매개변수 조합 포함 실행 34건, 실패/생략 0). 실기기에서 사진과의 시각 비교, 스크롤/뒤로 가기, 실제 음량 드래그는 아직 확인하지 않았다.

최종 iOS Generic Device 및 macOS 빌드 모두 `BUILD SUCCEEDED`(컴파일 오류/경고 0). `git diff --check`도 통과했다. 로그는 `/tmp/cassette-slider-soft-edge-ios-final.log`, `/tmp/cassette-slider-soft-edge-mac-final.log`, `/tmp/cassette-slider-soft-edge-mac.log`에 있다.
