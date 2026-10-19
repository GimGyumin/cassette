# Cassette F01–F22 구현 및 검증 결과

작성일: 2026-10-13. 대상: `/Users/kyumin/Cassette`의 기존 수정 사항을 포함한 작업 트리.

## 실제 완료 수준

F01–F22 전체를 검토하고 코드·회귀 테스트를 단계적으로 수정했다. 재생 제어는 기존 `PlayerService` actor에 유지하고 요청 검증, 확정된 표시 상태 전달, terminal 정리, 오류 정책, 엔진 기능 정책을 공통 경계로 모았다. 전면 재작성이나 외부 패키지 추가는 하지 않았다.

**최종 macOS 전체 테스트 1,121개 / 193 suites와 SwiftSonic 패키지 387개 / 120 suites가 통과했고, 최종 iOS 기기용 빌드가 성공했다.** 기준선은 macOS 1,083개였다. 최종 동시성 진단은 실제 소스 6개를 컴파일하는 독립 패키지에서 gate·cache·전송 coordinator·mailbox의 Thread Sanitizer 테스트 8개 / 3 suites 통과다.

**전체 완료 조건은 아직 충족하지 못했다.** iOS 전체 실행에서는 1,120개 중 테스트 정의 3개가 실패했다(8 expectations). divider fixture는 수정 후 통과했고 HTTP 전환은 기존 시간 기준으로 단독 통과했지만, Native PCM meter 테스트는 미해결이다. 이후 시뮬레이터 런타임이 조회되지 않아 최종 iOS 전체 재실행을 할 수 없었다. macOS gapless의 간헐적 시간 기준 초과도 관찰하여 검증 기록에 남겼다. 기기용 빌드 성공을 iOS 재생 검증 완료로 해석하면 안 된다.

자동 테스트가 확인하는 범위와 실기기 품질 보증은 다르다. Native 양의 ReplayGain 증폭, AudioStreaming의 item ID 없는 상태·오류 이벤트, 엔진 Range 스트리밍과 전체 파일 전송의 바이트 공유에는 제한이 남는다. 이 부분과 실제 배터리·무손실 출력·공간 음향·장시간 안정성을 완전 해결로 표시하지 않는다. Apple Music과 동등한 성능이라는 주장은 하지 않는다.

## 1. 작업 트리와 데이터 보호

- 감사 HEAD `e2cc0e5f6434c19eb8db88623723d6ae92f6b0fc`로 되돌리지 않고 작업 시작 시의 dirty tree를 기준으로 삼았다. 감사의 소스 해시와 실제 트리도 비교했다.
- 시작 시 소스·테스트·프로젝트·리소스 파일 941개를 `/tmp/cassette-hardening-baseline/sources.zip`에 보관했다. 같은 디렉터리에 기존 diff, status, hashes와 단계별 patch를 남겼다.
- 사용자 소스, 기존 미추적 파일, 영구 다운로드, 청취 기록을 삭제하지 않았다. Git reset/clean/강제 checkout, 저장소 초기화, CloudKit 활성화를 하지 않았다.
- `PlaybackSession`의 영구 모델 필드를 바꾸지 않았다. 기존 `id` 문자열에 계정·occurrence revision을 넣고 기존 무소속 세션은 그대로 보존한다. 설정에서 현재 서버를 명시적으로 확인한 경우에만 복사 복원한다.
- 공간 부족 때 재생성 가능한 DerivedData 컴파일 산출물과 이 작업에서 만든 시뮬레이터를 정리했다. 소스·저장 데이터·기준선 백업은 보존했다.
- [변경 파일 및 SHA-256 목록](implementation-manifest.json)은 작업 시작 스냅샷과 비교한 소스·테스트 변경만 담는다. 기존 사용자 변경을 이번 작업의 변경으로 계산하지 않는다. Xcode의 사용자 UI 상태 파일은 이 목록에서 제외한다.

