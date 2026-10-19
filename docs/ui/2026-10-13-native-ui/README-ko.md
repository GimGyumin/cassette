# Cassette 네이티브 UI 전환 및 백그라운드 커버 다운로드

> 후속 사용자 요청으로 슬라이더 및 상단 처리 일부가 변경되었다. 아래 내용은 최초 전환 기록이며, 현재 슬라이더/스크롤 정책은 [복원 및 soft 상단 효과 기록](slider-and-soft-edge-followup.md)을 우선한다.

2026-10-13 작업. 기존 작업 트리의 변경을 유지한 상태에서 실제 코드를 수정했다. 시뮬레이터는 실행하거나 빌드 대상으로 사용하지 않았다.

## 조사 범위와 우선순위

`Cassette/Views`, `Cassette/DesignSystem`의 Swift 파일 238개를 검색하고, 앱 진입점·공유 컴포넌트·탭·상세 화면·설정·플레이어 및 관련 다운로드 서비스를 추적했다. [component-index.tsv](component-index.tsv)는 파일별 시스템 API, 표시 계층, 커스텀 그리기/제스처의 위치를 기록한 정적 인덱스다. 정적 인덱스와 자동 테스트는 실제 iOS 화면 검증을 대신하지 않는다.

우선순위는 ① 백그라운드 전송 중단과 홈 상단 문제 ② 탭 액세서리/검색의 시스템 소유권 ③ 설정·재생 컨트롤·목록 인덱스 ④ 중복 장식과 접근성 순으로 정했다.

| 영역 | 기존 구성 | 실제 조치 |
| --- | --- | --- |
| 앱 탐색 | 탭별 `NavigationStack`과 `NavigationPath`, macOS `NavigationSplitView` | 이미 시스템 구현. 경로와 상세 destination 등록 구조 유지 |
| 하단 탭 | `TabView`, 검색 역할 `Tab`, iPad `.sidebarAdaptable` | 시스템 탭 유지. 커스텀 탭 바로 교체하지 않음 |
| 홈 상단 | `.navigationTitle` + `.inlineLarge` 프로필 툴바, 자동 배경/축소 제목 | 홈 루트에서만 스크롤 시 기본 제목 제거, 내비게이션 배경 및 상단 경계 효과 숨김 |
| 홈/찾아보기 프로필 | 공유 `AccountProfileToolbar` | 시스템 `ToolbarItem`/`Button`/`sheet` 유지. 프로필 표시 변경으로 콘텐츠 트리가 교체되던 분기 제거 |
| 검색 | 직접 만든 TextField·가짜 음성 검색 버튼·지우기/취소·고정 34pt 제목·계정 시트 | `searchable`, `searchFocused`, 기본 제목 및 공통 프로필 툴바로 교체 |
| 검색 분류 필터 | 가로 스크롤 Glass 캡슐 선택 버튼 | 메뉴형 `Picker`로 교체. 검색 범위는 기존 시스템 segmented Picker 유지 |
| 라이브러리 | List와 앨범 LazyVGrid, 기본 검색 drawer, Menu 필터 | 적절한 기존 시스템 컨테이너 유지 |
| 알파벳 탐색 | 직접 그린 글자 열, 위치→글자 계산, haptic/drag 관리 | iOS 26 이상 아티스트·곡·앨범 목록에 `sectionIndexLabel`/`listSectionIndexVisibility` 사용 |
| 설정 값 | HStack + Spacer + 한 줄 잘림 | 기본 `LabeledContent` 사용. 커스텀 LabeledContentStyle 제거 |
| 설정 단일 선택 | Button마다 직접 checkmark/선택 접근성 관리 | Form 안의 inline `Picker` 사용. 설정 모델/Binding 그대로 유지 |
| 설정 스위치/수치 | `Toggle`, `Slider`, `Form` | 이미 시스템 구현. 유지 |
| 툴바 아이콘 | 시스템 ToolbarItem 안에 추가 30pt Glass 원 | 아이콘만 제공하고 배경·터치 피드백은 툴바가 처리 |
| 주요 CTA | 커스텀 ButtonStyle의 Glass/opacity/pressed 처리 | `.glassProminent`, 구형 시스템 `.borderedProminent` |
| 빈 화면/오류 | 아이콘·제목·설명을 직접 배치한 VStack | `ContentUnavailableView`와 시스템 Button |
| 팝업/메뉴 | `Menu`, `contextMenu`, `confirmationDialog`, `alert` | 시스템 구현 유지. 전역 UIAlertController UIAppearance 재정의와 경고용 투명 배경 호스트 제거 |
| 계정/편집 시트 | 시스템 sheet + 계정 시트 반경 28 강제 | sheet/detent/닫기 기능 유지. 강제 반경 제거 |
| 미니 플레이어 | iPhone 시스템 accessory, iPad 별도 부유 캡슐, 중복 바닥 여백 | iPhone/iPad 모두 공식 accessory. iOS 26.1 이상 `isEnabled`로 재생 항목이 없을 때 공간 제거 |
| 미니 플레이어 장식 | 시스템 Glass 위의 색상 캡슐, iPad 이중 Glass/테두리/그림자 | 시스템 accessory에서는 제거. 색상은 기본 semantic 색상 사용 |
| 미니 플레이어 진행률 | GeometryReader로 폭을 직접 계산한 막대 | 선형 `ProgressView` |
| 재생 위치 | Capsule/GeometryReader/DragGesture로 구현한 slider | 시스템 `Slider`. 기존 seek Binding, seek 세대/트랙 동일성 검사는 유지 |
| iOS 시스템 음량 | 커스텀 slider + KVO + 거의 투명한 MPVolumeView의 UISlider 탐색 | 화면에 표시되는 공식 `MPVolumeView`로 교체 |
| AirPlay | 투명 AVRoutePickerView 위에 직접 만든 아이콘, 내부 subview 변경 | 공식 `AVRoutePickerView`를 그대로 표시. 기존 열림/닫힘 알림과 출력 장치 이름 유지 |
| 로딩 | 기본 ProgressView + 음악 카드 skeleton | ProgressView 유지. 설정의 scaleEffect 대신 controlSize 사용 |
| 전체 플레이어/가사 | 앨범 아트, 음악 배경, 가사 타이밍, 큐와 전용 제스처 | 음악 기능에 필요한 구성 유지. 하단 버튼 및 미니 플레이어 사용자 애니메이션에 Reduce Motion 반영 |

