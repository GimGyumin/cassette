# 몰입형 Now Playing

## 변경

`cassette.visuals.immersiveAlbums`(설정의 “Immersive Album Artwork”)가 켜져 있고,
iPhone 세로의 compact Now Playing `player` 화면일 때 사진과 같은 몰입형
레이아웃을 사용한다.

- 정사각 커버를 화면 상단에 **full-width**로 선명하게 표시하고, 상단 가장자리는
  상태 바 아래까지 이어지게 한다.
- 커버 아래쪽은 같은 커버의 **단순 블러 확장**으로 이어지며, 곡
  정보·스크러버·전송 버튼·볼륨·하단 툴바를 그 위에 오버레이한다.
  `AppleMusicLyricsBackground`의 하단 exposure/비네트는 사용하지 않는다.
- **별도의 하단 검은 스크림/어두운 그라데이션을 적용하지 않는다.** 사진처럼
  아트워크와 블러 확장의 밝기를 유지하고, 컨트롤은 그 위에 직접 올린다.
  상단 상태 바용 어두운 오버레이도 두지 않는다.
- 기존 정사각 커버 카드는 immersive player에서 렌더링하지 않는다.
- `animatedArtwork`가 켜져 있고 재생 중이면 선명한 커버에 아주 느린 호흡
  스케일(≈1.2%)만 적용한다. Reduce Motion이면 정지.
- 가사/큐 화면, iPad/가로/와이드 플레이어, 설정이 꺼진 경우는 기존
  레이아웃과 배경을 유지한다.
- 몰입형 화면은 `.preferredColorScheme(.dark)`로 상태 바/글래스 크롬을
  일관되게 유지한다.

## 파일

- `Cassette/Views/Main/Player/ImmersiveNowPlayingBackground.swift`
  - `ImmersiveNowPlayingBackground`
- `Cassette/Views/Main/FullPlayerView.swift`
  - `showsImmersivePlayer`, `immersiveCompactPlayer`
  - `content`의 배경 분기

## 검증

- iOS `build-for-testing`: `EXIT:0`
- macOS `AlbumDetailOfflineTests` + `LyricsAndChromeRegressionTests`: 44개 통과
  (`TEST SUCCEEDED`)
- 실제 iPhone 세로에서 설정 ON/OFF, 재생/일시정지, 가사/큐 전환을 확인한다.
- 노치/상태 바, 홈 인디케이터, 작은 화면과 큰 Dynamic Type에서 컨트롤이
  잘리지 않는지 확인한다.
