# 앨범 페이지 종료(zoom pop) 애니메이션 정밀 분석

> 2026-10-22 최종 결정: 앨범 페이지 navigation zoom을 **완전히 제거**하고 기본
> `NavigationStack` push/pop으로 되돌렸다. `AlbumZoomDestination`,
> `.cassetteAlbumZoomNavigation()`, `AlbumDetailView`의 navigation
> `.cassetteZoomTransition`, `SwipeBackEnabler`, 커스텀 back을 제거했고 시스템
> back을 복원했다. 아래 zoom 수명/lifecycle 수정 설계는 이 결정으로 폐기되었다.
> 최종 변경은 `docs/fixes/2026-10-22-album-zoom-removed.md`를 참고한다.

## 1. 현상 분석

기기 녹화의 순서:

1. 앨범 페이지가 축소되기 시작한다.
2. 홈 화면이 보이지만 앨범 페이지가 비정상 위치로 이동한다.
3. 애니메이션 중 검은 직사각형이 나타난다.
4. 닫히던 앨범 페이지가 다시 전체 화면으로 돌아온다.
5. 정상 애니메이션 없이 갑자기 사라진다.

종료 애니메이션(zoom)을 제거하면 정상이라는 관찰은 **일반 데이터 로딩이나 앨범
콘텐츠 렌더링이 아니라 pop 전환 자체**가 문제라는 뜻이다. 다만 "zoom을 제거하면
정상"이라는 사실만으로 zoom 내부의 어느 단계가 원인인지는 확정되지 않는다.
아래에서 코드로 확인되는 사실과 아직 기기 로그가 필요한 가설을 구분한다.

## 2. 실행 경로

### 진입

1. `AdaptiveAlbumShelf` / `AlbumsListView` / `HomeView`의
   `AlbumNavigationLink(album:namespace:)`가 `NavigationLink(value:)`를 만든다.
2. `AlbumNavigationLink`는 `AlbumZoomDestination(id: routeID, album:,
   sourceID:, namespace:)`를 value로 사용한다.
3. 카드의 `CoverArtView`에
   `.cassetteMatchedTransitionSource(id: sourceID, in: namespace)`가 붙는다.
4. `cassetteAlbumZoomNavigation()`이 등록한 destination이
   `AlbumDetailView(album:zoomSourceId:zoomNamespace:)`를 만든다.
5. `AlbumDetailContentView` 마지막에
   `.cassetteZoomTransition(sourceID:in:)` →
   `.navigationTransition(.zoom(sourceID:in:))`가 적용된다.

### 종료

- 툴바 `<`: `AlbumDetailContentView`의 `dismiss()` → NavigationStack pop.
- 가장자리 스와이프: UIKit/SwiftUI의 interactive pop. 같은 zoom 전환을 사용하지만
  손가락 위치에 따라 소스 카드로 되돌아가는 **live source 추적**이 필요하다.
- `AlbumPresentationLifecycle`의 `AlbumPresentationController`가
  `viewWillDisappear`에서 로드만 suspend하고, 전환 완료 시 복귀/정리를 수행한다.

## 3. 근본 원인

### 확정된 코드 결함 1 — zoom 소스 ID가 카드 인스턴스 수명에 묶여 있었음

`AlbumNavigationLink`는 이전에 다음을 사용했다.

```swift
@State private var sourceID = UUID().uuidString
```

`matchedTransitionSource`의 ID와 destination의 `zoom(sourceID:)`는 이 값으로
연결된다. 그런데 앨범 페이지가 열린 동안 Home/Library가 갱신되어 카드가
재생성되면 `@State`가 초기화되어 **새 UUID**가 된다. 그러면 destination이 들고
있는 예전 source ID와 화면에 다시 만들어진 카드의 ID가 달라진다.

- 인터랙티브 pop은 소스 카드로 되돌아가며 위치를 추적하므로, 소스를 찾지 못하면
  잘못된 프레임으로 이동하거나 전환이 취소될 수 있다.
- 비인터랙티브(툴바) pop은 스냅샷 기반으로 완료될 수 있어 같은 증상이 항상
  나타나지 않을 수 있다. 이것이 "`<`는 정상, 스와이프는 깨짐"과 일치하는
  설명이지만, 기기 로그로 소스 소멸을 확인하기 전까지는 가설이다.