## 홈 상단 원인과 수정

`MainTabView → NavigationStack → DashboardHomeView(ScrollView)`에서 홈의 navigation title과 프로필 ToolbarItem은 시스템 내비게이션 바에 있다. 홈에는 별도의 검은 헤더 View가 없었다. 스크롤 후 보이는 축소 제목과 어두운 배경은 자동 내비게이션 바 표시와 상단 scroll-edge 효과에 해당한다. 앨범 상세의 `StatusBarScrim`은 이 홈 계층에 적용되지 않는다.

`AccountProfileToolbar.swift`의 `HomeNavigationChrome`을 **DashboardHomeView에만** 적용했다.

- 실제 `contentOffset.y + contentInsets.top`이 0보다 큰지 관찰한다. 매 픽셀을 저장하지 않고 Bool 변경만 게시한다.
- 맨 위에서는 `.inlineLarge` 제목과 trailing 프로필 버튼을 시스템이 같은 줄에 배치한다.
- 스크롤한 동안 `.toolbar(removing: .title)`로 기본 작은 제목을 제거한다. 빈 제목 문자열, 빈 Text, 수동 Y offset을 사용하지 않았다.
- `.toolbarBackgroundVisibility(.hidden, for: .navigationBar)` 및 공유 `cassetteHideTopScrollEdgeEffect()`를 적용한다.
- NavigationStack/내비게이션 바의 safe area와 프로필 버튼은 유지한다. 상태 표시줄 영역을 침범하는 `ignoresSafeArea`는 추가하지 않았다.
- 앨범·아티스트·플레이리스트 상세에는 이 설정을 적용하지 않았다. 기본 뒤로 가기와 경로 수명은 유지한다.

