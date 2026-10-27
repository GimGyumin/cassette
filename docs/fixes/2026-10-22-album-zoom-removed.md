# 앨범 페이지 zoom 전환 제거

## 결정

앨범 카드에서 상세 페이지를 열 때의 navigation zoom 전환을 제거하고, 표준
`NavigationStack` push/pop으로 되돌린다. 앨범 페이지의 디자인, 커버, 재생/다운로드
UI, 미니 플레이어는 유지한다.

## 이유

- 원본(`CassetteLab/cassette` main `aed1663d`)도 수평 선반(`CarouselAlbumCard`)과
  `AlbumsListView`에서는 navigation zoom을 쓰지 않는다. zoom은 최근 추가/
  Discover/컬렉션 grid처럼 안정적인 `matchedTransitionSource`가 있는 곳에만 쓴다.
- 로컬은 `AlbumNavigationLink`가 모든 앨범 카드에 zoom source를 등록했다.
  `LazyHStack`, `.clipped()`, `List` 안의 카드가 페이지가 열린 사이 재생성되면
  interactive pop의 소스가 사라져 “zoom이 잘못된 위치로 가고, 페이지가 다시
  전체 화면으로 돌아온 뒤 사라지는” 현상이 생길 수 있다.
- 이 문제를 source ID/namespace/lifecycle로 계속 보정하는 대신, 앨범 페이지
  전환에서 zoom을 제거해 UIKit의 기본 interactive pop만 사용하도록 단순화했다.

## 변경

- `AlbumNavigationLink`: 항상
  `NavigationLink(value: destination ?? .album(album))` (iOS) /
  `DetailNavigationLink` (macOS)를 사용. `zoomEnabled`, `routeID`, source route 제거.
- `AlbumZoomDestination`, `.cassetteAlbumZoomNavigation()` 제거.
  MainTabView/HomeView의 등록 호출도 제거.
- `AlbumDetailView`에서 `.cassetteZoomTransition(...)` 제거. 앨범 페이지는 기본
  push/pop을 사용한다.
- `SwipeBackEnabler.swift` 제거, iOS 커스텀 back/`isDismissing` 제거, 시스템
  back 버튼 복원. (다른 화면의 zoom은 유지)
- `AlbumPresentationLifecycle`은 로드 suspend/복귀와 완료된 pop의 터치 차단만
  유지한다. (`isHidden` 없음)

## 유지되는 zoom

- 전체 플레이어 전환
- 앨범/아티스트/플레이리스트 내부의 커버 확대 화면 (해당하는 화면)
- 기타 기존 `cassetteZoomTransition` 사용처

## 검증

- iOS `build-for-testing`(generic/platform=iOS) 성공, `EXIT:0` — 앨범 zoom
  라우트/전환/커스텀 back 제거 후 최종 코드.
- macOS `AlbumDetailOfflineTests` + `LyricsAndChromeRegressionTests` 44개 통과
  (`TEST SUCCEEDED`, `EXIT:0`).
- `AlbumZoomDismissalTests`(7개)는 `AlbumPresentationLifecycle`의 로드 suspend/
  복귀·터치 차단 계약을 계속 검증한다. (이전 리비전에서 실기기 7/7 통과)
- 실제 가장자리 스와이프가 기본 NavigationStack pop으로 동작하는지는 아이폰에서
  확인해야 한다. (마지막 기기 테스트 시도는 iPhone 잠금으로 시작되지 않음)