- DesignSystem README도 원래 `album.id`를 source ID로 사용하라고 문서화하고
  있었다. 실제 구현이 문서와 어긋나 있었다.

### 확정된 코드 결함 2 — 이전 수정이 zoom 도중 페이지 가시성을 변경했음

직전 구현의 `AlbumPresentationController`는 pop 완료/`viewDidDisappear`에서
`page.view.isHidden = true`를, 늦은 appearance에서 `isHidden = false`를 실행했다.

- SwiftUI zoom은 전환이 끝날 때까지 destination의 hosting view를 렌더링/스냅샷
  대상으로 사용한다. 그 표면을 전환 중에 숨기면 검은 프레임이 생길 수 있다.
- 이후 늦은 appearance가 `isHidden = false`로 되돌리면 페이지가 전체 화면으로
  다시 나타난 뒤, teardown이 끝나면서 갑자기 사라질 수 있다.
- 이 코드 경로는 이번 녹화의 3·4·5번 현상과 **직접적으로 일치**한다. 다만
  `viewDidDisappear`/coordinator 완료가 SwiftUI zoom 완료보다 먼저 오는지는
  기기 로그로 확인해야 한다.

### 아직 확정되지 않은 부분

- 검은 사각형이 (a) lifecycle이 숨긴 hosting view, (b) zoom 스냅샷 컨테이너의
  배경, (c) 소스 카드의 clip/placeholder 중 무엇인지.
- 스와이프 도중 카드가 실제로 재생성되었는지, namespace까지 바뀌었는지.
- `transitionCoordinator`의 completion이 SwiftUI zoom의 시각적 완료와 동일한
  시점인지.

## 4. 증거

- `AlbumNavigationLink.swift`: `@State sourceID = UUID().uuidString` (수정 전),
  현재 `sourceID = album.id`, `zoomEnabled`로 zoom 적용 여부를 분리.
- `NavigationTransitions+Cassette.swift`: `navigationTransition(.zoom(...))`,
  `matchedTransitionSource(...)`.
- `AlbumPresentationLifecycle.swift`: `isHidden = true/false` (수정 전).
- `AdaptiveAlbumShelf.swift`: `LazyHStack` + `ScrollView.clipped()` 안의 소스 카드.
  현재 기본 `zoomEnabled = false`로 기본 pop을 사용.
- `HomeView.swift` 최근 추가 grid: `album.id` + 페이지 소유 namespace로 zoom 유지.
- `AlbumsListView.swift`: 수정 전 모든 카드에 zoom을 강제했으나, 현재
  `zoomEnabled: false`로 원본과 동일하게 기본 pop.
- 원본(`CassetteLab/cassette` main `aed1663d`) 비교:
  - 수평 선반은 `CarouselAlbumCard`를 쓰고 `matchedTransitionSource`를 등록하지 않음.
  - `AlbumsListView`는 `NavigationLink(value: HomeDestination.album(album))`와
    source 없는 `AlbumGridCell`/`AlbumRow`를 사용.
  - zoom은 최근 추가 `HomeAlbumCell`, Discover grid, 컬렉션 grid 등
    `cassetteMatchedTransitionSource(id: album.id, in: namespace)`가 있는 곳에서만 사용.
  - `AlbumDetailView`는 `.navigationBarBackButtonHidden(true)` +
    `.enableSwipeBack()`을 사용하고, delegate가 `transitionCoordinator == nil`일
    때만 pop을 시작.
  - 원본에는 `AlbumPresentationLifecycle.swift`, `ChromeAppearance.swift`,
    `AdaptiveAlbumShelf.swift`가 없음 (로컬 추가분).
- 새 진단 로그:
  - `[ALBUM-ZOOM] source appear/disappear album= source= route= ns=`
  - `[ALBUM-ZOOM] destination appear album= source= ns=`
  - `[ALBUM-POP] willAppear/didAppear/willDisappear/didDisappear/transition-complete/interaction-end ... inStack= committed= window=`
  - `[ALBUM-POP] interaction-disabled/enabled ...`

## 5. 수정 설계 (적용)

최소 수정으로 두 결함을 분리했다.

