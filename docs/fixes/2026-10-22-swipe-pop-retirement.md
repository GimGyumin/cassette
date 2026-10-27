# 스와이프 뒤로가기 잔상·유령 터치 수정

> 2026-10-22 최종 결정: 앨범 페이지의 zoom 전환 자체를 제거하고 기본
> NavigationStack push/pop으로 되돌렸다. 이 문서의 source ID/가시성 수정은
> 더 이상 최종 구현이 아니다. 최종 변경은
> `docs/fixes/2026-10-22-album-zoom-removed.md`를 참고한다.

> 2026-10-22 후속 수정: 이 문서에서 추가한 `page.view.isHidden` 기반 retire는
> zoom 종료 도중 검은 프레임·전체 화면 복귀·갑작스러운 소멸을 만들 수 있어
> 제거되었다. 현재 구현은 가시성을 건드리지 않고 터치만 차단하며, zoom 소스 ID를
> `album.id`로 고정한다. 자세한 분석은
> `docs/fixes/2026-10-22-album-pop-animation-analysis.md`를 참고한다.

기기 보고:

- 툴바 `<` 뒤로가기는 정상이다.
- 아이폰 가장자리 스와이프 뒤로가기를 하면 앨범 페이지가 닫힌 직후 잠깐 다시
  나타났다가 사라진다.
- 앨범 페이지가 완전히 로드되기 전에 닫으면 정상이다.
- 페이지가 사라진 뒤에도 보이는 내용만 사라지고 재생 버튼 등의 터치 영역이 남아
  있어, 그 위치를 탭하면 방금 닫은 앨범이 재생된다.

## 원인

앨범 페이지는 `NavigationStack`의 목적지이며 iOS 18+ zoom 전환을 사용한다.
완료된 인터랙티브 pop 뒤에도 UIKit/SwiftUI가 제거된 페이지의 hosting view를 잠시
유지하면서 늦은 appearance/teardown 콜백과 상태 업데이트가 들어온다.

- 이전 `AlbumPresentationController`는 `viewWillAppear`마다 revision을 올리고
  appearance 콜백으로만 복귀를 판단했다. 완료된 pop인지 취소된 스와이프인지
  전환 코디네이터의 `isCancelled`로 구분하지 않았다.
- 제거된 페이지의 hosting view는 화면에서만 사라지고 `isUserInteractionEnabled`는
  그대로여서, 남아 있는 버튼이 탭을 계속 받았다.
- 페이지가 로드되기 전에는 늦게 도착하는 상태 업데이트가 없어 증상이 보이지 않았다.

## 변경

`AlbumPresentationLifecycle.swift`의 `AlbumPresentationController`:

1. `viewWillDisappear`에서 `transitionCoordinator`(또는 내비게이션 컨트롤러의
   coordinator)의 완료를 등록한다. 완료 시 `context.isCancelled`로
   - 취소된 스와이프: 페이지를 복원하고, 정착한 뒤에만 `onReturn()`을 실행한다.
   - 완료된 pop: 페이지를 즉시 retire한다.
2. `notifyWhenInteractionChanges`에서 드래그가 끝난 시점에 커밋된 스와이프의
   페이지 상호작용을 먼저 끈다. 정착 애니메이션 중 재생 버튼 탭이 먹지 않는다.
3. `retirePageIfPopped()`는 `navigation.viewControllers`에 더 이상 없는 페이지만
   대상으로 한다.
   - `page.view.isUserInteractionEnabled = false`
   - `page.view.isHidden = true`
   - 위로 push된 페이지만 덮인 경우(배열에 남아 있음)는 건드리지 않는다.
4. 늦은 `viewWillAppear`/`viewDidAppear`가 제거된 페이지에 도착하면 복귀/로드
   재개 대신 retire만 수행한다. 다시 스택에 들어온 경우에는 가시성과 터치를
   복원한다.
5. 내비게이션 스택은 있는데 페이지 컨트롤러를 찾지 못한 경우 `isCurrentPage`는
   `false`로 처리해 pop 이후의 늦은 resume을 막는다.

기존 zoom 전환, `NavigationLink` 라우트, 툴바 뒤로가기, 페이지 로드/서스펜드
구조는 유지한다. 타이머로 숨기거나 제스처를 비활성화하지 않는다.

## 검증

- 아이폰 16 Pro(실기기)에서 `AlbumZoomDismissalTests` 7개 전부 통과:
  - 완료된 스와이프: 페이지가 숨겨지고 터치가 꺼지며, 늦은 appearance로도
    복귀/로드가 재개되지 않는다.
  - 드래그 커밋 직후(정착 전): 터치만 먼저 꺼지고, 취소로 확정되면 다시 켜진다.
  - push로 덮인 앨범 페이지: retire되지 않고, 돌아오면 로드가 재개된다.
  - 취소된 스와이프: 계속 보이고 터치 가능하며, 정착 후 한 번만 resume된다.
- iOS `build-for-testing`(generic/platform=iOS) 성공, 경고/오류 없음.
- macOS `AlbumDetailOfflineTests` + `LyricsAndChromeRegressionTests` 44개 통과.
- 실제 가장자리 제스처의 시각적 결과(재표시/잔상)는 빌드된 앱에서 한 번 더
  확인해야 한다. 유닛 테스트는 UIKit 라이프사이클 계약을 검증하지만, SwiftUI
  zoom 스냅샷 자체의 기기 고유 렌더링까지 재현하지는 않는다.
