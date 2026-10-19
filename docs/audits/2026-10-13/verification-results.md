# 검증 기록 — 2026-10-13

이번 작업에서 실행한 검증의 최종 기록이다. **iOS 전체 통과와 실기기 승인 조건은 미충족**이다. 구현 완료, 자동 테스트 통과, 실제 출력·성능 검증을 서로 구분한다.

## 확정된 결과

| 실행 | 결과 | 원본 로그 |
|---|---|---|
| 작업 전 macOS 전체 | 1,083 tests 통과 | `/tmp/cassette-implementation-baseline.log` |
| Phase 1 | 28 tests / 4 suites 통과 | `/tmp/cassette-phase1-green.log` |
| Phase 2 | 38 tests / 5 suites 통과 | `/tmp/cassette-phase2-green.log` |
| Phase 3 | 27 tests / 5 suites, iOS build 통과 | `/tmp/cassette-phase3-green.log`, `cassette-phase3-ios.log` |
| Phase 4 전체 | 1,100 tests / 188 suites, iOS build 통과 | `/tmp/cassette-phase4-full.log`, `cassette-phase4-ios.log` |
| Phase 5 | 39 tests / 5 suites, iOS build 통과 | `/tmp/cassette-phase5-first.log`, `cassette-phase5-ios.log` |
| Phase 6 cache/gate | 16 tests / 3 suites 통과 | `/tmp/cassette-phase6-cache-first.log` |
| Phase 6 media/transfer | 20 tests / 3 suites 통과 | `/tmp/cassette-phase6-transfer-second.log` |
| Phase 6 coordinator | 17 tests / 4 suites 통과 | `/tmp/cassette-phase6-coordinator.log` |
| Phase 6 다국어 가사·성능 경로 | 5 tests 통과, iOS build 통과 | `/tmp/cassette-phase6-lyrics-green.log`, `cassette-phase6-ios.log` |
| Phase 7 gain/fade/gapless/session | 30 tests / 5 suites 통과 | `/tmp/cassette-phase7-first.log` |
| Phase 7 추가 fade | 5 tests 통과, iOS build 통과 | `/tmp/cassette-phase7-fade.log`, `cassette-phase7-ios.log` |
| Phase 8 macOS 전체 | **1,121 tests / 193 suites 통과** | `/tmp/cassette-phase8-final-verified-macos.log` |
| SwiftSonic 독립 package | **387 tests / 120 suites 통과** | `/tmp/cassette-phase8-swiftsonic.log` |
| Phase 8 generic iOS 기기 build | **최종 소스 BUILD SUCCEEDED** (서명 비활성화) | `/tmp/cassette-phase8-ios.log`, `/tmp/cassette-phase8-final-device-build.log` |
| 최종 핵심 소스 Thread Sanitizer | **8 tests / 3 suites 통과, race 보고 없음** | `/tmp/cassette-phase8-core-tsan-current.log` |

중간 실패를 숨기지 않았다. Phase 1 red 테스트, Phase 2 pause-during-recovery, Phase 6 optional exclusivity 컴파일 오류와 가사 fixture enum 오타는 각각 수정 후 해당 검증을 재실행했다. 최종 전체 빌드에서 발견한 gate acquire 반환값 미사용도 수정 후 전체 테스트를 다시 통과했다.

## iOS Simulator 검증 — 미완료

iPhone 17 Pro / iOS 27.2, 새 감사 전용 simulator에서 전체 **1,120 tests / 193 suites**를 실행했다. 3개 테스트 정의가 실패했고 8 expectation issues가 기록됐다. 이는 최종 iOS 전체 통과 기록이 아니다.

- `albumSeparatorRendering`: 네 조합에서 iOS 0.5pt divider의 2x 높이 1px를 macOS의 2px와 비교했다. 작업 시작 백업에서도 제품의 iOS 0.5pt 구현은 동일했다. UI 코드는 변경하지 않고 플랫폼별 정확한 픽셀 assertion으로 교정했다. width/contrast assertion은 유지했다. 후속 해당 suite는 통과했다.
- `NativePlaybackMeterTests.nativePCM`: meter 값 0, 두 assertion 실패. 단독 실행과 명시적 audio session 활성화에서도 같았다. 미터 구현만 시작 ZIP의 원본으로 교체한 비교에서도 `clock=0, state=buffering, duration=0, codec=PCM`이며 tap의 prepare callback 미진입이 관찰됐다. **이것은 새 mailbox만의 문제라는 가설을 약화하지만, 원인을 플랫폼이나 기존 코드로 확정하는 증거는 아니다.** 탭 연결 시점 변경 실험은 런타임 부재로 실행되지 않았고 채택하지 않았다. 진단용 session 활성화·print·atomic probe도 모두 제거했다. 테스트는 원래 강도 그대로 남아 있으며 미해결이다.
- `progressiveHTTPPreparesTheNextStreamBeforeEOF(mp3)`: 2초 startup 기준과 후속 handoff 대기 실패. 다른 컴파일·프로파일링 작업 없이 실행한 두 codec 사례는 원래 시간 기준 그대로 통과했다. 전체 재실행 확인은 남아 있고 제한 시간을 늘리지 않았다.

