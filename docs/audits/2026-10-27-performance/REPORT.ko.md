# Cassette 성능 감사 및 구현 결과

작업: 2026-10-26~27. 기준선은 HEAD가 아니라 작업 시작 시의 **수정된 작업 폴더**다. 기존 변경·미추적 파일을 유지했으며 reset, 데이터 삭제, 음원 변환, 서버 설정 변경, 앱 설치/배포를 하지 않았다. 이번 코드 변경만 분리한 파일은 [changes-from-start.patch](changes-from-start.patch)다.

## A. 전체 성능 진단

### 환경과 확인 범위

- Xcode 27.2 (27B5028f), iOS/macOS 27.2 SDK. Cassette 앱·테스트의 iOS 최소 버전은 18.6이다. 프로젝트 공통 설정에는 18.0도 있으나 타깃 설정이 우선한다.
- 앱은 Swift 5 언어 모드, 기본 MainActor 격리를 사용한다. 로컬 SwiftSonic 패키지는 Swift tools 6.0이다. 설치된 Swift 도구 체인과 언어 모드는 별개다.
- Scheme: `Cassette`, `CassetteTests`, `CassetteUITests`; Debug/Release 구성. macOS arm64에서 호스팅 테스트를 실행했다.
- Instruments 템플릿은 Time Profiler, CPU Profiler, SwiftUI, Animation Hitches, Allocations, Leaks, File Activity, Network, Power Profiler 등을 사용할 수 있었다. 그러나 연결 목록의 iPhone 16 Pro/iPad Pro는 **Offline**이었다. iPhone의 CPU·전력·메모리·프레임 trace는 수집하지 않았다.
- 전체 파일 목록과 반복 작업/IO/동시성 패턴을 검색하고, 아래 핵심 경로의 구현과 호출부를 읽었다. 모든 UI 경로를 기기에서 직접 실행하거나 모든 경쟁 상태의 부재를 증명한 것은 아니다.

### 실제 구조와 실행 경로

| 계층 | 확인한 실행 경로 및 수명 |
|---|---|
| 앱 시작 | `CassetteApp` → `AppContainer` → `setup()`에서 Player/NowPlaying/Widget/ReplayGain 연결. 호스팅 단위 테스트는 개인 저장소·실제 앱 부팅을 건너뛴다. |
| 선택/재생 상태 | actor `PlayerService`와 `+Transition`, `+Controls`, `+Commit`; MainActor `PlayerState`에 투영. `PlaybackContext`, command/epoch, seek generation, `PlaybackAuthority`로 오래된 결과를 차단한다. |
| 소스 결정 | `MediaResolver.resolve` → 다운로드 파일 → 유효한 캐시 → 서버. Subsonic뿐 아니라 Jellyfin 경로도 구현되어 있다. 계정 revision과 원본/트랜스코딩/Atmos 설정을 반영한다. |
| 네이티브 오디오 | `startEnginePlayback` → `AVPlayerPlaybackEngine.start` → `AVURLAsset`/`AVPlayerItem` → `AVQueuePlayer` → 시스템 디코더·출력. macOS는 이 경로를 사용한다. iOS의 캐시, HLS, transcode offset, 무손실의 비44.1kHz/채널 조건, 무선 출력 등은 정책에 따라 이 경로로 간다. |
| 대체 오디오 | `AudioStreamingPlayerEngine` → AudioStreaming 1.4.5의 네트워크/파일 소스·디코더 → PCM reservoir → AVAudioEngine/custom EQ → 출력. 의존성의 출력은 44.1kHz stereo Float32이며, 고해상도/다채널 우회 정책은 기존 구현을 유지했다. |
| Gapless | `ensureGaplessPreparation` → `scheduleGaplessPreQueue` → native `prepareNext` 또는 AudioStreaming queue. 네이티브 `consumeQueuedTransition`은 재시작 없이 메타데이터만 인계한다. |
| Crossfade | 기존 구현은 capability에 따른 **sequential fade-out/fade-in**이다. 항상 두 곡을 동시 믹싱하는 엔진으로 가정하지 않았다. 별도로 무손실 품질 교체에 일시적 두 플레이어와 80ms blend가 있다. |
| DSP/미터 | ReplayGain 설정·peak 제한 정책과 native gain 보존. Beat meter는 atomic gating/mailbox로 UI 구독이 없을 때 PCM 분석을 피한다. native gapless 경로는 per-item audio mix 분석을 피하는 기존 정책을 유지한다. |
| 네트워크 | `LibraryService`의 클라이언트·계정별 메타데이터 캐시/진행 중 요청 통합 → SwiftSonic transport/재사용 URLSession. `MediaTransferCoordinator`는 cache/permanent 전송을 request identity별로 조정한다. |
| 저장소 | SwiftData 캐시·세션·청취 기록, SQLite 라이브러리 index. `PlaybackCheckpointScheduler`는 30초 체크포인트, pause/background 등은 즉시 저장. 세션 저장은 동일 payload/queue 재인코딩을 피한다. |
| 가사 | `LyricsService` → TTML/LRC parser/document builder → detached 준비 → `LyricsViewModel`의 표시행/타임라인. 단어 TTML은 AMLL cursor 기반 timeline, 나머지 경로는 `LyricPlaybackTimeline`. 엔진 샘플로 보정한 presentation clock을 사용하며 비표시/background에는 tracking을 중단한다. |
| SwiftUI/이미지 | `@Observable PlayerState`, 가사 전용 clock/state, lifecycle별 task 취소. `MarqueeText`는 scene/motion 정책에 따라 task 중단. GPU 배경은 비표시 때 MTKView pause. artwork는 240/1200px ImageIO downsample, decode gate, RAM 110개/48MiB, account generation과 요청 통합을 사용한다. |
| 미디어/백그라운드 | `.playback` + `.longFormAudio`, `UIBackgroundModes=audio`; 인터럽션/route/media reset 처리. Now Playing은 이벤트 기반 clock/rate를 게시하고 30초 반복 작업은 서버 보고에 사용한다. |

