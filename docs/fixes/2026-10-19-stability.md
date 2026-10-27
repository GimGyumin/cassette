# 2026-10-19 안정성 수정 — 1.0 (1002)

사용자가 제공한 1.0 (1001) 종합 진단을 현재 작업 트리와 대조했다. 이후 제공된
10월 14일 11:50 사건의 원본 보고서 본문도 확인했다. 나머지 사건의 원본 `.ips`와
Instruments 추적 파일은 직접 재분석하지 않았다. 기존 작업 트리의 변경 사항은
유지하고 아래 경로를 수정했다.

## AVPlayer 재진입

`AVPlayerPlaybackEngine`의 status, timeControlStatus, loadedTimeRanges KVO는
별도의 직렬 큐에 처리를 예약한다. AVFoundation 알림 스택에서 재생 명령을
동기적으로 다시 실행하지 않는다. 예약된 작업은 플레이어 세대와 플레이어/항목
객체를 확인하므로 교체되거나 중지된 항목에는 명령을 내리지 않는다.

`PromptPlaybackGate`는 `playImmediately(atRate:)` 호출 **전에** 시작 요청을
소비한다. 동일 위치에서 반복되는 playing/waiting 알림으로 요청이 다시 활성화되지
않는다. 이후 미디어 시간이 0.1초 넘게 전진하면 다음 버퍼 부족에 대한 복구 요청을
허용한다. 명시적인 seek와 항목 교체는 새 시작 구간을 만든다. 재생 의도, seek 완료,
버퍼 길이, 스트림 종류에 대한 기존 검사는 유지한다.

## 팔레트 저장과 화면 계산

`ColorCache`의 저장 구현을 `ArtworkPaletteCache`로 분리했다. 캐시 잠금 안에서는
메모리 조회·갱신과 저장 스냅샷 복사만 수행한다. UserDefaults 읽기/쓰기, JSON
인코딩/디코딩, SwiftUI Color 변환은 잠금 밖에서 실행한다.

저장 큐는 변경 revision의 스냅샷을 순서대로 기록한다. 저장 도중 새로운 변경이
들어오면 다음 저장에 남겨 두며, 변경 없는 flush는 쓰지 않는다. 같은 팔레트는
기존 JSON 키 순서가 달라도 다시 저장하지 않는다. cold hydration 중 clear가
발생하면 디스크에서 읽은 과거 값으로 복원하지 않는다. 기존 v8 키와 데이터 형식을
유지한다.

`FullPlayerView.content`는 준비된 뷰 모델 테마와 MainActor의 색상 캐시를 사용한다.
SwiftUI 화면 계산 중 ColorCache의 잠금이나 cold UserDefaults 조회를 기다리지 않는다.

## 저장량 및 종료 지연에 관한 범위

현재 `PlaybackCheckpointScheduler`는 30초 주기로 위치를 저장한다.
`PlaybackSessionService`에는 작은 위치 차이·같은 전체 상태의 저장 생략과,
큐가 바뀌지 않았을 때 queueData 재인코딩을 피하는 코드가 이미 있다. 따라서
보고서의 1.07GB를 위치 저장 탓으로 확정하거나 주기를 임의로 늘리지 않았다.
이번 캐시 수정은 불필요한 팔레트 쓰기를 줄이지만 SwiftData 쓰기량 해결을
입증하지는 않는다.

10월 14일 process-exit Watchdog의 원인은 이 변경만으로 확정할 수 없다.
Core Animation/glass 경고, 오디오 시작 지연도 별도 실기기 측정이 필요하다.

## 추가 원본 확인: 10월 14일 11:50 종료 지연

사건 ID `F102344B-14DF-4B80-B5D0-15BF5CF092D4`는 앞선 종합 진단의
10월 14일 사건과 일치한다. 추가 사고 건수로 세지 않는다. 버전은 1.0 (1001),
OS는 iOS 27.2 Beta (24B5110a)로, 1002 수정 후의 재발 증거가 아니다.