## 2. F01–F22 처리 현황

`구현 완료`는 해당 코드 결함의 수정과 명시한 자동 검증을 의미한다. 모든 기기·출력 경로의 실제 재생 품질을 검증했다는 뜻은 아니다. 경로는 프로젝트 루트 기준이다.

| ID / 상태 | 수정한 파일·함수와 구체적 변경 | 테스트와 검증 범위 |
|---|---|---|
| F01 구현 완료 | `PlayerService+Engine.swift`: `shouldRecoverFromLocalMedia`, `recoverAcquiringPlaybackFromLocalMedia`. 초기 acquisition과 중간 stalled 복구를 구분한다. 이미 진행한 시계가 로컬 복구를 막지 않게 하고 위치·epoch·명령·재생 의도를 확인한다. | `AuditPlaybackHardeningTests.stalledLocalRecoveryAcceptsAnEstablishedClockButNotPausedIntent`, 기존 `PlaybackRecoveryPositionTests`. 진행 위치와 Pause의 복구 차단 검증. 실제 네트워크 단절 직후 파일 전환의 청감은 실기기 필요. |
| F02 구현 완료 | `PlayerService+Engine.swift`: stall refresh 실패를 `finishPlaybackFailure`로 종료한다. 한 번의 복구와 명확한 terminal 경로로 무한 buffering을 방지한다. | `failedStallRefreshTerminatesAndRetainsPosition`: 실패 후 위치 60초 보존, progress Task 종료, 오류 표시. |
| F03 구현 완료 | `PlayerService+Controls.swift`, `+Queue.swift`: 일반 자동 연장과 큐 끝 fallback이 같은 `allowsAutoExtend` 정책을 사용한다. 내부에서 설정을 켜지 않으며 늦은 추천은 새 명령·계정·큐 상태를 덮어쓰지 못한다. | `disabledAutoplayNeverFetchesOrChangesPreference`, `lateSmartShuffleDoesNotUndoStop`, 기존 큐·repeat 테스트. |
| F04 구현 완료 | `PlayerService+Reporting.swift`: monotonic 청취 구간과 occurrence별 기록 중복 방지. `PlayerService+Commit.swift`: terminal 정리와 확정된 Widget 상태 전달. `+Engine`, `+Controls`, `+AudioSession`: audible 확인·대기·인터럽션에 따라 구간 시작/종료. | `terminalFailureClosesTheListeningSegmentAndRejectsLateConfirmation`, 기존 통계·Scrobble·cold resume 테스트. Stop 시 outgoing 구간 기록; 같은 실패 반복 시 중복 누적 방지. |
| F05 구현 완료 | `PlayerService+Commit.swift`: `beginSystemInterruption`이 hard pause 지연 전에 command를 무효화하고 미완료 play/seek/acquisition을 취소한다. 사용자 의도와 interrupted 상태를 분리한다. | `interruptionInvalidatesAResolverThatIgnoresCancellation`: 취소를 무시하는 resolver를 늦게 완료시켜도 재생 불가. 실제 통화·Siri·알람 인터럽션은 기기 검증 필요. |
| F06 구현 완료 | `AppContainer.migratePlaybackEventsIfNeeded`: fetch 오류와 빈 배열을 분리한다. 읽기·저장이 성공하기 전 완료 marker를 쓰지 않는다. 원본 기록 보존 및 ID 중복 회피 유지. | `migrationReadFailureDoesNotMarkCompletion`: 읽기 실패 후 marker 없음, 다음 정상 실행으로 재시도. 기존 migration 테스트 유지. |
| F07 구현 완료, legacy 복원은 사용자 선택 | `PlaybackCheckpointIdentity.swift`, `PlaybackSessionService`: 계정·track ID·큐 index·revision으로 save/checkpoint를 검증한다. `PlayerService+Session`: 계정별 자동 복원. `LegacyPlaybackSessionSection`: 소속 불명 세션의 명시적 복사 복원. | `PlaybackSessionIdentityTests`: 다른 계정·곡·동일 index의 다른 occurrence checkpoint 거부, 원본 legacy 행 보존, 디스크 store 재개방. persisted schema 변경 없음. |
| F08 구현 완료, 식별 정보 한계는 F15 | `PlaybackContext`, `PlaybackAuthority`, `commitPresentation`; Controls/Transition/Queue/Gapless/Seeking/Session/AudioSession 경로에 command·epoch와 결과 적용 검증. Library 추천은 원래 client·account token 유지. 다운로드 설치도 account revision 확인. | `oldPresentationCannotCommitAfterPause`, 늦은 Smart Shuffle/인터럽션 resolver, 기존 cold-resume·seek·계정 교체 회귀 테스트. actor isolation에만 의존하지 않는다. |
| F09 구현 완료, 실기기 reset 검증 필요 | `resetAudioObjectsAfterMediaServicesReset`: 명령·세대 무효화, 큐·위치 보존, paused 확정. `AudioStreamingPlayerEngine`: 실제 AudioPlayer 교체; ReplayGain EQ node 재구성. Native facade는 이전 AVPlayer 해제. 다음 사용자 resume에서 gain 재적용. | `resetRebuildsAudioObjectsAndRetainsAPausedQueue`: 객체 reset, 이전 native 이벤트 거부, 자동 resume 없음, 큐·위치 보존. 실제 media server 재시작은 미실행. |
| F10 구현 완료 | `PlayerService+Transition.swift`: 같은 track ID라도 다른 queue index면 정상 선택. 현재 occurrence의 불필요한 중복 요청 차단은 유지. | `duplicateSongAtAnotherQueueIndexIsASelection`, 계정/occurrence checkpoint 테스트. |
| F11 플랫폼 범위 내 구현, 실제 출력 검증 필요 | `EngineCapabilities`, `PlaybackGainState`, `ReplayGainService.gainState`, `PlayerService.applyReplayGain`: 계산 정책 공유. AudioStreaming은 기존 EQ gain, Native는 AVPlayer volume으로 음수 gain 감쇄. 양수 gain은 unity 유지 및 지원 불가 표시. fade/user volume과 gain 인자를 분리한다. | `EngineCapabilityConsistencyTests`와 기존 ReplayGain 14개 계산 테스트. clipping 계산, 감쇄 계수, fade 중 볼륨, 설정 해제, 오래된 gain 거부. 포맷·채널·sample rate 강제 변환 없음. Native 양수 증폭을 지원한다고 주장하지 않음. |
| F12 구현 완료, 출력 경로 검증 필요 | `EngineCapabilities.supportsSequentialFades`, `PlayerService+Crossfade`, `+Transition`, `+Engine`: Native fade-in 배제 제거, iOS wireless fade 양방향 우회 유지. 엔진 시작 전 0 volume 설정, 실제 재생 확인 후 fade-in. monotonic 시간 및 command guard. | `bothEnginesShareFadeRoutePolicy`, `fadeInWaitsForAudibleConfirmationAndPauseRestoresVolume`, 기존 curve/threshold/gapless 테스트. 설정 안내를 순차 fade로 정확히 변경; 두 곡 겹침 재생을 새로 구현한 것은 아님. |
| F13 구현 완료 | `PlayerService+Engine.handleSystemEngineEvent(.codec)`: AAC/MP3라는 이유만으로 transcoded를 켜지 않는다. source의 전송 정책과 actual codec을 분리하며 `PlaybackDetails`에서 별도 표시. | `originalLossyCodecDoesNotBecomeTranscoded`, 기존 `AudioQualityClassifierTests`, `PlaybackDetailsTests`. |
| F14 구현 완료 | `WidgetSyncService.onPlayStateChanged`: 매번 최종 데이터를 저장하고 WidgetCenter reload만 throttle한다. trailing reload 및 publication sequence 검증. Player는 실제 확정 상태를 전달한다. | `rapidWidgetChangesPersistTheFinalValue`: 빠른 Pause→Play 뒤 저장 값 확인. 타임라인 갱신 시점 자체는 WidgetKit 시스템 정책 영향을 받음. |
| F15 부분 해결 | `PlaybackFailure`, 순수 `PlaybackRecoveryPolicy`, native `.failed` 이벤트: NSError/URL/HTTP/AVFoundation/AudioStreaming/Cassette/SwiftSonic/Jellyfin 원인을 보존·분류. native generation+item ID, AudioStreaming callback receipt context와 엔진 객체 identity 검증. | `PlaybackFailureAndPublicationTests`: wrapping된 인증 오류, 취소, codec 오류, bounded retry, 오래된 오류 거부. **AudioStreaming의 state/error API에는 originating entry ID가 없어 내부 지연 이벤트의 진짜 발생 occurrence를 완전히 복원할 수 없음.** SDK 포크는 하지 않음. |
| F16 구현 완료 | `PlaybackPublication`, `NowPlayingService+Update`: command·epoch·sequence와 MainActor revision을 함께 확인한다. full metadata, elapsed/rate, track change, stop, artwork 및 iOS 27 MediaSession 갱신에 적용. | `oldPositionAndFullSnapshotCannotOverwriteTheNewOccurrence`, `olderPublicationWithinTheSameCommandIsRejected`; 늦은 rate/stop도 거부. 기존 artwork/remote command 테스트 유지. |
| F17 구현 반영, iOS 검증 미완료 | `PlaybackMeterMailbox`, `PlaybackBeatMeter`: callback의 배열/Task 생성을 SIMD4와 고정 atomic mailbox로 교체. writer와 reader는 같은 atomic guard를 한 번만 시도한다. 경쟁 시 visual sample을 건너뛰며 오디오를 기다리게 하지 않는다. snapshot의 lane·generation을 같은 경계에서 읽는다. MainActor publisher 한 개는 화면·구독·전력 정책이 허용할 때만 동작. | RMS 계산 일치, 다중 writer/reader와 generation 일관성 stress, 핵심 소스 TSan 8개 통과. macOS native PCM 테스트 통과. **iOS native PCM은 clock 0/buffering 상태에서 실패하며 원인 미확정**이다. 원래 meter로 교체한 비교에서도 재현되지만 이것만으로 기존 버그나 플랫폼 버그라고 확정하지 않는다. AudioStreaming 내부 frameFiltering lock 및 AVFoundation 내부 동작까지 무할당·무잠금으로 보증하지 않음. 실제 underrun/CPU 측정 필요. |
| F18 구현 완료 | `CoverDecodeGate`, `ArtworkImageCache`, `ExternalArtworkCache`: 대기 중 취소 시 continuation 완료, 취소된 permit을 작업에 쓰지 않음, decode 직전 cancellation/generation 확인, 정상 획득한 슬롯만 반환. 공유 producer는 개별 view 취소로 중단하지 않음. | `ArtworkGateAndMetadataBoundsTests`: busy slot을 기다리지 않는 취소, 빈 permit 소비 방지. 최종 전체 빌드의 unused acquire 경고를 통해 추가 fetch 경로도 수정. |
| F19 구현 완료, 튜닝 실측 필요 | `ExpiringBoundedCache`, `LibraryService`: album/artist/info 상세 cache를 LRU 개수·record 비용·300초 TTL로 제한. oversized 응답은 반환하지만 보관하지 않음. memory warning에서 상세 cache 정리. | `metadataRetentionIsBoundedAndExpiresWithoutClockChanges`: 크기, eviction, TTL, 과대 항목 검증. 한도는 bytes 측정값이 아닌 record 수 정책이며 기기·라이브러리별 튜닝 필요. |
| F20 구현 완료, 대규모 실측 필요 | `AppContainer`: migration을 detached utility worker로 이동, StatsService는 준비 완료 후 접근. `LibraryIndexService.runRebuild`, `StagedFileWrite`: JSON encode/대형 write는 worker, MainActor에서는 현재 generation 확인 후 atomic rename만 수행. | `migrationCreatesAndFetchesContextsOnTheWorker`, `discardedStagingCannotReplaceTheCurrentIndex`, 기존 인덱스 계정 취소 테스트. 작은 rename의 파일 시스템 지연과 전체 migration 배열의 peak memory는 남은 측정 항목. |
| F21 부분 해결 | `MediaTransferCoordinator`, Player cache/prefetch·DownloadService·AppContainer: 계정 revision/곡/정규화된 실제 request별 whole-file 전송 조율. 영구 다운로드가 matching cache를 supersede하고 취소 종료를 기다림. 보존된 완료 cache 파일은 검증 후 복사 재사용. background URLSession/저널 유지. | `MediaTransferCoordinationTests`: format/Range/account 구별, draining, 여러 consumer 중 하나 취소, cache 교체 검출. **엔진의 독립 Range 스트리밍과 전체 파일의 물리적 전송량까지 하나로 합치지는 않음.** AVPlayer 내부 캐시 공유용 공개 API가 없고 proxy/resource-loader 재작성은 회귀 위험이 커 도입하지 않음. |
| F22 구현 완료, UI 실측 필요 | `LyricKaraokeSpacing.displayTexts`, `WordWrapLayout.Cache`: line 공백/CJK 판단 한 번, text layer 재사용, subview measurement/width별 row 캐시. timing 및 sync cadence는 유지. | 다국어/CJK/원문 공백/보조 보컬 테스트, 기존 TTML/LRC/translation/lyrics presentation 테스트. Dynamic Type·긴 번역·실제 SwiftUI layout 비용은 기기 검증 필요. |