후반부에는 `xcrun simctl list runtimes`가 빈 목록, 기기는 `Unavailable: ...iOS-27-2`로 조회됐다. 동일한 실행 권한으로 확인했으며 runtime image 목록도 비어 있었다. 사라진 원인을 추측하지 않는다. 마지막 재실행은 테스트가 시작되기 전에 runtime/deployment-target 불일치로 종료됐다. runtime 설치·업데이트나 테스트 skip으로 결과를 바꾸지 않았다. 최종 mailbox 보강 후 iOS 실행 검증도 남는다.

로그: `/tmp/cassette-phase8-ios-tests-retry.log`, `/tmp/cassette-phase8-ios-audio-isolated.log`, `/tmp/cassette-phase8-ios-fixtures.log`, `/tmp/cassette-phase8-ios-original-meter-final.log`, `/tmp/cassette-phase8-ios-native-cause-retry.log`, `/tmp/cassette-phase8-ios-native-mix-order.log`.

## macOS 반복 실행의 시간 민감 사례

최종 소스의 전체 1,121개는 모두 통과했고 Native PCM도 통과했다. 바로 앞 전체 실행에서는 `GaplessContinuityTests.continuousClock(native: true)`가 한 번 실패했다: clock loss 0.27649초, 기존 기준 `< 0.08초`. 최종 재실행에서는 같은 assertion으로 약 0.0000117초를 기록했다. 두 실행의 native engine/tap 및 해당 테스트 코드는 같다. 미터 mailbox의 마지막 보강은 최종 실행에 포함됐다. 이 수치를 보강의 성능 향상으로 해석하지 않는다.

이 편차의 원인은 확정하지 못했다. 한 번의 최종 통과만으로 gapless 지연이 항상 해결됐다고 판단하지 않는다. 실기기 및 부하를 통제한 반복 재현이 필요하다. 임계값·assertion을 완화하지 않았다. 실패 로그는 `/tmp/cassette-phase8-final-current-macos.log`, 최종 통과 로그는 `/tmp/cassette-phase8-final-verified-macos.log`다.

## 진단 도구

- **Time Profiler:** macOS Debug 앱을 `--cassette-ui-testing`의 메모리 저장소로 실행한 trace를 저장하고 XML export로 확인했다. 요청한 5초 기록의 전체 trace 구간은 6.784386초이며 time-profile 행 633개 중 Main Thread 샘플은 595개였다. 기록 구간 길이는 앱 실행 지연이 아니고, sample 수는 CPU 점유율이 아니다. 이 자료는 시작 경로 관찰용이며 재생 부하·Release·기준선과 비교한 성능 수치가 아니다. trace: `/tmp/cassette-phase8-startup-retry.trace`; toc 및 sample XML도 같은 prefix로 보관한다.
- 첫 Time Profiler 시도는 trace 저장/패키지 lock 오류로 실패했다. 공간 확보 후 재시도에서 저장 성공을 확인했다. 유효하지 않은 첫 trace를 성능 자료로 사용하지 않는다.
- **Thread Sanitizer:** 전체 앱 첫 빌드는 `IO failure on output stream: No space left on device`로 중단됐다. race 발견이나 통과로 계산하지 않는다(`/tmp/cassette-phase8-tsan.log`). 이후 production 소스 6개를 SHA-256으로 일치시킨 독립 Swift 패키지에서 기존 gate/cache/transfer 테스트와 mailbox stress를 실행했다. **8 tests / 3 suites가 통과했고 race 보고는 없었다.** 최종 mailbox 보강도 포함한다. `PlaybackContext`는 의존 소스로 컴파일하며, 이 진단의 동시 실행 coverage는 gate·metadata cache·transfer coordinator·mailbox이다. 전체 앱, SwiftData, AVFoundation 및 SDK 내부의 TSan 통과를 의미하지 않는다.
- Main Thread Checker의 전체 사용자 흐름과 Swift Concurrency Instrument는 미검증이다. 임시 iOS session 활성화 fixture에서 Main Thread hang-risk 진단이 나왔으며 효과가 없어 해당 실험 코드는 제거했다.
- Allocations/Leaks/Power/SwiftUI/Swift Concurrency/Network의 실제 재생 시나리오 전후 측정은 수행하지 않았다. Time Profiler 기본 템플릿에 포함된 Hangs 자료만으로 장시간 hitch/누수/전력 검증을 대체하지 않는다.
- 기기 목록에서 iPhone 16 Pro, iPad Pro, Apple Watch가 모두 offline이었다. 따라서 Bluetooth/AirPlay/Atmos, 실제 무손실 출력, 장시간 백그라운드 전력 비교는 미실행이다.