- 확정된 종료 원인은 `EXC_CRASH / SIGKILL`, `FRONTBOARD / 0x8BADF00D`,
  `WatchdogEvent: process-exit`, `Failed to terminate gracefully after 5.0s`이다.
  종료 요청 후 5초 제한을 넘겨 시스템이 프로세스를 종료했다.
- 실행 시각은 11:50:03.9831, 캡처 시각은 11:50:39.0240이다. 캡처 시점의
  프로세스 수명은 약 35초이며, 이 전체가 종료 제한 5초 구간인 것은 아니다.
  `uptime: 4800`도 앱 실행 시간으로 해석하지 않는다.
- 메인 스레드는 `ObservationRegistrar.Context.cancel → ObservationTracking.cancel
  → ObservationCenter.invalidate → DynamicBody.updateValue → SwiftUI layout`
  경로에서 관찰 등록을 정리하며 화면을 갱신하고 있었다. 최상단의 `Hasher`와
  `Set.remove`는 그 시점의 작업을 보여 주며, 해당 함수가 5초 내내 실행되었다는
  증거는 아니다. 주기적 샘플이 없어 단일 프레임으로 병목 지속 시간을 알 수 없다.
- 메인 스레드의 ColorCache/NSLock 대기, 팔레트 저장 큐의 UserDefaults 알림,
  AVPlayer 재귀 스택은 이 보고서에 나타나지 않는다. 오디오·애니메이션 보조
  스레드의 semaphore 대기만으로 교착의 순환 의존성을 확인할 수도 없다.
- 레지스터의 `far: 0`, Data Abort 설명이 있어도 보고된 종료 유형은 SIGKILL이다.
  이를 별도의 nil 접근 EXC_BAD_ACCESS 사고로 분류하지 않는다.
- 발열은 nominal이다. CPU 통계만으로 CPU 폭주를 확정할 수 없다. 가상 메모리
  TOTAL 388.8GB 중 Guard 385GB는 실제 RAM 사용량을 나타내는 값이 아니다.

바이너리 식별자는 executable UUID `2ca34524-350f-3419-af5d-3699cea481b5`,
`Cassette.debug.dylib` UUID `3e8d46bb-90af-3080-b72d-0e15423b1155`이다.
현재 작업 트리와 이 과거 바이너리의 소스 일치를 버전 표시만으로 가정하지 않는다.

이 원본으로도 어떤 앱 뷰/상태 변경이 종료 지연을 유발했는지는 특정할 수 없다.
다음 재현에서는 종료 직전의 SwiftUI 갱신·Observation 처리에 대한 시간별 스택과
scenePhase/사용자 동작 기록이 필요하다. 이 사건의 해결 여부는 P0 두 경로의
자동 테스트 통과와 별개로 검증한다.

## 검증

- `CrashPathRegressionTests`: 3,321회 반복 알림에서 중복 prompt 명령 차단,
  실제 시계 전진과 seek 후 재시작, 저장 observer의 다른 스레드 캐시 읽기·갱신,
  hydration 도중 clear, 변경 없는 저장 생략과 지연 쓰기 취소를 검증한다.
- `TranscodeHTTPSeekTests`: 실제 로컬 HTTP 스트림의 startup/seek/다음 곡 준비와,
  빠른 항목 교체 후 pause/resume 동작을 검증한다.
- 기존 buffering, session 저장·계정 식별, 준비된 플레이어 테마 회귀 테스트를 함께 실행한다.
- 최종 결과: 선택한 회귀 테스트 37건(매개변수별 실행 포함) 모두 통과,
  `TEST SUCCEEDED`. macOS 앱과 테스트 타깃 컴파일 경고·오류 없음.
- iOS Simulator arm64/x86_64 클린 빌드 통과. 마지막 소스 보완 후 증분 빌드도
  `BUILD SUCCEEDED`, 컴파일 경고·오류 없음. iOS 실기기 실행 검증은 포함하지 않는다.
- `git diff --check` 통과.

검증 환경은 Xcode 27.2 (27B5028f)이다. 명령 및 원본 결과:

```sh
xcodebuild test -project Cassette.xcodeproj -scheme CassetteTests \
  -destination 'platform=macOS' -derivedDataPath .derivedData-mac \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO \
  -only-testing:CassetteTests/CrashPathRegressionTests \
  -only-testing:CassetteTests/PlaybackBufferPolicyTests \
  -only-testing:CassetteTests/TranscodeHTTPSeekTests \
  -only-testing:CassetteTests/PlaybackSessionServiceTests \
  -only-testing:CassetteTests/PlaybackSessionIdentityTests \
  -only-testing:CassetteTests/LyricsPresentationRegressionTests

xcodebuild -project Cassette.xcodeproj -scheme Cassette \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .derivedData-ios \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO clean build
```

macOS 결과 번들:
`.derivedData-mac/Logs/Test/Test-CassetteTests-2026.10.19_15-24-43-+0900.xcresult`.
로컬 실행 로그는 `/tmp/cassette-stability-mac-tests.log`,
`/tmp/cassette-stability-ios-build.log`, `/tmp/cassette-stability-ios-final.log`에 있다.

## 실기기 확인 항목

1. 1002의 실행 바이너리 UUID와 OS 빌드를 함께 기록한다.
2. 빠른 곡 전환, seek, 일시정지, 잠금 화면·제어 센터·이어폰 제어를 반복한다.
3. 앨범아트 준비와 동시에 플레이어를 열고 닫으며 Hangs/Thread Performance
   Checker로 메인 스레드 정지를 관찰한다.
4. 재생 중 백그라운드 전환과 종료·재실행으로 위치 및 큐 복원을 확인한다.
5. 같은 라이브러리·네트워크 조건으로 94분 이상 재생하며 File Activity에서
   SQLite/WAL, 팔레트 설정, 다운로드·캐시 파일의 쓰기를 각각 집계한다.

자동 테스트 통과만으로 장시간 안정성이나 iOS 27.2 Beta Watchdog 재발 방지가
확정되는 것은 아니다. 새 빌드의 실기기 기록으로 추가 검증한다.

## iOS 설정의 분석 데이터 파일명

iOS 앱의 `EXECUTABLE_NAME`을 `$(PRODUCT_NAME)-$(CURRENT_PROJECT_VERSION)`으로
설정했다. 예를 들어 빌드 1002의 바이너리는 `Cassette-1002`이다. Apple 문서의
크래시 파일명 규칙이 `<AppBinaryName>_<DateTime>`이므로, 새 앱 크래시·Watchdog
보고서의 이름에도 이 빌드 번호가 포함될 것으로 예상한다. 실제 iOS 설정 목록에서의
표시는 새 빌드를 설치한 뒤 생성되는 보고서로 확인해야 한다. 기존 보고서는 바뀌지
않으며 `JetsamEvent`처럼 시스템 자체 이름을 쓰는 보고서까지 변경하는 설정은 아니다.

빌드 번호는 프로젝트의 Debug/Release 설정에서 앱·위젯·테스트가 공유한다. iOS
테스트의 `TEST_HOST`에도 같은 번호를 사용해 실행 파일명과 테스트 호스트 경로가
어긋나지 않게 했다. macOS 실행 파일명은 기존 설정을 따른다.

생성된 iOS Simulator 앱의 Info.plist에서 `CFBundleExecutable = Cassette-1002`,
`CFBundleVersion = 1002`와 해당 바이너리 파일의 존재를 확인했다. 추가 iOS
테스트 빌드는 Swift 컴파일러가 `No space left on device`를 보고하여 중단됐다.
따라서 위의 기존 회귀 테스트 결과를 실행 파일명 변경 이후의 iOS 테스트 통과로
해석하지 않는다. 이 설정으로 실제 iOS 분석 데이터가 생성되는 과정은 미검증이다.

근거: [Apple의 진단 로그 수집 안내](https://developer.apple.com/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs),
[EXECUTABLE_NAME 빌드 설정](https://developer.apple.com/documentation/xcode/build-settings-reference).
