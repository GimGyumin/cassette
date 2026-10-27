# 지금 재생 화면 아트워크 고화질 선택

## 증상

다운로드한 앨범은 원본(고화질) 커버가 디스크에 있는데도 지금 재생 화면이
저화질 썸네일로 표시될 수 있었다.

## 원인

- 지금 재생 화면은 `playbackCoverId` **한 개**만 사용했다.
- 곡의 explicit cover ID와 라이브러리 준비/다운로드가 저장한 앨범 cover ID가
  다를 수 있고, 전자에는 240px 썸네일만 있는 경우가 있다.
- `FullPlayerViewModel`의 초기 이미지 선택은 hero 캐시가 없으면 thumb를
  받아들이고, 그 상태를 prepared로 표시해 hero 승격이 늦어질 수 있었다.

## 수정

- `AppContainer.playbackCoverCandidates(for:)`: 곡 explicit → 준비된 앨범
  cover → playback cover → effective cover 순으로 중복 제거된 후보를 만든다.
- `AppContainer.localPlaybackArtwork(for:)`:
  1. 모든 후보의 **영구 다운로드 원본**(`loadPlainDiskCover`, hero 1200)을 먼저 검색
  2. 없으면 후보별 로컬 tiered hero를 검색
  3. 썸네일만 있는 후보는 선택하지 않는다
- `FullPlayerView`:
  - 트랙이 바뀌거나 `coverArtUploadVersion`/artwork revision이 바뀌면 후보를
    다시 해석한다.
  - 해석된 ID와 이미지를 `resolvedArtworkID`/`resolvedArtworkImage`에 보관하고
    `playerCoverImage`, 배경, 모든 CoverArtView가 이 값을 우선 사용한다.
  - 해석 중에는 기존 playback cover를 먼저 보여 주고, 원본이 준비되면 교체한다.
- 앨범 페이지의 다운로드 원본/커버 캐시 경로는 그대로 유지한다.

## 파일

- `Cassette/App/AppContainer.swift`
- `Cassette/Views/Main/FullPlayerView.swift`

## 검증

- iOS `build-for-testing`: `EXIT:0`
- 기존 macOS 테스트 45개 통과 (`TEST SUCCEEDED`)
- 실제 iPhone에서 다운로드 앨범을 열고, 지금 재생 화면을 닫았다 다시 열어
  고화질 원본이 표시되는지 확인한다.
- 같은 앨범의 곡별 커버가 다른 경우, 곡 고유 아트워크가 있으면 그것을
  우선하되 원본이 없을 때 준비된 앨범 커버 원본으로 폴백한다.
- 앨범 페이지에서 스크롤을 끝까지 내린 뒤에도 제목/버튼 뒤 어두운
  그라데이션이 유지되는지 확인한다.