1. **가시성 변경 제거** — `AlbumPresentationLifecycle.swift`
   - `isHidden`을 전혀 사용하지 않는다. `viewDidDisappear`/전환 완료/late
     appearance에서도 페이지를 숨기거나 다시 보이게 하지 않는다.
   - 스택에서 빠진 페이지만 `isUserInteractionEnabled = false`로 터치를 막는다.
   - 취소된 스와이프에서 다시 스택에 남아 있으면 `isUserInteractionEnabled = true`.
   - zoom의 렌더링 표면은 SwiftUI가 단독으로 소유한다.
2. **zoom 적용 범위를 원본과 일치시킴** — `AlbumNavigationLink.swift`,
   `AdaptiveAlbumShelf.swift`, `AlbumsListView.swift`
   - 원본(`CassetteLab/cassette` main `aed1663d`)은 수평 선반의
     `CarouselAlbumCard`와 Albums 목록에서 **matched transition source를 등록하지
     않고 기본 NavigationStack pop**을 사용한다. zoom은 최근 추가 grid,
     Discover의 source가 있는 grid, 컬렉션 grid처럼 안정적인 source가 있는
     곳에서만 사용한다.
   - `AlbumNavigationLink`에 `zoomEnabled`를 추가했다. `false`이면
     `NavigationLink(value: HomeDestination.album(album))`으로 push해 기본 pop을
     사용한다.
   - `AdaptiveAlbumShelf`의 기본값을 `zoomEnabled = false`로 두어 수평 선반
     (Dashboard/Discover)은 기본 pop을 사용한다.
   - `AlbumsListView`의 grid/list는 `zoomEnabled: false`로 원본과 동일하게 한다.
   - `HomeView`의 최근 추가 grid와 `AlbumShelfCollectionView`는 `album.id`를
     안정적인 source로 유지해 zoom을 보존한다.
3. **전환 중 새 pop 제스처 금지 (원본 `SwipeBackEnabler`)** —
   `SwipeBackEnabler.swift`, `AlbumDetailView.swift`
   - 원본의 `SwipeBackGestureDelegate`를 그대로 이식했다.
     `navigationController.viewControllers.count > 1`이고
     `transitionCoordinator == nil`일 때만 interactive pop을 시작한다.
   - push/pop이 아직 진행 중인데 두 번째 pop이 시작되어 stack이 꼬이는 경로를
     막는다. delegate는 화면이 사라질 때 원래 delegate로 복원된다.
   - `AlbumDetailView`도 원본처럼 시스템 back 버튼을 숨기고
     `.enableSwipeBack()`을 사용한다. 툴바의 chevron 버튼은 `isDismissing`으로
     첫 탭을 래치해 push/pop 중 두 번째 pop 요청을 막는다.
4. **완료된 pop에 대한 hard stop** — `AlbumPresentationLifecycle.swift`
   - `committedPop`을 추가했다. `viewDidDisappear`/non-cancelled completion에서
     페이지가 스택에 없으면 true가 되고, 이후 늦은 `viewWillAppear`/`viewDidAppear`는
     interaction 복원과 `resumeIfCurrent`(로드 재개)를 수행하지 못한다.
   - completion 시점에 스택 갱신이 늦는 경우를 위해 다음 main turn에서 한 번 더
     확인한다. push-over는 페이지가 스택에 남아 있으므로 hard stop되지 않는다.
   - 정상적인 취소는 `cancelled=true`이고 페이지가 스택에 남아 있으므로
     `committedPop`이 설정되지 않는다.
5. **진단 로그 추가** — 위 `[ALBUM-POP]`, `[ALBUM-ZOOM]` 로그로 다음을 확인한다.
   - `willAppear`/`didAppear`/`willDisappear`/`didDisappear`, `committed`, `inStack`,
     `top`, `window`, `cancelled`
   - 스와이프 도중 source 카드의 appear/disappear 및 source/namespace 값
   - lifecycle이 페이지를 숨기지 않는지(로그상 `interaction-disabled`만 존재)

## 6. 회귀 위험

- 수평 선반(Dashboard/Discover)과 Albums 목록에서 **zoom 종료 애니메이션이 사라지고
  기본 NavigationStack pop**으로 바뀐다. 이는 원본과 동일한 동작이지만, 로컬에서
  해당 화면의 zoom을 기대했다면 체감 차이가 있다. 최근 추가 grid와 컬렉션 grid의
  zoom은 유지된다.