## 3. 상태와 오류 처리의 책임 경계

변경 전에는 비동기 소스 해석, engine callback, UI 상태, 재시도, 통계가 서로의 필드를 직접 조정했다. actor 내부에서도 `await` 전후에 새 명령이 들어오면 오래된 결과를 적용할 수 있었다.

변경 후 계약은 다음과 같다.

```text
사용자/시스템 명령
  → PlayerService: intent, command, epoch 소유
  → engine / resolver / 저장소 작업
  → 결과의 context·generation·item 식별자 검증
  → commitPresentation: 현재 권한 아래에서 UI 상태 확정
  → 버전이 있는 Now Playing·Widget·session publication

실패 이벤트
  → PlaybackFailure 분류
  → PlaybackRecoveryPolicy의 순수 결정
  → PlayerService가 제한된 복구 또는 terminal 정리 실행
  → 동일한 context 검증과 표시 상태 commit
```

`PlaybackAuthority`의 짧은 mutex는 MainActor로 이동하는 사이의 check-then-write 틈을 막는다. 오디오 render callback에서는 사용하지 않는다. `PlaybackMeterMailbox`의 실시간 전달과는 별도다. 정상 start/pause/resume 경로는 오류 정책을 거칠 필요가 없다.

UI가 사용하는 기존 `PlayerState`, 공개 player protocol, engine protocol은 유지했다. 별도 Queue/Session/UI 관리자 actor를 다수 만들지 않았다. `PlaybackContext`는 제어 권한, `PlaybackPublication`은 비동기 외부 표시 순서, `PlaybackCheckpointIdentity`는 영구 저장의 대상 식별을 담당한다. 세 타입의 수명·목적이 달라 하나의 전역 숫자로 합치지 않았다.