Apple 공식 문서에서 [기본 툴바 항목 제거](https://developer.apple.com/documentation/swiftui/view/toolbar(removing:))와 [title 항목](https://developer.apple.com/documentation/swiftui/toolbardefaultitemkind/title)을 확인하고, 설치된 SDK 선언과 기기 대상 컴파일로 가용성을 검증했다. 작은 제목을 따로 재현하는 커스텀 헤더는 추가하지 않았다.

**Apple Music과의 비교 범위:** 사용자가 설명한 “상단에서는 큰 제목/프로필, 스크롤 뒤에는 작은 홈 제목과 별도 막대 없음”을 목표로 구성했다. Apple Music을 실제 기기에서 나란히 조작해 전환 임계점이나 애니메이션을 비교한 것은 아니다. 이 구현은 스크롤 원점을 벗어나면 제목 항목을 제거하므로 Apple Music 내부의 타이밍과 같다고 단정할 수 없다.

## 탭과 미니 플레이어

공식 [tabViewBottomAccessory](https://developer.apple.com/documentation/swiftui/view/tabviewbottomaccessory(isenabled:content:))가 하단 공간과 최소화 전환을 관리하도록 했다. iPad도 같은 API를 사용하며, 넓은 레이아웃의 가사·대기열 버튼은 유지했다. `.tabViewBottomAccessoryPlacement`에 따라 축소형 표시를 선택한다.

세 갈래에 반복되던 FullPlayer fullScreenCover를 한 곳으로 통합했다. 재생 여부가 달라져도 TabView 자체를 다른 조건부 계층으로 바꾸지 않아 탭별 경로가 보존된다. iOS에서 고정 `miniPlayerBottomMargin`과 하단 scroll-edge 숨김을 제거했다. 기존 safeAreaInset/accessory와 두 번 공간을 예약하던 문제 및 Search의 중복 modifier 호출을 정리했다. macOS의 별도 하단 플레이어 레이아웃에는 기존 여백을 유지한다.

## 백그라운드 커버 다운로드 원인과 수정

두 원인이 있었다.

1. 앞선 수정의 `hasPlaybackIntent` 대기 조건에 정상 `.playing`도 포함되어, 곡이 재생 중이면 커버 작업이 무기한 대기했다. 이를 `.loading/.buffering/.recovering`인 `isAwaitingAudio`로 한정했다.
2. 기존 코드는 소수 파일을 예약한 뒤 각각 끝날 때 Swift task가 다음 파일을 예약했다. 앱이 suspend되면 이 반복문도 중단되므로 URLSession이 전체 남은 목록을 알지 못했다.

누락된 원본 커버 목록을 `URLSessionConfiguration.background`의 download task로 먼저 등록한다. 소수의 Swift 작업은 진행률을 관찰하며, 실제 다음 전송 예약은 앱 프로세스의 실행 여부에 의존하지 않는다. 이는 Apple의 [백그라운드 다운로드 지침](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)이 권장하는 여러 다운로드 작업의 사전 등록 방식이다.

- 앨범/트랙 공통 커버의 기존 identity 중복 제거 및 계정별 저장 경로를 유지한다.
- 파일명 기반 작업 레지스트리로 중복 등록을 막고, 재실행 시 기존 URLSession 작업을 복구한다.
- 진행률 관찰자가 늦게 붙으면 이미 등록한 작업에 연결하거나 완성된 파일을 반환한다. delegate와 동일한 lock을 사용해 완료/관찰자 등록 사이의 경합을 막는다.
- Swift continuation이 없어도 delegate가 검증된 이미지를 최종 위치에 원자적으로 저장한다.
- 작업 목록을 넘기는 짧은 구간에만 `beginBackgroundTask` 실행 시간을 요청하고 종료/만료 시 해제한다. 장시간 실행 권한으로 다운로드를 유지하려 하지 않는다.
- 커버 세션은 낮은 우선순위와 호스트당 연결 1개로 설정한다. 음악 세션과 분리하고 기존 Wi-Fi 정책을 유지한다. HTTP/2와 실제 대역폭 배분은 URLSession/서버가 관리하므로 연결 제한이 대역폭 보장을 의미하지 않는다.
- 계정 초기화 시 등록 작업과 레지스트리를 함께 취소/제거한다.

아직 예약되지 않은 목록의 discovery가 OS 실행 시간 안에 끝나지 않으면 기존 BGProcessing 재개 경로를 사용한다. iOS는 앱 실행/네트워크/전력 상태에 따라 작업을 지연할 수 있다. 사용자의 강제 종료 후 자동 전송 재개도 보장하지 않는다. 코드 변경으로 중단 원인을 제거했지만 실제 기기의 suspend·잠금·재실행 실험은 아직 하지 않았다.

## 유지한 커스텀 구성과 이유

- **가로 앨범 선반/그리드:** ScrollView/LazyVGrid 자체가 적합한 공식 컨테이너다. List로 강제 변경하면 음악 탐색 구성이 바뀐다.
- **앨범·아티스트·플레이리스트 상세의 커버 배경/스크롤 테마:** 음악 앱의 디자인 정체성과 아트 위 글자 대비를 위한 것이다. 관련 scrim/blur를 홈 막대 문제와 혼동해 제거하지 않았다.
- **전체 플레이어·동기 가사·번역·큐:** 대체 가능한 단일 시스템 플레이어 컴포넌트가 없고 앱의 커스텀 엔진/가사 동기화가 필요하다. 표시 컨테이너는 기존 fullScreenCover/sheet 및 zoom transition을 사용한다.
- **곡 넘기기 제스처, 가사 탐색, 이미지 정사각형 crop, Wrapped story:** 고유 기능이다. 표준 제스처와 충돌하지 않는지 실기기 확인은 별도 필요하다.
- **Toast/now-playing 막대/skeleton:** 동일한 의미와 동작을 제공하는 공개 시스템 컨트롤이 없거나 콘텐츠 로딩 레이아웃을 유지하기 위한 표현이다. 일반 로딩은 ProgressView를 사용한다.
- **구형 iOS/macOS 알파벳 jump bar:** iOS List 인덱스 API가 없는 환경의 기능을 보존한다.
- **UIKit 브리지:** MPVolumeView, AVRoutePickerView, 공유/사진 선택기, 상태 표시줄 대비, 탭 재선택 관찰, Metal 가사 표면 등 SwiftUI만으로 기존 기능을 대체하기 어려운 부분만 유지했다. 음량과 AirPlay의 내부 subview 조작은 제거했다.
- **음악 전용 버튼/패널 장식:** 커버 위의 대비가 필요한 버튼은 유지했다. 시스템 툴바·시트·탭 액세서리에 겹치던 장식을 우선 제거했다. iOS 26 미만에는 가용한 시스템 material/버튼 fallback을 둔다.

## 주요 수정 파일

| 파일 | 변경 |
| --- | --- |
| `DesignSystem/Components/AccountProfileToolbar.swift`, `Views/Main/DashboardHomeView.swift` | 홈 루트 스크롤/제목 정책, 계정 툴바 수명 안정화 |
| `Views/Main/MainTabView.swift`, `MiniPlayerAccessoryView.swift`, `DesignSystem/Components/MiniPlayerBottomMargin.swift` | 공식 하단 액세서리, 중복 표시/여백/장식 제거 |
| `Views/Main/SearchTabContent.swift`, `DesignSystem/Components/AppleMusicSearchBar.swift` | 시스템 검색 전환. 후자는 기존 library searchable helper만 유지 |
| `Views/Settings/SettingsComponents.swift` | LabeledContent/Picker 및 기본 접근성·값 레이아웃 |
| `DesignSystem/Components/AlphabetJumpBar.swift`, `Views/Browse/ArtistListView.swift`, `SongsListView.swift`, `AlbumsListView.swift` | 공식 목록 인덱스와 공통 fallback |
| `DesignSystem/Components/CircleToolbarLabel.swift`, `GlassButtonModifier.swift`, `EmptyStateView.swift` | 시스템 툴바/CTA/빈 화면 |
| `DesignSystem/CassetteSystemChrome.swift`, `App/CassetteApp.swift`, `CassetteAppDelegate.swift` | 전역 alert 외형 강제 설정 제거 |
| `Views/Main/Player/PlayerTransportControls.swift`, `PlayerBottomControls.swift`, `DesignSystem/Components/SystemVolumeView.swift` | 시스템 재생 slider·음량·출력 장치 UI |
| `Views/Platform/macOS/BottomPlayerBar.swift`, `MiniPlayerWindowView.swift`, `FullPlayerExpandedView.swift` | 공통 slider 호출 정리, macOS control size 유지 |
| `Services/Implementations/AlbumCoverPreloadService.swift`, `ArtworkImageCache.swift`, `CassetteBackgroundDownloads.swift` | 정상 재생 중 전송, 백그라운드 전체 목록 인계·복구·중복 방지 |
| `CassetteTests/ArtworkDownloadPolicyTests.swift`, `BackgroundArtworkQueueTests.swift` | 정상 재생 중 다운로드 및 로컬 HTTP 전체 배치/중복/완료 관찰 테스트 추가 |

## 삭제/통합한 중복 구현

커스텀 검색 TextField와 포커스 토큰·지우기/취소/음성 아이콘, 검색 전용 계정 시트와 헤더, 검색 필터 캡슐, 설정 선택 checkmark 행/커스텀 LabeledContentStyle, 커스텀 주요 CTA ButtonStyle, 전역 UIAlertController appearance, 음량 KVO/숨긴 MPVolumeView/내부 UISlider 탐색, 숨긴 AirPlay 아이콘/subview 조작, 진행 slider의 직접 그리기/drag 상태, 미니 플레이어의 중복 fullScreenCover와 바닥 여백, 시스템 Glass 위 추가 캡슐/테두리/그림자를 제거하거나 통합했다.

## SDK 및 검증

설치된 Xcode beta의 iOS 27.2 / macOS 27.2 SDK를 사용했다. 앱 최소 지원 버전은 iOS 18.6 / macOS 15.6이다. SDK의 SwiftUI swiftinterface와 실제 컴파일에서 아래 가용성을 확인했다.

| API | 적용 조건 |
| --- | --- |
| `NavigationStack`, toolbar, sheet, searchable, Slider, Picker, Form | 기존 최소 지원 범위에서 사용 |
| `toolbar(removing: .title)`, `toolbarBackgroundVisibility`, `onScrollGeometryChange`, `searchFocused` | iOS 18 이상 |
| `scrollEdgeEffectHidden`, `tabViewBottomAccessory`, `sectionIndexLabel`, `listSectionIndexVisibility`, glassProminent | iOS 26 이상; 목록 index visibility는 macOS 미지원 |
| `tabViewBottomAccessory(isEnabled:content:)` | iOS 26.1 이상 |
| MPVolumeView, AVRoutePickerView | 공개 UIKit/MediaPlayer/AVKit API; 내부 view 탐색 제거 |

최종 검증 결과와 재현 명령은 [verification-results.txt](verification-results.txt) 및 `*-results.json`에 기록했다. 테스트를 삭제하거나 기대값을 완화하지 않았다. 새 두 테스트는 실제 다운로드 요청 수/파일 내용과 완료 상태를 검사한다.

| 검증 | 정확한 결과 |
| --- | --- |
| iOS Generic Device 최종 빌드 | `BUILD SUCCEEDED`, 컴파일 오류 0 / 경고 0, 서명·설치 없음 |
| macOS 확대 회귀 | [178/178 통과](mac-regression-results.json), 실패 0 / 생략 0; 매개변수 조합 포함 실행 193건 |
| 최종 검색 수정 후 재검증 | [25/25 통과](mac-search-results.json), 실패 0 / 생략 0; 확대 회귀와 중복되는 검색 테스트 |
| Crossfade·prefetch·Gapless 조건 | [34/34 통과](mac-crossfade-results.json), 실패 0 / 생략 0 |
| 변경 공백 검사 | `git diff --check` 통과 |

확대 회귀에는 커버 원본/중복/정상 재생 중 전송, background payload 복구, 실제 로컬 HTTP 전체 배치, 오류 난 AudioStreaming 인스턴스 뒤의 연속 정상 곡 재생, Gapless 시간 연속성, seek, 요청 취소, 오프라인 앨범/플레이리스트, 계정 격리, 검색 debounce/페이지/인덱스, 가사 추적·seek·번역 세션 검증을 포함했다. macOS에서 실행한 재사용 카드 캡처는 iOS 홈 내비게이션의 시각 검증으로 계산하지 않았다.

## 실기기에서 확인해야 할 항목과 남은 제한

1. 홈의 초기 큰 제목/프로필 정렬, 스크롤/바운스/당겨서 새로고침 시 제목 전환, 상태 표시줄 및 Dynamic Island 겹침 여부, 상세 화면 push/pop 후 원상 복구.
2. iPhone/iPad의 탭 최소화와 액세서리 배치, split view/회전, 검색 키보드와 미니 플레이어, 재생 항목이 없을 때 공간. iOS 26.0 fallback에는 isEnabled API가 없어 26.1 이상과 표시 타이밍이 다를 수 있다.
3. 최대 Dynamic Type, VoiceOver focus/adjustable action, Reduce Motion/Reduce Transparency, 밝은/어두운 앨범 화면의 Glass 대비.
4. 실제 MPVolumeView 드래그·하드웨어 음량 버튼·Bluetooth/AirPlay 출력 전환. 자동 테스트는 물리 음량과 외부 장치를 검증하지 않는다.
5. Wi-Fi에서 커버 준비를 시작한 후 홈 버튼/잠금으로 배경 이동, 다수 커버 저장, 앱 재진입, 시스템 종료 후 복구, Wi-Fi 이탈과 계정 변경. macOS HTTP 테스트는 iOS background daemon 스케줄링을 검증한 것이 아니다.
6. 실제 서버의 장시간 재생, 오류 후 다음 곡, Gapless/Crossfade, 음악 재생 중 대량 커버 다운로드의 대역폭 경합. 자동 재생 회귀는 통과 여부를 별도 기록하며 실제 서버 네트워크 품질을 보장하지 않는다.
7. 동일 커버라는 증거가 없는 서로 다른 opaque 서버 ID는 무조건 합치지 않는다. 기존 구현은 동일 ID 및 Navidrome 콘텐츠 해시가 같은 앨범/곡을 공유하고, 다른 콘텐츠 해시의 트랙은 별도 저장한다.

현재 남은 핵심 검증은 위 실기기 항목이다. Apple Music과 완전히 같은 전환/외형 또는 모든 iOS 실행 상태에서 즉시 다운로드 완료를 검증했다고 주장하지 않는다.