### 발견한 추가 문제

1. **사용하지 않는 오디오 엔진의 즉시 생성 — P1.** `AppContainer`가 만드는 `AudioStreamingPlayerEngine.init`이 AudioPlayer를 곧바로 생성했다. 의존성의 `AudioRendererContext.init`은 `44,100 × 30 × 8 = 10,584,000 bytes`의 PCM 저장소를 할당하고 AudioPlayer는 그래프·큐·네트워크 클라이언트를 구성한다. macOS 및 native-only iOS 재생에서도 필요하지 않은 할당이다. 이는 소스에서 확인한 할당 크기이며, RSS 감소 실측값은 아니다.
2. **진행 시간 게시의 오래된 occurrence 수용 가능성 — P0.** `startProgressTimer`는 actor에서 epoch를 검사한 뒤 MainActor로 이동하여 track ID만 다시 검사했다. 같은 ID의 재선택/repeat나 새로운 seek/pause command가 그 사이 발생하면 이전 샘플을 현재 UI에 적용할 여지가 있었다. 기존 authority commit 경계를 이 게시에도 사용하도록 수정했다. 기기에서 관찰한 버그 재현으로 과장하지 않는다.
3. **긴 가사의 매 tick 전체 순회 — P2.** 기존 `LyricPlaybackTimeline.activeRows`는 text-free 캐시를 사용하더라도 전체 timed entries를 매번 순회했다. 단어 TTML의 기존 AMLL 경로와 구분하여 fallback/line timeline만 개선했다. 독립적인 기존 알고리즘과 결과를 대조하고 같은 프로세스에서 A/B 측정했다.
4. **이미지 보조 사전의 무제한 증가 — P1/P2.** 이미지 RAM에는 제한이 있었지만 `localImageSources`와 실패 cooldown 날짜 사전은 별도였다. 다른 앨범을 계속 방문하거나 서로 다른 실패를 만나면 메모리 경고 전까지 항목이 늘어날 수 있었다.
5. **불필요한 반복 분기 비용 — P1.** Crossfade가 꺼져 있어도 prefetch 검사에서 iOS 오디오 route 조회와 MainActor snapshot을 먼저 수행했다. scrobble이 이미 제출된 곡도 매 tick MainActor를 조회했다. 자동 다운로드 비활성 여부도 Atmos 후보 조회 뒤 검사했다. 다운로드 안정화 대기는 같은 track ID의 다른 epoch로 바뀐 경우 불필요하게 계속 polling할 수 있었다.
6. **테스트 전역 상태 간섭 — P3.** 기본 병렬 전체 실행은 13개 실패했다. MPNowPlayingInfoCenter, 실제 오디오 출력, PerformanceGovernor, UserDefaults를 공유하는 suite가 동시에 실행된다. 동일 최종 코드의 전체 직렬 실행에서는 실패가 없었다. 실패를 성능 개선으로 해결했다고 세지 않고, 테스트 격리 문제로 분리했다.