오류 정책 변경은 `PlaybackFailure`와 `PlaybackRecoveryPolicy`에서 시작하고, terminal 정리는 `finishPlaybackFailure`를 재사용한다. 새로운 비동기 제어 경로는 context를 캡처하고 매 suspension 이후 유효성을 확인한 뒤 commit해야 한다. source metadata나 queue 편집 등 모든 종류의 상태 변경을 하나의 거대한 reducer로 바꾸지는 않았다. 기존 동작을 유지하면서 재생 전환의 핵심 경계를 통일했다.

잔여 결합은 native/AudioStreaming gapless handoff, seek offset, session route 처리다. 이 경로에는 실제 엔진별 제약이 있으므로 이름만 다른 추상 계층으로 가리지 않았다. 신규 엔진 기능은 `EngineCapabilities`에 한계를 먼저 기술하고 테스트와 표시 상태를 함께 바꾸는 것이 원칙이다.

## 4. 성능 변경과 아직 측정하지 않은 것

| 영역 | 코드에서 확인 가능한 변경 | 성능 수치의 한계 |
|---|---|---|
| CPU/오디오 | 분석 callback에서 Task·동적 배열 생성 제거, 고정 SIMD/atomic 전달, 기존 분석 주기 유지 | 엔진 내부 allocation/lock 및 실제 underrun은 미측정 |
| 배터리 | 숨겨진 beat UI의 publisher 취소, terminal 작업 정리, 중복 whole-file transfer 조율 | mW, wakeup/s, 장시간 배터리 소모 개선률은 산출하지 않음 |
| 메모리 | 상세 metadata cache의 수명·개수·record 비용 한도, producer/continuation 정리 | peak RSS/physical footprint, 장시간 plateau 미측정. TTL은 접근 시 만료 제거이며 memory warning도 처리 |
| Main Thread | migration의 SwiftData context를 worker에서 생성, JSON encode/대형 쓰기 worker 이동 | atomic rename 및 상태 commit은 MainActor. 디스크 지연이 전혀 없다고 주장하지 않음 |
| SwiftUI/가사 | 전체 line 검사 반복 감소, layout measurement 재사용 | 실제 frame time, hitch ratio, Dynamic Type 조합 미측정 |
| 네트워크 | 동일 request의 cache/permanent 중복 조율과 완료 파일 재사용 | 엔진 Range traffic은 별도. 전송량 절감률·네트워크 지연 수치 미산출 |
| 품질/음량 | Native 감쇄와 지원 한계 표시, 두 엔진의 fade 정책 일치 | 실제 출력 sample/채널·Atmos·gapless 청감·AirPlay 볼륨 동작은 실기기 필요 |