- `album.id`를 source ID로 쓰므로 같은 grid 안에 같은 앨범 카드가 중복되면 소스가
  모호해질 수 있다. 현재 최근 추가/컬렉션 grid는 앨범을 한 번만 나열한다.
- `SwipeBackEnabler`는 화면이 보이는 동안 시스템 interactive pop delegate를
  교체한다. `dismantle`에서 원래 delegate로 복원하지만, 다른 화면이 같은 시점에
  delegate를 교체하는 경우 서로의 복원 순서를 확인해야 한다. (원본 구현과 동일)
- `committedPop`은 컨트롤러 수명 동안 유지된다. 같은 hosting controller가 재사용되는
  특수한 경로가 있다면 그 페이지는 다시 로드/터치되지 않을 수 있다. NavigationStack은
  목적지마다 새 host를 만들므로 일반 경로에서는 문제되지 않는다.
- lifecycle은 더 이상 유령 프레임을 숨기지 않는다. SwiftUI가 제거된 host를 계속
  그리는 OS 버그가 남아 있으면 시각적 잔상은 재발할 수 있다.
- `ChromeAppearance`의 root TabView 갱신 시점은 이번 수정에서 건드리지 않았다.
  실제 로그로 확인이 필요하다.
- 미니 플레이어/재생 상태와 페이지 로드 suspend/resume 로직은 변경하지 않았다.

## 7. 검증 계획

### 자동 검증 결과

- iOS `build-for-testing`(generic/platform=iOS) 성공, 경고/오류 없음.
- macOS `AlbumDetailOfflineTests` + `LyricsAndChromeRegressionTests` 44개 통과
  (이번 원본 정렬 수정 포함).
- 아이폰 16 Pro 실기기에서 `AlbumZoomDismissalTests` 7개 통과 (committedPop
  hard stop이 포함된 리비전). 원본 정렬 수정 후 마지막 기기 재실행은 iPhone 잠금
  때문에 시작되지 않았고, 동일 코드의 iOS 빌드는 별도로 검증했다.
  - `committedSwipeDisablesThePoppedPageAndBlocksLateReturn`
  - `cancelledReturnKeepsHostingViewVisibleAndPoppedPageInteractionDisabled`
  - `committedSwipeDisablesTheOutgoingPageBeforeTheZoomSettles`
  - `cancelledSwipeWaitsForSettlingBeforeResuming`
  - `pushOverKeepsThePageAliveForItsReturn`
  - 기존 chrome 수명 테스트 2개
- 테스트는 “pop 후 `isHidden`을 바꾸지 않는다”, “터치만 차단한다”, “취소된
  스와이프는 다시 활성화한다”, “push-over 페이지는 살아 있다”를 확인한다.

### 기기에서 추가 확인할 것

- 앨범 페이지를 열고 홈/선반이 갱신되는 동안 가장자리 스와이프로 닫는다.
  - `source disappear`가 pop 시작 전에 발생하는가?
  - 재생성 전후 `route`/`ns`가 동일한가? (`source`는 `album.id`로 동일해야 함)
  - `didDisappear` 시점의 `window` 값. `true`이면 아직 전환 표면이 살아 있다는 뜻.
  - `transition-complete`의 `cancelled` 값. `true`이면 pop이 취소된 뒤 재실행된 것.
- Xcode 콘솔에서 `ALBUM-POP` / `ALBUM-ZOOM`을 필터링하면 위 이벤트를 시간순으로
  얻을 수 있다. (subsystem `app.cassette.ui`)
- 검은 사각형이 계속되면 zoom을 제거하지 않고 다음을 개별 실험한다.
  1. `AlbumDetailContentView` 루트에 임시 불투명 배경/테두리를 주어 검은 영역이
     페이지 자체인지 스냅샷 배경인지 구분.
  2. 소스 카드의 `GeometryReader`를 고정 크기 프레임으로 바꾸어 소스 프레임
     변동을 제거.
  3. `.clipped()`가 걸린 shelf에서만 zoom을 끄고, 다른 화면에서는 유지.
- 실제 영상 프레임과 로그 타임스탬프를 대조해 3·4·5번 현상의 주체를 확정한다.

### 아직 검증하지 않은 것

- 실기기에서 새 빌드로 종료 애니메이션을 직접 촬영/확인하는 것.
- 검은 사각형의 정확한 렌더링 주체.