## B. 실제 수정 사항

| 파일 | 수정 내용 | 회귀 위험·보존 범위 |
|---|---|---|
| `Services/Playback/AudioStreamingPlayerEngine.swift` | AudioPlayer 지연 생성. volume/delegate/EQ/filter 설정은 먼저 보존하고 처음 필요한 play/queue에서 적용. idle 상태 조회·pause/stop/reset은 엔진을 만들지 않는다. | 최초 fallback 시작 시 생성 비용이 발생한다. stop 후 기존 인스턴스를 안전하게 교체하는 정책과 이미 준비된 gapless 인스턴스는 유지. 기존 버퍼/포맷/DSP 변경 없음. 한 번 사용한 엔진의 즉각적인 메모리 해제까지 이번 변경에 포함하지 않았다. |
| `Services/Implementations/PlayerService+Progress.swift` | progress UI 게시에 `commitPresentation(context)` 사용. 자동 다운로드 early exit 및 안정화 polling의 epoch 검사 추가. | 동일 ID 재선택과 신규 command 보호. 필요한 재생/복구 tick 주기는 바꾸지 않았다. |
| `Services/Implementations/PlayerService+Crossfade.swift` | Crossfade 비활성 상태에서 route/snapshot 조회 전 반환. | enabled 경로의 prefetch 시점과 fade 곡선 그대로. |
| `Services/Implementations/PlayerService+Reporting.swift` | scrobble 완료 후 불필요한 조회 생략; 조회 후 context 재검사. | reset된 새 곡에는 다시 적용. 이전 곡의 metadata를 새 accumulator에 적용하는 경로도 차단. |
| `Utilities/LyricPlaybackTimeline.swift` | start upper-bound + 최대 종료 시각 tree로 만료된 범위 건너뛰기. display-order upcoming fallback은 suffix index로 보존. | 생성 시 O(n log n), 추가 O(n) 메모리. 조회는 대부분 O(log n + 활성 겹침 수); open-ended 행이 모두 실제 활성인 경우 그 출력 비용은 남는다. backward seek/동시 vocal/빈 행/정렬되지 않은 입력/끝 경계 의미 유지. |
| `Services/Implementations/ArtworkImageCache.swift` | source metadata 110개, 실패 cooldown 256개 LRU 제한. | evicted source hint는 재조회 가능. 256개 초과 서로 다른 실패에서는 오래된 실패가 다시 시도될 수 있다. 원본·음원·영구 다운로드 파일 삭제 없음. |
| `Services/Networking/NetworkTaskDiagnostics.swift` | URLSession transaction의 encoded HTTP 송수신 byte 수 합산. redirect 포함, URL/인증정보 미기록. | 이 delegate를 사용하는 세션 범위만 측정. AVPlayer 내부 전송이나 무선 링크 전체 바이트라고 해석하면 안 된다. iOS 13+ API로 최소 OS 범위 내다. |
| `CassetteTests/GaplessContinuityTests.swift` | 1,000회 idle 조회에서 엔진 미생성, EQ/volume 지연 설치와 queue 인스턴스 유지 테스트 추가. | 실제 PCM fixture 재생 테스트도 기존 그대로 실행. |
| `CassetteTests/LyricPlaybackTimelineTests.swift` | 2,000행/502개 시각의 randomized oracle 비교. overlap, nil end, 역방향 seek, Int 경계 포함. | 기존 선형 의미와 결과를 비교하며 새 구현 자체를 기대값으로 쓰지 않는다. |
| `CassetteTests/LyricTimelinePerformanceTests.swift` | 변경 전 cached scan과 새 index의 XCTest clock/CPU A/B benchmark. | Debug microbenchmark이며 앱/기기 전력 지표와 분리한다. |
| `CassetteTests.xcscheme` | 공유 시스템 자원을 쓰는 hosted suite의 기본 병렬 실행 해제. | 일부 순수 테스트 병렬성은 줄지만 전역 미디어 상태 간섭을 방지한다. |

