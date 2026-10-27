# 앨범 몰입형 하단 색상 — 하단 중앙만 사용

## 증상

몰입형 앨범 페이지의 하단 캔버스 색이 가끔 커버의 **상단 로고**나 **좌우
레터링/여백**에 끌려갔다. 특히 하단 가장자리 전체의 중앙값을 쓰거나,
하단 색이 부족할 때 이미지 전체의 색상 필드로 폴백하면서 발생했다.

## 수정

### 1. 연속 색상은 하단 중앙 밴드에서만

`ArtworkEdgeAnalyzer`가 `packedBottomBackground`를 만들 때 전체 하단
에지가 아니라 다음 영역만 샘플링한다.

- 세로: 하단 18% (`82%..<100%`), 가장자리 링잉 제외
- 가로: 중앙 60% (`20%..<80%`)

이 색이 `FadedArtworkHero`의 `edgeColor`로 들어가 커버 아래 페이지
본문으로 이어진다.

### 2. 페이지 색은 하단 구성에서만

- `lowerFamilies`는 기존처럼 하단 40%만 보되, 바깥 20%의 가중치를 0.5로
  낮춰 옆면 레터링/스파인/흰 여백이 중앙 피사체를 이기지 못하게 했다.
- 이미지 전체 색상 필드(`families`/`hasColorField`)로의 폴백을 제거했다.
  하단에 색상 필드가 없으면 하단 중앙의 색으로 중립 캔버스를 만든다.
- 하단의 중립 색이 다수이면(예: 흰 타이포그래피 슬리브의 작은 빨간 띠)
  중립 캔버스를 우선한다. 단, 매끈한 그라데이션은 미세한 색조를 유지한다.
- 하단에 색상 패밀리가 있으면 그 색을 사용하되, 상단에만 있는 색은
  후보에서 제외된다.

### 3. 캐시 무효화 및 페이지 진입 시 재분석

`ArtworkEdgeAnalysis.currentVersion`을 **8 → 9**로 올려 기존에 저장된
하단 색상 사실을 다시 준비하도록 했다. 또한 앨범 페이지가 준비된 팔레트를
읽을 때 `isPreparedForCurrentPresentation`을 확인하고, 구버전이면
`AlbumCoverPreloadService.prepareTheme`으로 즉시 재분석해 새 팔레트를
적용한다. 그래서 라이브러리 전체 준비 패스를 기다리지 않아도 페이지를
열면 새 하단 색상이 반영된다.

## 파일

- `Cassette/DesignSystem/Theming/ArtworkEdgeAnalysis.swift`
- `Cassette/Views/Browse/AlbumDetailView+Palette.swift`
  - 구버전 팔레트 감지 시 `prepareTheme` 재분석
- `CassetteTests/ArtworkPresentationTests.swift`
  - `bottomContinuationUsesTheCentralSubjectNotSideMargins`
  - `topOnlyRedFieldDoesNotTintTheBottomPageColor`

## 검증

- iOS `build-for-testing`: `EXIT:0`
- `AlbumDetailOfflineTests` + `LyricsAndChromeRegressionTests`: 44개 통과
  (`TEST SUCCEEDED`)
- `ArtworkPresentationTests`의 분석/팩트 테스트 통과:
  - 새 테스트 2개 포함
  - `ordinarySleeves…`, `lowerComposition…`, `darkSleeveBorder…`,
    `whiteTypography…`, `smoothSleeves…`, `uniformSleeves…` 등
- `ImageRenderer` 기반 렌더 테스트 6개는 이 Mac 테스트 환경에서
  분석기와 무관한 Dolby 렌더 테스트까지 함께 실패한다(렌더 하네스 제약).
  실제 기기에서 Bad/세로 레터링 커버로 시각 확인이 필요하다.

## 실제 확인

- Bad처럼 상단에 큰 레터링, 하단에 인물이 있는 커버에서 페이지 하단이
  커버 하단 중앙 색으로 이어지는지 확인한다.
- 좌우에 세로 레터링/흰 여백이 있는 커버에서 하단 색이 밝아지지 않는지
  확인한다.
- 기존 버전에서 분석된 앨범은 페이지 진입 시 버전 9로 재분석된 뒤 확인한다.