기존 buffer 크기, 가사 동기화 주기, gapless 정책, server quality 선택을 측정 없이 공격적으로 바꾸지 않았다. 캐시 record 한도는 유한한 보존 정책이며 최적값이 실측으로 증명되었다고 볼 수 없다.

공식 API 근거: AVPlayer의 volume은 system volume에 상대적인 0–1 범위이므로 Native 양의 gain을 구현했다고 표시하지 않았다. [AVPlayer.volume](https://developer.apple.com/documentation/avfoundation/avplayer/volume), [AVAudioUnitEQ.globalGain](https://developer.apple.com/documentation/avfaudio/avaudiouniteq/globalgain).

Media Services reset 뒤에는 오디오 객체와 session 설정을 재구성하고 사용자 동작을 기다린다. [Apple mediaServicesWereResetNotification](https://developer.apple.com/documentation/avfaudio/avaudiosession/mediaserviceswereresetnotification). Render callback에서 blocking·allocation을 피해야 한다는 기준으로 앱의 meter 경로를 바꿨다. [Apple QA1715](https://developer.apple.com/library/archive/qa/qa1715/_index.html).

## 5. 빌드·테스트 및 환경

Xcode 27.2 beta, macOS host, iOS 27.2 SDK/runtime에서 검증했다. 후반에 runtime이 unavailable 상태가 되어 iOS 실행 검증이 중단되었다. 세부 단계는 [구현 로그](IMPLEMENTATION-STATUS.md), 최종 실행 결과와 제약은 [검증 증거](verification-results.md)에 기록한다.

```sh
xcodebuild test -project Cassette.xcodeproj -scheme CassetteTests \
  -destination 'platform=macOS' -derivedDataPath .derivedData-test \
  -disableAutomaticPackageResolution -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO

swift test --package-path Packages/SwiftSonic

xcodebuild build -project Cassette.xcodeproj -scheme Cassette \
  -destination 'generic/platform=iOS' -derivedDataPath .derivedData-audit-ios \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO
```

검증 후반에는 Xcode가 원래 프로젝트의 NSFileCoordinator 잠금에서 대기했다. 실제 소스는 그대로 두고 `/tmp/cassette-validation/Cassette.xcodeproj`에 project/공유 scheme만 복사한 뒤 원본 소스·테스트·패키지를 symlink하여 실행했다. 따라서 최종 로그의 프로젝트 경로는 위 명령과 다르지만 테스트 대상 소스는 동일하다. 이 복사본의 빠진 위젯/Info.plist 연결로 발생한 첫 빌드 실패도 연결 후 재검증했다.

기존 테스트의 기대값을 약화하지 않았다. `AlbumDetailOfflineTests`의 divider fixture는 작업 전부터 달랐던 플랫폼별 높이(iOS 0.5pt, macOS 1pt)를 정확하게 검증하도록 수정했다. native PCM 및 gapless/startup 시간 기준은 그대로 유지했다. 기존 restore fixture에 account identity를 제공하고 native 실패 이벤트 fixture에 typed failure를 추가했다. 테스트 stub에는 resolver/추천의 완료 순서를 제어할 수 있는 hook을 추가했다. Phase 1에서는 네 회귀 테스트의 다섯 expectation 실패를 확인한 뒤 수정했다. Phase 2의 pause-during-recovery 회귀는 기존 assertion을 유지한 채 수정했다.

## 6. 호환성과 남은 검증 계획

공개 제어 API와 큐/셔플/반복/자동 연장, 파일 캐시·영구 다운로드·background journal, 가사 timing, 서버 요청 품질 선택을 유지했다. ReplayGain Native 감쇄를 위해 PCM 변환·downmix·새 audio mix/tap을 추가하지 않았다. 현재 Crossfade 설정은 기존 순차 fade 동작을 유지하고 안내만 정확히 했다.

다음 작업은 출시 전 실기기에서 같은 조건으로 비교해야 한다. 기준 소스/개선 소스, 음악 bytes, 서버 버전, cache 상태, 기기/OS, 출력 route, 전력·thermal·화면 상태를 고정하고 각각 반복 측정한다. 평균만 아니라 p50/p95/p99와 실패·underrun 횟수를 함께 기록한다.

| 시나리오 | 수집 지표·도구 | 회귀 판단 |
|---|---|---|
| ALAC/FLAC/Hi-Res 연속 2–8시간, 잠금 화면 | Time Profiler, Allocations, Leaks, Power Profiler; footprint/CPU/wakeup/underrun 추이 | 큐·위치·통계 일관성, 지속 메모리 증가 없음, 오류 후 감시 Task 잔존 없음 |
| 같은 앨범 gapless, 동일 곡 중복 queue, Repeat One/All | 전환 signpost/출력 캡처, 실제 오디오 간격과 엔진 restart 여부 | 불필요한 재시작·중복 완료·첫 sample 누락 없음 |
| 빠른 Play/Pause/Skip, 반복 Seek | Swift Concurrency, Time Profiler, Hangs, command→audible/seek settle 지연 | 마지막 명령만 확정, UI/실제 clock 동일, Pause 이후 재생 없음 |
| Wi-Fi/셀룰러 차단·복구, 401/404/잘린 파일 | Network, engine error log, 요청/전송 bytes와 retry 횟수 | 제한된 복구 종료, 인증 오류 불필요 재시도 없음, 현재 재생 우선 |
| 통화·Siri·route 변경·Media Services Reset | session notification/engine 세대·snapshot 기록 | 이전 callback 거부, 의도 없는 재개 없음, 다음 사용자 명령으로 복구 |
| AirPods/Bluetooth/AirPlay, Atmos/multichannel | 실제 route/채널/출력 레벨 및 청취 비교 | 포맷·공간 음향 보존, gain/fade 정책과 실제 효과 일치 |
| 긴 TTML/LRC/번역/보조 보컬, Dynamic Type | SwiftUI Instrument, Hangs, Time Profiler | 가사 sync 보존, layout/문자열 hot spot·hitch 확인 |
| 대규모 라이브러리 스크롤·화면 반복 진입·memory warning | Allocations/Leaks, SwiftUI, Network, main-thread 시간 | cache 한도/재요청 균형, 객체·Task·continuation 누적 없음 |
| cache/자동 다운로드/수동 다운로드 동시 실행 | Network, background journal relaunch, 실제 Range 응답 | 동일 포맷만 병합, 취소·완료·오프라인 install 보존 |

Thread Sanitizer는 핵심 코드의 독립 진단 패키지에서 실행했다. 전체 앱 TSan 첫 빌드는 디스크 부족으로 중단되어 통과로 계산하지 않는다. Main Thread Checker의 전체 사용자 시나리오 및 Swift Concurrency Instrument는 미검증이다. Debug 진단 실행 시간을 최적화 성능 지표로 쓰지 않는다. 전력 비교는 Release 빌드 실기기에서 별도 수행한다. Instruments 수치가 확보되기 전 CPU·배터리 개선율을 보고하지 않는다.

## 7. 단계별 적용과 후속 우선순위

1. Phase 0: 현재 트리/감사 일치 확인, 기존 1,083개 기준선 및 소스 보존.
2. Phase 1: 복구 조건·실패 종료·자동 연장·migration·중복 occurrence·품질 표시·Widget 결함 및 재현 테스트.
3. Phase 2–4: context 권한/commit, intent와 actual 상태 분리, 청취 구간/terminal 정리, typed failure와 순수 정책, 버전이 있는 외부 표시.
4. Phase 5: 계정·occurrence 저장 식별과 비파괴 legacy 복원, media reset 객체 재생성.
5. Phase 6: 실시간 meter 전달, 취소 gate, bounded cache, worker I/O, whole-file 전송 조율, 가사 계산/측정 재사용.
6. Phase 7: 엔진 기능 정책, Native 감쇄와 명시적 한계, 순차 fade 일관성.
7. Phase 8: macOS 전체·iOS 기기 빌드·독립 패키지·핵심 TSan·시작 Time Profiler 실행. iOS 전체 통과와 실기기 성능 검증은 미완료로 인계한다.

다음 최우선은 **iOS runtime 복구 후 Native PCM 실패 원인 규명과 전체 재실행, 간헐적 gapless 지연 재현, 실기기 출력·장시간 재생 검증**이다. 그다음 AudioStreaming upstream의 originating item 식별 가능성을 확인하고, 네트워크 trace가 실제로 중복 전송 병목을 보일 때에만 Range 공유 구조를 별도 설계한다. 이 두 부분을 해결하려고 지금 engine/proxy를 전면 교체하면 회귀 위험이 이득보다 크다.

유지보수 검토 기준은 파일 수가 아니다. 신규 오류 하나를 추가할 때 정상 start/seek/EOF/UI를 동시에 바꿔야 하는지, terminal 정리 목록이 복제되는지, 새 비동기 결과에 context 검증이 있는지, Native 기능 한계를 UI가 정확하게 설명하는지를 본다. 이번 구현은 그 변경 지점을 줄였지만, 실기기 성능과 모든 외부 SDK의 내부 이벤트 순서까지 입증한 완제품 인증은 아니다.