새 프레임워크를 도입하지 않았다. UI 디자인·접근성 레이블·Dynamic Type·Reduce Motion·음질 설정·코덱 선택·샘플레이트·음량 정책을 변경하지 않았다. 이것은 변경 범위의 확인이며, 기기에서 모든 기능이 검증되었다는 뜻은 아니다.

## C. 성능 비교

### 실제 iPhone 앱 지표

| 측정 항목 | 변경 전 | 변경 후 | 변화 |
|---|---|---|---|
| Idle / Playback CPU, Main Thread 점유 | 미측정 | 미측정 | 확인 불가 |
| 평균/최대 메모리, 30분/60분 증가량 | 미측정 | 미측정 | 확인 불가 |
| Energy / Power Impact | 미측정 | 미측정 | 확인 불가 |
| Disk Writes | 미측정 | 미측정 | 확인 불가 |
| Network 요청 수·전체 전송량 | 미측정 | 미측정 | 확인 불가 |
| Playback 시작/전환 지연·stall | 미측정 | 미측정 | 확인 불가 |
| SwiftUI 업데이트·Animation Hitches | 미측정 | 미측정 | 확인 불가 |

### 측정한 제한적 A/B 결과

macOS 27.2 arm64 MacBook Air, Xcode 27.2, Debug hosted XCTest. **4,000 timed rows, 2,000개 재현 가능한 forward/backward 조회, 3회 평균**, 생성 비용은 측정 구간 밖. 전후 알고리즘을 같은 실행 파일에 포함했다. 화면/음원/오디오 출력 부하의 비교가 아니며 기기 열 상태를 통제한 전력 측정도 아니다.

| 측정 항목 | 기존 cached linear scan | 새 indexed lookup | 변화 |
|---|---:|---:|---:|
| 조회 workload wall time | 357.512 ms | 2.058 ms | 약 99.42% 감소 |
| 조회 workload process CPU time | 357.152 ms | 2.353 ms | 약 99.34% 감소 |

원시 결과: [linear-baseline-metrics.csv](linear-baseline-metrics.csv), [indexed-metrics.csv](indexed-metrics.csv). 이 비율을 음악 재생 전체 CPU나 배터리 절감률로 사용해서는 안 된다.

할당 경로 비교: native-only 사용에서 fallback AudioPlayer 생성은 즉시 1회에서 최초 사용 전 0회로 바뀌었다. PCM reservoir의 **10,584,000 bytes 할당 경로를 피한다**는 것은 코드 및 수명 테스트 근거다. 실제 resident memory가 같은 양만큼 줄었다고 주장하지 않는다.

## D. 검증 결과

정확한 집계는 [verification.json](verification.json)에 기록한다. 테스트 수와 parameterized 실행 건수를 구분한다.

- 변경 전 전체 Debug 테스트: 1,329 통과, 13 실패, 1 skip. parameterized 통과 1,496건.
- 1차 오디오/clock/가사 회귀: 16 통과, 0 실패 (17건).
- 2차 가사 benchmark/이미지/취소/네트워크 회귀: 49 통과, 0 실패 (51건).
- 최종 코드 전체 직렬 Debug 테스트: **1,347 통과, 0 실패, 1 skip**, parameterized 통과 **1,514건**. 1개 기존 skip을 실행 성공으로 세지 않았다.
- 공유 Scheme 직렬화 후 `-parallel-testing-enabled NO` 없이 다시 전체 실행: **동일하게 1,347 통과, 0 실패, 1 skip**. skip은 기존 `CustomHeadersTransportTimeoutTests/defaultInit_timesOutOnHungServer()`다.
- SwiftSonic 패키지: **387 tests / 120 suites 통과**.
- iOS: **Cassette / Release / generic iOS / SDK 27.2 / CODE_SIGNING_ALLOWED=NO 빌드 성공**. 서명·설치·실기기 실행 성공을 뜻하지 않는다.
- `git diff --check` 통과. 초기 사용자 변경을 되돌리지 않았다.

