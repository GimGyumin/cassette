# 가사 전환, 공백 및 실제 오디오 파형 수정

2026-10-08 작업. 이전 스트리밍 탐색·배경 렌더러 변경 위에 통합했다.

## 변경 내용

- `FullPlayerViewModel.swift`: 배경 분석 완료 후 제목이 대비 계산 회색으로 바뀌지 않도록 기본 따뜻한 흰색을 유지한다. 일반 플레이어와 가사 헤더가 같은 값을 읽는다.
- `FullPlayerView.swift`, `LyricsView.swift`: 컴팩트 플레이어의 가사 LazyVStack을 재사용한다. 숨김 상태에서 추적을 중지하고, 다시 열 때 현재 위치를 한 번 반영한 뒤 400ms 후 단어 추적을 재개한다. 빠른 전환은 SwiftUI task 취소로 처리한다. 가사 하위 뷰에서 표면 전환의 암묵적 애니메이션을 차단하며 가사 자체 스크롤·번역 애니메이션은 유지한다.
- `AppleLyricTTMLParser.swift`, `LyricWordKaraokeLine.swift`: XML의 공백 콜백과 0 길이 공백 태그를 보존한다. 개별 Text 뷰에서 끝 공백이 줄어드는 것을 방지하기 위해 렌더링용 문자열만 NBSP로 바꾼다. 원본 텍스트·번역·시간·바이트 오프셋은 변경하지 않는다. 공백 없이 이어진 음절은 그대로 유지한다.
- `NowPlayingBackgroundPreparation.swift`, `ArtworkRendererPreparation.swift`: 앱 시작·준비 화면·서버 전환에서 복원할 곡의 로컬 앨범 이미지, 공통 색상 캐시 및 GPU 텍스처를 미리 준비한다. GPU 파이프라인과 블러를 준비한 렌더러 하나를 첫 화면에 독점 전달한다. 보관함 전체의 GPU 텍스처를 메모리에 만들지 않는다. 로컬 이미지가 없으면 기존 배경 로딩 경로가 처리한다.
- `AppContainer.swift`, `CassetteApp.swift`, `PlaybackSessionService.swift`, `EssentialSupportPreparationView.swift`, `RootView.swift`, `Localizable.xcstrings`: 준비 단계에 ‘지금 재생 중 배경’을 추가하고 세션 메타데이터를 오디오 재생 없이 읽는다. 동시 준비와 서버 변경은 작업·세대 번호로 중복 및 오래된 완료를 제어한다.
- `NativePlaybackMeterTap.swift`, `AVPlayerPlaybackEngine.swift`, `AudioStreamingPlayerEngine.swift`, `PlayerService+Engine.swift`: 네이티브 플레이어의 MTAudioProcessingTap과 AudioStreaming 믹서에서 실제 PCM을 읽는다. 샘플은 수정하지 않는다. 네이티브 항목 교체·Gapless 전환·중지 시 이전 탭을 비활성화한다.
- `PlaybackBeatMeter.swift`, `NowPlayingBarsIndicator.swift`, `PerformanceGovernor.swift`: 반복 사인 파형을 실제 RMS 음량으로 교체한다. 화면에 보이는 재생 중 표시만 구독하며 최대 20Hz로 작은 표시 뷰만 갱신한다. Float32/64 및 Int16/32, 인터리브·분리 채널을 처리한다. 오디오 스레드의 발행 간격은 원자 연산으로 예약하고 오래된 UI 발행을 무시한다. Reduce Motion·저전력·발열·메모리 압박·백그라운드에서는 움직임을 중지한다.

네이티브 iOS/macOS 27의 트랙 믹스 탭을 사용했다. 이전 OS에서는 오디오 트랙 탭을 사용하고 HLS 경로에는 적용하지 않는다. 보호된 스트림이나 외부 출력에서 PCM을 제공하지 않는 경우 실제 데이터가 없는 표시를 반복 애니메이션으로 대체하지 않는다. 새 디코더나 오디오 플레이어를 만들지 않는다. API 근거: [Apple HLS 2026, MTAudioProcessingTap](https://developer-rno.apple.com/streaming/Whats-new-HLS.pdf).

## 검증 상태

- unsigned generic iOS 빌드 성공: `/tmp/cassette-lyrics-transition-build.log`, `/tmp/cassette-lyrics-transition-final-build.log`.
- `git diff --check` 통과.
- 공백 파싱·SwiftUI 공백 너비·제목 색상·인터리브/Float64 PCM·준비 렌더러 독점 전달·실제 AVPlayer PCM/무음/탐색 테스트를 추가했다. 변경된 음량 갱신 주기에 맞춰 기존 성능 정책 테스트를 갱신했다.
- macOS 회귀 테스트 실행 요청은 도구에서 `Rejected("rejected by user")`로 거절되어 실행하지 않았다. 이번 변경의 테스트 통과를 주장하지 않는다. 테스트 타깃도 이번 작업에서는 빌드하지 않았다.
- 실기기에서 Liberian Girl 및 다른 가사의 띄어쓰기, 빠른 가사 열기/닫기 프레임, 서버 AAC/HLS와 AirPlay에서 파형 반응을 확인해야 한다. 실기기 프레임 계측과 서버 재생 테스트는 미실행이다.
