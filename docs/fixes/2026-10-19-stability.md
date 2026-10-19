# 2026-10-19 안정성 수정 — 1.0 (1002)

사용자가 제공한 1.0 (1001) 종합 진단을 현재 작업 트리와 대조했다. 원본
`.ips`와 Instruments 추적 파일을 직접 재분석한 결과는 아니다. 기존 작업 트리의
변경 사항은 유지하고 아래 경로를 수정했다.

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