실행한 주요 명령:

```sh
xcodebuild test -project Cassette.xcodeproj -scheme CassetteTests \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/cassette-performance-audit-20261026/DerivedData \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO

xcodebuild build -project Cassette.xcodeproj -scheme Cassette \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/cassette-performance-audit-20261026/DerivedData \
  CODE_SIGNING_ALLOWED=NO

swift test --package-path Packages/SwiftSonic \
  --scratch-path /tmp/cassette-performance-audit-20261026/SwiftSonicBuild
```

원본 로그/xcresult: `/tmp/cassette-performance-audit-20261026/`. 결과 bundle은 baseline, phase1, phase2, final-full 및 기본 Scheme 재검증 final-scheme으로 구분한다. `/tmp`는 영구 보관 위치가 아니므로 비교 CSV와 민감한 오류 내용을 제외한 요약을 이 디렉터리에 보존했다.

기존 회귀 테스트는 첫 시작, 취소, stale callback, seek/복구, pause, queue/repeat 정책, prepared gapless, 캐시/전송 통합, 세션 저장, 가사 시계 등을 포함한다. 실제 출력 파형의 무음·bit-perfect 측정, 100곡 실연속 재생, 30/60분 soak, Bluetooth/전화/잠금 화면, 느린 Wi-Fi 및 셀룰러 handoff는 이번 환경에서 실행하지 않았다.

## E. 남은 최적화 과제와 측정 절차

1. **P0/P1 — 실제 iPhone 재생 정확성·전력 검증.** 연결 가능한 iPhone에서 같은 Release 소스 조건의 전후 빌드를 별도 보존한다. 현재 변경 파일만 되돌려 개인 작업 폴더를 파괴하는 방법은 사용하지 않는다. 처음 1회 warm-up 후 각 조건 최소 3회, 같은 음원/출력/볼륨/밝기/네트워크/온도 조건을 기록한다.
2. **P1 — 30/60분 soak.** local lossless, Wi-Fi lossless, cellular streaming, 화면 잠금, 가사 표시를 분리한다. Allocations/VM Tracker로 peak와 시간별 증가량, Leaks로 retain cycle, File Activity로 세션 DB와 캐시 쓰기를 기록한다. 한 번 fallback을 사용한 뒤 native로 바꿀 때의 엔진 잔존 메모리는 다음 검토 대상이다.
3. **P1 — 반복 작업 통합 검토.** 현재 progress loop와 native stall watchdog은 서로 다른 판단을 수행한다. 실제 Thread State/CPU trace로 비용을 확인한 뒤 통합 여부를 결정한다. 이번에는 stall/seek 복구 지연 위험을 피하기 위해 주기·buffer policy를 추정으로 줄이지 않았다.
4. **P1 — 서버별 전송 검증.** 실제 서버의 Range/206/Content-Range, offset transcode, ETag/Last-Modified, 연결 중단·재개를 확인한다. 인증/코덱/bitrate/offset에 따라 cache identity를 보존한다. 서버 지원을 가정한 새 resume/validation 기능은 구현하지 않았다. HTTP metrics는 부착된 URLSession만 포함하므로 Instruments Network와 서버 로그로 AVPlayer 전송까지 함께 비교한다.
5. **P2 — UI 실측.** SwiftUI Instruments의 Update Groups/Long View Body Updates, Animation Hitches를 Mini↔Full, 앨범 진입/닫기, swipe, lyrics show/hide, 대량 목록에 대해 기록한다. 실제 60/120Hz 하드웨어, VoiceOver/Dynamic Type/Reduce Motion 조건을 포함한다. 이번 가사 결과는 AMLL 단어 강조 전체 비용을 나타내지 않는다.
6. **P2 — 남은 cache/main-thread 비용.** artwork preference/revision 사전과 album-list cache의 장기 크기, `presentationKey`의 반복 SHA 계산, 일부 동기 파일 metadata 조회, GPU texture 생존 수명을 trace로 평가한다. revision은 진행 중 결과의 권한 토큰이므로 무작정 LRU로 바꾸지 않았다.
7. **P3 — 테스트 자원 격리.** 시스템 미디어를 사용하는 suite를 별도 test plan/process로 나누고, UserDefaults/성능 budget을 주입하면 순수 테스트의 병렬화를 복구할 수 있다. 지금은 공유 Scheme 직렬화로 동일 프로세스 오디오/Now Playing 간섭을 막는다.

