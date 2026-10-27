# 1002 보고서 추가 확인 및 1003 진단 보강

2026-10-21, 사용자가 제공한 종합 분석문과 현재 코드를 대조했다. 이번에는 원본
로그 전체나 Instruments 추적 파일을 받지 않았으므로 경고 횟수와 연결별 원인은
독립적으로 재집계하지 않았다.

## 추가로 확인한 사용자 동작

사용자는 08:13:04 무렵 **앱을 다시 열거나 화면으로 복귀**했다고 확인했다.
같은 시각의 `PerformanceGovernor active=true`와 일치하는 정황이다. 코드상
scene 활성화 시 서버 도달 여부 확인, 설정 재로딩, 다운로드 복구 및 재생 상태
확인 등이 수행된다. 연결 재개·정리와 QUIC 메시지가 겹쳤을 가능성이 있으나,
어느 요청에서 나온 시스템 메시지인지는 기존 요약만으로 특정할 수 없다.

복귀 시 실제 재생 중단 여부는 확인되지 않았다. 이번 자료는 AVPlayer 재귀나
ColorCache 교착의 재발을 보여 주는 크래시 보고서도 아니다.

## 추가한 진단

- `[SCENE]`: 이전/현재 scenePhase, 변경 시점의 실제 UI 재생 상태·재생 의도·위치.
- `[PATH]`: NWPathMonitor의 online, Wi-Fi, cellular, expensive, constrained 값.
  서버의 HTTP 성공 여부와 별개인 경로 상태로 취급한다.
- `[HTTP]`: 요청마다 임의 ID, API 종류, 시작·HTTP 완료·취소·실패, 상태 코드,
  소요 시간, 응답 바이트 수. HTTP 200의 서버 API 오류까지 성공으로 해석하지 않는다.
- `[HTTP-METRICS]`: 표준 API 세션의 URLSession task 번호, 프로토콜, 연결 재사용,
  프록시 여부, 트랜잭션·리다이렉트 수, 총 소요 시간. SwiftSonic의 요청 및 redirect
  guard를 유지한다. 임의로 HTTP/3을 끄거나 요청을 다시 보내지 않는다.
- `[LIFECYCLE]`: appInit, rootAppeared, setupReady, libraryReady, playbackReady.
  시간은 App 초기화 진입을 기준으로 한 단조 시계의 밀리초 값이다. pre-main 시간은
  포함하지 않는다. rootAppeared는 SwiftUI onAppear이며 실제 첫 표시 프레임이나
  GPU 완료 시각을 보증하는 firstFrame 측정은 아니다.
  libraryReady는 저장된 인덱스를 복원하거나 새 인덱스를 설치한 시점이다.
  앨범아트 준비까지 포함하는 전체 준비 작업은 별도의 LIBRARY-PREP 소요 시간으로 구분한다.
- `[BOOT] setup() done`과 라이브러리 준비 완료에 각 작업의 소요 시간을 추가했다.
- `[PLAYBACK]`: 재생 확인, 재생 중 대기 전환, 최종 실패. 대기 시 AVPlayer의
  버퍼 길이도 기록하며 다른 엔진은 `-1`(미측정)로 표시한다.
- `[PLAYER-VIEW]`, `[PLAYER-SURFACE]`: 전체 플레이어 열기·닫기와 player/lyrics/queue
  전환 시 애니메이션 설정 및 성능 budget. 프레임마다 로그를 남기지 않는다.
- App Group suite를 실제로 열었을 때 container/suite 접근 성공을 기록한다.
- 내보낸 로그의 ISO 8601 시각에 밀리초를 포함한다. 앱 실행 식별자를 통해
  lifecycle/API/재생 기록을 같은 실행으로 묶을 수 있다.

API 이름은 알려진 이름만 허용하고 그 외 경로는 `other`로 기록한다. URL, 서버
주소, 쿼리, 인증 헤더, 응답 본문 및 오류 설명을 새 진단 필드에 기록하지 않는다.
최상위 CancellationError/NSURLErrorCancelled는 일반 실패와 구분한다.

## App Group 확인 범위

소스의 메인 앱 iOS/macOS entitlement와 위젯 entitlement는 모두
`group.com.kyumin.Cassette`를 사용한다. SharedStorage는
`UserDefaults(suiteName:)`으로 접근한다. 이번 변경에서 실제 설치 앱의 서명된
entitlement나 앱·위젯 간 영속 저장을 실기기로 검증하지는 않았다. suite 열기 성공
기록만으로 cross-process 영속 저장까지 검증되었다고 보지 않는다.

## 남은 확인

Core Animation 경고의 원인과 실제 화면 지연은 여전히 미확정이다. 새 계측은
동작 시점과 상태를 제공하며 경고를 해결했다는 의미가 아니다. 화면·효과별 실제
Animation Hitches 측정과 실기기 재현이 필요하다. 새 네트워크 진단은 기본
CustomHeadersTransport API 요청 범위이며 AVPlayer 내부 연결, 모든 외부 이미지
요청 및 모든 다운로드 세션까지 URLSessionTaskMetrics를 수집하는 것은 아니다.

빌드 번호는 앱·위젯·테스트 공통 **1003**으로 올렸다. iOS 실행 파일명과 앱에서
내보내는 로그 파일명도 기존 설정을 통해 새 빌드 번호를 반영한다.

## 검증

`NetworkDiagnosticsTests`는 endpoint/오류 필드의 비밀정보 제외와 취소·실패의
구분을 검증한다. `TranscodeHTTPSeekTests`에서 실제 로컬 HTTP 요청으로
SwiftSonic + URLSession delegate 메트릭 연동을 검증한다. 기존 헤더 전달,
재생 publication/failure, performance budget 및 로그
내보내기 테스트도 함께 실행한다.

최종 macOS 결과: 선택한 회귀 테스트 **34건 통과** (`TEST SUCCEEDED`),
컴파일 경고·오류 없음. 결과 로그는
`/tmp/cassette-1003-diagnostics-tests-final.log`이다. 실제 HTTP 스트림의
빠른 항목 교체·일시정지·재개·탐색 테스트도 포함한다.

최종 iOS Simulator 앱 빌드도 통과했으며 컴파일 경고·오류는 없었다.
`/tmp/cassette-1003-diagnostics-ios-final.log`. 생성된 앱의 빌드는 1003,
실행 파일명은 `Cassette-1003`임을 확인했다. 실기기 재현·성능 측정과 배포는
수행하지 않았다. `git diff --check`도 통과했다.