## 환경 문제와 경고

- 디스크 공간이 여러 차례 부족해 simulator/TSan 빌드가 중단되었다. 이번 작업의 simulator와 재생성 가능한 DerivedData 캐시·컴파일 산출물만 정리했고 소스·사용자 저장 데이터·시작 백업은 보존했다.
- 원래 `.xcodeproj` 읽기가 NSFileCoordinator에서 대기한 것을 `sample`로 확인했다. `/tmp/cassette-validation`에 project/shared scheme만 복사하고 실제 소스·테스트·패키지를 원본에 연결해 우회했다. 앱 코드의 lock 문제가 아니다.
- `com.apple.linkd.autoShortcut` XPC 4097과 일부 AVFoundation/AudioQueue 진단은 기준선/테스트 환경에서도 나타난다. clean compiler 성공과 이 시스템 로그를 구분한다.
- 최종 macOS 및 iOS 기기용 빌드 로그에서 compiler `warning:` 또는 `error:` 진단은 없었다. 의도적으로 오류를 주입하는 테스트 로그와 시스템 XPC 진단은 compiler 결과와 분리했다. `git diff --check`도 통과했다.
- 실제 시뮬레이터 오디오 실패는 위 별도 항목에 기록한다. 테스트 통과 수만으로 이 실패를 덮지 않는다.

## 최종 집계와 남은 승인 조건

- macOS `CassetteTests`: 최종 1,121 통과 / 0 실패. 직전 반복 실행의 gapless 1개 실패는 위에 보존했다.
- SwiftSonic: 387 통과 / 0 실패.
- 핵심 코드 TSan: 8 통과 / 0 실패. 전체 앱 TSan은 빌드 중단으로 미실행.
- iOS 전체: 실행한 1,120개 중 테스트 정의 3개 실패, 8 issues. 후속 부분 실행으로 divider와 HTTP 사례가 통과했으나 Native PCM 1개는 미해결. 최종 전체 재실행 불가.
- `CassetteUITests` 별도 UI 자동화 scheme: 미실행. 위 `CassetteTests` 수에 UI journey나 launch-performance XCTest를 포함하지 않는다.
- 실기기 오디오·장시간 백그라운드·전력·출력별 검증: 미실행. 측정되지 않은 항목에 성공률이나 개선율을 부여하지 않는다.
- F15 originating item 식별과 F21 Range/whole-file 바이트 공유: 부분 해결. 전체 완료로 표시하지 않는다.

최우선 후속 작업은 iOS runtime 복구 → 원래 Native PCM fixture와 탭 없는 AVPlayer 대조 → 파일 준비/오디오 세션/tap 준비 경계 추적 → 원인 수정 후 iOS 전체 실행이다. 이어 동일한 조건에서 gapless/HTTP 시간 민감 테스트 반복 및 실기기 출력/전력 측정을 수행한다. 현재 상태는 출시 품질 승인 완료가 아니다.

## 증거 보관과 재현

`/tmp` 로그와 DerivedData는 시스템 정리로 사라질 수 있어 핵심 자료를 저장했다.

- [통과·실패 발췌 및 원본 로그 해시](verification-artifacts/test-results.txt)
- [TSan 원본 로그](verification-artifacts/core-tsan.log), [검증한 production 소스 해시](verification-artifacts/core-tsan-source-hashes.json)
- [독립 TSan harness](verification-artifacts/concurrency-sanitizer-harness.zip): 외부 의존성 없는 Package.swift, production 소스 복사본, 기존 테스트/fixture만 포함한다. 현재 앱 빌드에는 포함되지 않는다. 임시 디렉터리에 풀고 `swift test --package-path <디렉터리> --sanitize=thread -j 1`로 재현한다.
- [Time Profiler 목차](verification-artifacts/cassette-phase8-startup-toc.xml), [sample export](verification-artifacts/cassette-phase8-startup-samples.xml)
- [현재 구현 소스·테스트 72개 해시](implementation-manifest.json): 수정 53개, 추가 19개. 시작 스냅샷의 941개 파일이 모두 남아 있음을 확인했다. 최종 소스 patch는 `/tmp/cassette-hardening-baseline/final-source-changes.patch`.

실행 명령은 결과 보고서의 build/test 항목을 따른다. 최종 macOS 전체는 실제 소스에 연결한 `/tmp/cassette-validation/Cassette.xcodeproj`, `-jobs 2`, `-parallel-testing-enabled NO`, `CODE_SIGNING_ALLOWED=NO`, `COMPILER_INDEX_STORE_ENABLE=NO`로 실행했다. 마지막 native meter 비교용 shadow project는 진단 전용이며 최종 앱 소스 검증으로 계산하지 않는다.