기기별 데이터 입력 양식은 [device-measurements.csv](device-measurements.csv)다. 모든 미측정 셀을 그대로 남겼다.

### Instruments 재현 순서

1. 먼저 `xcrun xctrace list devices`로 **온라인** 여부를 확인한다. Xcode destination 목록의 기억된 기기만으로 연결 가능하다고 판단하지 않는다.
2. Product → Profile로 Release를 실행한다. Time Profiler/CPU Profiler와 Thread State(System Trace), Allocations/Leaks, File Activity/Network는 필요에 따라 별도 실행해 도구 자체의 부하를 줄인다.
3. 2분 idle, 2분 paused, 5분 전경 재생, 5분 가사, 5분 화면 잠금, 30/60분 soak를 동일 playlist와 출력을 사용해 비교한다. 100곡 queue, rapid next/previous, seek 중 next, buffering pause, 회복 중 queue 교체, 마지막 곡·repeat/shuffle을 별도 수행한다.
4. 시작 지연은 기존 `[ENGINE-START]`와 `[PLAYBACK] event=confirmed`의 같은 epoch를 상관 분석하되, 후자는 UI/엔진 확인 시점임을 기록한다. 실제 첫 audible sample과 gapless 무음은 오디오 loopback/Audio System Trace로 별도 측정한다. `[PLAYBACK] event=waiting`은 사용자 seek/초기 acquisition과 실제 재생 underrun을 구분해 집계한다.
5. Power Profiler에서 CPU/GPU/Network/Display 영향과 밝기·thermal·charging을 함께 기록한다. 총 배터리 퍼센트만 비교하지 않는다. 충전 중 overall system power가 0으로 보고될 수 있고, Xcode pairing이 SoC sleep을 방해할 수 있으므로 잠금 장기 테스트는 on-device Performance Trace도 사용한다. 서로 다른 기종의 power impact 값을 직접 비교하지 않는다.

### 적용한 Apple 공개 자료

- [Improving Your App’s Performance](https://developer.apple.com/documentation/xcode/improving-your-app-s-performance): 기준선·프로파일·변경·재비교 절차.
- [Understanding and Improving SwiftUI Performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance): 실제 view 업데이트 비용과 원인 graph 확인.
- [Reducing Your App’s Battery Use](https://developer.apple.com/documentation/xcode/reducing-your-app-s-battery-use): 필요 없는 작업/리소스 제거를 우선.
- [Reducing Networking and Bluetooth Power Usage](https://developer.apple.com/documentation/xcode/reducing-networking-and-bluetooth-power-usage): 작업 통합·연결/백그라운드 정책.
- [Reducing Disk Writes](https://developer.apple.com/documentation/xcode/reducing-disk-writes): write 양·빈도 측정과 기존 batch/checkpoint 정책 확인.
- [Configuring Your App for Media Playback](https://developer.apple.com/documentation/avfoundation/configuring-your-app-for-media-playback): playback session/background capability와 활성화 시점.
- [AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer): 시스템 transport/KVO/시간 관찰·queue 역할.
- [MetricKit](https://developer.apple.com/documentation/metrickit): 장기 on-device 진단/성능 자료. 이번에는 신규 subscriber를 도입하지 않았으며, 없는 payload로 결과를 만들지 않았다.
- [Power Profiler](https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler): subsystem 구분·반복 측정·연결/충전 영향.
- [ProMotion](https://developer.apple.com/documentation/quartzcore/optimizing-iphone-and-ipad-apps-to-support-promotion-displays): 시스템 프레임 스케줄링 우선. 120Hz 전역 상태 발행을 도입하지 않았다.

Apple 문서는 웹 도구의 Markdown content-type 제한 때문에 공식 Markdown 원문을 내려받아 읽었다. 신규 사용 API의 availability는 설치된 SDK header와 iOS Release 빌드로 확인했다. Apple Music의 비공개 구현을 근거로 삼지 않았다.
