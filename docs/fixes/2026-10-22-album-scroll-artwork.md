# Apple Music 스타일 앨범 스크롤 아트워크

## 목표

몰입형(`.faded`) 앨범 페이지에서 스크롤 위치에 직접 연동되는 아트워크
블러·페이드를 구현한다. 제목, 아티스트, 메타데이터, 버튼, 트랙 목록은
블러/페이드 대상이 아니며 기존 레이아웃 그대로 스크롤된다.

## 구현

### 스크롤 진행도

`ScrollLinkedFadedArtworkHero`가 앨범 헤더의 위치를 기존
`albumDetailScroll` 좌표 공간에서 읽는다.

- 헤더 프레임의 `minY`를 그대로 스크롤 거리로 사용한다. 이 좌표 공간은
  기존 `AlbumScrollOffsetKey`와 동일하며 정지 상태에서 0이다.
- 헤더 폭을 기준으로 임계값을 스케일한다.
  - 390pt 기준 블러: `smoothstep(90, 240, scrollY)`
  - 390pt 기준 페이드: `smoothstep(170, 310, scrollY)`
  - iPad/작은 화면은 `width / 390` 비율로 같은 지점을 맞춘다.
- `onChange`로 상태를 직접 갱신한다. `withAnimation`, `DispatchQueue`,
  지연 타이머를 사용하지 않는다.
- 진행 상태는 헤더 내부 `@State`에만 있어 트랙 목록 전체 body가 매 프레임
  재평가되지 않는다.
- 커버 id가 바뀌면 헤더에 `.id(albumCoverId)`를 적용해 이전 앨범의 스크롤
  진행 상태가 남지 않게 한다.

### 블러·페이드

`FadedArtworkHero`에 `artworkBlurProgress`/`artworkFadeProgress`를 추가했다.

- **방식 B**: 동일한 아트워크 두 레이어를 겹친다.
  - 선명한 레이어 opacity: `1 - blurProgress`
  - 고정 반경(390pt 기준 28pt, 화면 폭에 비례) 블러 레이어 opacity:
    `blurProgress`
  - 두 레이어는 같은 이미지 소스, 프레임, 마스크, 스케일, 오프셋을 쓴다.
- 아트워크/컬러 배경을 하나의 그룹으로 묶어 `1 - fadeProgress` opacity를
  적용한다.
- 제목/버튼 뒤의 어두운 그라데이션은 **그 그룹 밖**에 두어 스크롤로
  아트워크가 사라진 뒤에도 유지된다. 제목/버튼이 배경의 밝기 변화에 따라
  대비를 잃던 문제를 막는다.
- 제목/버튼/설명은 배경 그룹 밖에 있어 블러/페이드의 영향을 받지 않는다.
- `Reduce Motion`이면 블러를 0으로 하고 페이드만 스크롤에 연동한다.

### 이미지/성능

- `initialImage`가 있으면 두 레이어 모두 이미 디코딩된 `Image`를 사용하고,
  없을 때만 기존 `CoverArtView` 캐시 경로를 사용한다.
- 블러 반경은 스크롤에 따라 변하지 않으므로 정적 블러 레이어를 재사용한다.
- 스크롤마다 이미지 요청/디코딩을 하지 않는다.
- 헤더 상태 갱신은 작은 wrapper에 격리되어 트랙 목록과 NavigationStack을
  건드리지 않는다.

## 탭 바 / 미니 플레이어

현재 Cassette는 이미 iOS 26 시스템 API를 사용하고 있다.

- `.tabBarMinimizeBehavior(.onScrollDown)` (`MainTabView`)
- `.tabViewBottomAccessory(isEnabled:)`
- `@Environment(\.tabViewBottomAccessoryPlacement)` + `MiniPlayerAccessoryView`
- `Tab(role: .search)`

따라서 탭 바 축소/미니 플레이어 인라인 전환은 별도 커스텀 스크롤
애니메이션 없이 시스템 동작을 유지한다. 스크린샷과 Cassette의 탭 구성은
다를 수 있지만(현재 Home/Discover/Library/Search 4개), 축소 표현은 시스템이
담당한다.

## 네비게이션 안정성

- `NavigationStack` 경로, `AlbumPresentationLifecycle`, 기본 push/pop,
  기존 zoom transition을 변경하지 않았다.
- 스크롤 진행 상태는 헤더 로컬 상태이며 네비게이션 상태를 변경하지 않는다.
- `AlbumScrollOffsetKey` 기반의 기존 `navChromeProgress` 경계 업데이트도
  그대로 둔다.
- UIKit 커스텀 전환, UIWindow 오버레이, matchedGeometryEffect를 추가하지
  않았다.

## 파일

- `Cassette/Views/Browse/AlbumDetailView+ScrollArtwork.swift`
- `Cassette/DesignSystem/Theming/FadedArtworkHero.swift`
- `Cassette/Views/Browse/AlbumDetailView+Header.swift`
- `Cassette/Views/Browse/AlbumDetailView+Layout.swift`
- `CassetteTests/AlbumScrollProgressTests.swift`

## 검증

- iOS `build-for-testing`: `EXIT:0`
- macOS `AlbumScrollProgressTests` + `AlbumDetailOfflineTests` +
  `LyricsAndChromeRegressionTests`: 45개 통과 (`TEST SUCCEEDED`)
- `ArtworkPresentationTests`의 분석 테스트는 별도로 통과했으며, 이 Mac
  환경의 `ImageRenderer` 렌더 테스트는 무관한 Dolby 렌더 테스트까지 함께
  실패해 시각 검증에는 사용하지 않았다.
- 실제 iPhone 16 Pro에서 느린 스크롤, 빠른 플링, 역방향 스크롤, 관성 중
  정지, 닫기/재진입을 확인해야 한다.

## 남는 시각적 차이

- 상단 Safe Area는 기존 `topColor` 확장을 유지한다. 커버의 실제 픽셀을
  상태 바 뒤까지 늘리는 대신, 상단 에지에서 추출한 색으로 이어 붙인다.
- 스크린샷의 스크롤 인디케이터는 기존 Cassette 설정대로 숨겨져 있다.
- Cassette 탭 구성(4개)과 Apple Music 스크린샷(5개)은 다르다.
- `.uniform`/`.standard` 아트워크 스타일은 기존 표시 방식을 유지한다.
