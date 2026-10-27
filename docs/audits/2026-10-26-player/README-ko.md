# 플레이어·가사·Atmos 다운로드 수정 및 성능 감사

2026-10-26 · Xcode 27.2 (27B5028f)

이번 작업은 요청한 플레이어 문제를 우선 수정하고, 검증 중 직접 확인한 메인 스레드 대기와 테스트 저장소 격리 문제를 함께 해결했다. 기존 작업 트리의 수정은 유지했다. Apple Music 수준의 배터리 효율이나 실기기 성능 달성을 주장하지 않는다.

## A. 실제 데이터 흐름

- 재생: `PlayerService` actor가 사용자 의도·명령 번호·재생 epoch를 소유한다. `MediaResolver`는 서버/계정에 맞는 다운로드 → 캐시 → 원격 소스를 고른다. 일반 오디오 엔진과 `AVPlayerPlaybackEngine`의 시스템 재생 경로가 공존한다. 큐, Gapless, Crossfade, 음량 처리는 기존 구조를 유지했다.
- 상태: 엔진 콜백은 서비스의 유효성 검사를 거쳐 `PlayerState`로 반영된다. `NowPlayingService`가 시스템 메타데이터와 원격 명령을 맡고, `FullPlayerView`가 화면 상태를 관찰한다.
- 가사: 파싱된 `LyricDocument` → 표시 행 → 재생 시계/AMLL 타임라인 → 활성 행과 단어별 렌더러로 이어진다. 단어 렌더링 시계와 전체 행 배치는 분리되어 있다. 숨김·백그라운드에서 추적을 중단하는 기존 정책을 유지했다.
- 저장: 다운로드 서비스가 전송 식별자, 재개 journal, SwiftData 레코드, 실제 오디오 파일을 관리한다. 원본 보존 요청도 같은 전송·검증·저장 경로를 사용하며 음질 정책만 명시한다.

## B–C. 확인한 문제와 변경

| 우선순위 | 파일/함수 | 원인 및 재현 조건 | 수정 |
| --- | --- | --- | --- |
| 높음 | `DownloadService._downloadSong`, `PlayerService.scheduleAutomaticDownload`, Atmos 버전 선택 화면 | 일반 음질이 AAC인 상태에서 Atmos 다운로드를 선택해도 일반 인코딩 설정을 따름. 자동 다운로드는 Atmos 다운로드 선호를 읽지 않았음 | `downloadOriginal` 경로 추가. 명시적 Atmos 선택과 자동 다운로드가 원본을 요청. 기존 손실 파일/진행 중 손실 전송도 원본 요청을 충족한 것으로 오인하지 않음 |
| 높음 | `PlayerService+Controls.pause`, `configureAudioSessionIfNeeded` | 세션 활성화 재시도가 메타데이터 await 동안 살아 있거나 이전 명령에 속할 수 있음 | pause 첫 단계에서 취소. 재시도에 epoch·명령·재생 의도·중단 상태 검증 추가. 현재 코드의 pause/stop/큐 종료에서 오디오 세션을 비활성화하지 않는 정책 유지 |
| 높음 | `CacheService.init` | 생성자에서 동기 `setResourceValues` → `CSBackupSetItemExcluded` → `getxattr` 대기. 앱 생성 메인 스레드가 정지 | 백업 제외 메타데이터 작업을 utility 직렬 큐로 이동. 동일 디렉터리의 동시 대기 요청 통합. 캐시 actor도 이 작업 완료를 기다리지 않음 |
| 보통 | `LyricsViewModel.amllActiveRows`, `LyricsPlaybackLineRow.lineAnimation` | AMLL의 스크롤용 lingering highlight를 실제 보컬 활성 상태로 사용. 끝난 겹침 행에 강조가 남고 퇴장에도 stagger가 적용됨 | 실제 보컬 `playing` 집합으로 활성 상태 결정. 다음 곡절로 미리 스크롤하지 않도록 스크롤 초점은 별도로 유지. 퇴장 dim은 지연 없이 0.18초 |
| 보통 | `FullPlayerView.portraitPanels`, `ImmersivePlayerControlsLayout` | 비몰입형 커버가 가사 패널의 scrubber 기준 공간을 공유하면서 별도의 여백을 다시 차감 | 커버 슬롯의 하단을 곡 정보 위로 제한하고 슬롯 안에서 한 번만 크기 계산. 재생/정지 시 레이아웃 슬롯은 고정 |
| 보통 | `PlayerRotationController`, `PlayerArtworkPlaybackModifier` | 회전 중 컨트롤러가 교체되면 weak completion이 호출되지 않아 애니메이션 비활성 상태가 남을 가능성. 세로/가로 커버 효과가 중복 구현됨 | 회전 완료 콜백을 보존. 세로/가로에 같은 spring·그림자·정지 배율 0.82 적용. Reduce Motion 유지 |
| 보통 | `phoneLandscapeSurface`, `LyricsView.scrollAnchor`, `LyricScrollGeometry` | 가로 레이아웃에 상단/하단 여백이 두 번 적용됨. spacious 가사가 행 높이와 하단 여유를 무시한 고정 비율 anchor 사용 | 여백을 외부 컬럼 한곳에서 적용. 가로 폰에만 실측 행 anchor 활성화, 내부 하단 8pt 확보. 데스크톱 spacious 배치 유지 |
| 보통 | `FullPlayerView.topBar/portraitPanels`, `PlayerDismissGesturePolicy` | 상단에만 닫기 드래그가 있어 커버에서 내리기 어려움 | 커버 영역에서도 아래로 드래그해 닫기. 가로 곡 넘김, 가사 스크롤, 컨트롤 조작과 구분. 짧은 탭/위로 드래그는 닫지 않음 |
| 보통 | `TrackInfoSection` | 다운로드 표시가 논리적 원곡 ID만 보고 계정 조건도 빠져 있었음 | 현재 계정과 실제 다운로드 대상 버전을 기준으로 표시/삭제. Atmos 요청은 원본 레코드만 완료로 표시 |
| 보통 | `AppContainer.init(inMemory:)` | 테스트 DB는 인메모리지만 다운로드·커버 파일은 실제 앱 폴더를 공유 | 테스트 컨테이너별 임시 오디오·커버·journal 경로 사용 |
| 낮음 | 설정 화면 | 다운로드 음질 진입점 중복, Atmos 다운로드 설정이 재생 설정 안에 흩어짐 | 다운로드 섹션으로 Atmos 다운로드 옵션 통합, 음질 화면의 중복 다운로드 행 제거, 적용 범위/원본 보존 설명 및 한국어 번역 추가 |

Atmos 선호 옵션의 적용 범위는 **지금 재생 중 다운로드와 자동 다운로드**다. 앨범/플레이리스트 일괄 다운로드를 다른 버전으로 대체하지 않는다. 버전 선택 화면의 개별 다운로드는 명시적 원본 요청이다. 설정 변경 자체가 기존 파일을 재다운로드하지는 않는다.

다른 앱이 재개되는 증상은 이 환경에서 직접 재현하지 못했다. 현재 소스에는 오디오 세션의 `setActive(false)` 실행 호출이 없고, 기존 세션 유지 정책을 보존했다. Apple은 `notifyOthersOnDeactivation`이 중단된 앱에 재개 가능성을 알리는 옵션이라고 설명한다. [Apple 공식 문서](https://developer.apple.com/documentation/avfaudio/avaudiosession/setactiveoptions/notifyothersondeactivation)

## D. 측정 및 한계

| 항목 | 변경 전 | 변경 후 | 해석 |
| --- | --- | --- | --- |
| 테스트 호스트 메인 스레드 1초 샘플 | 763개 샘플 모두 CacheService 생성자의 백업 메타데이터 호출에서 대기 | 동일 메타데이터 대기는 별도 utility 큐에 위치, 메인 스레드는 테스트/런루프 진행 | 동기 대기의 위치가 이동했음을 확인. CPU·배터리 절감률을 의미하지 않음 |
| 전체 단위 테스트 | 최초 실행은 위 메인 스레드 대기로 완료하지 못함 | 직렬 전체 실행 완료: 143.649초 | 실행 조건이 달라 성능 before/after 수치로 비교하지 않음 |
| 원본 다운로드 | 일반 인코딩 설정을 적용할 수 있었음 | AAC 128 설정·Lossless OFF에서도 raw 전송 재사용, 저장 바이트 동일성 회귀 테스트 통과 | 테스트 MP3 fixture로 원본 경로를 검증. Atmos 디코딩 검증은 아님 |
| 커버 정지 배율 | 세로/가로 별도 구현 | 200pt 슬롯에서 164pt 표시, 중심 및 외부 슬롯 크기 유지 | ImageRenderer의 정적 끝점 검사. 실제 애니메이션 FPS는 Not measured |
| 평균/피크 CPU, wakeups, 전력, 장시간 메모리, 디스크/네트워크 총량 | Not measured | Not measured | 실제 재생 계정·동일 콘텐츠·기기 조건의 Instruments 측정 필요 |
| startup/transition latency, stall, hitch, 60/120Hz 프레임 시간 | Not measured | Not measured | 시뮬레이터 런타임과 실기기 재생 환경 부재 |

## E–F. 기능 보존 및 테스트

- macOS 전체 단위 테스트: **총 1,335개 / 1,334 통과 / 0 실패 / 1 기존 skip**, 221개 suite. Xcode 결과 JSON은 `test-summary.json`에 보관했다.
- 기존 skip: `defaultInit_timesOutOnHungServer` — 저장소에서 수동 실행하도록 비활성화한 약 20초 timeout 테스트. 이번 작업에서 skip을 추가하지 않았다.
- 마지막 가로 폰 전용 앵커 범위 조정 후 UI 회귀 테스트 **22개 / 4개 suite / 실패 0개**를 추가 실행했다.
- iOS 앱 빌드 및 최종 **테스트 타깃 build-for-testing 통과**. 설치된 iOS 27.2 시뮬레이터 런타임이 unavailable이므로 iOS 테스트 실행 및 실기기 동작을 성공으로 표기하지 않는다.
- Lossless, Hi-Res 정책, Gapless, Crossfade, seek, 취소·중단, 다운로드/캐시 계정 격리, 가사 시계, 기존 artwork/layout 테스트를 전체 suite에서 유지했다. 시스템 출력 품질 및 실제 청취 결과는 미측정이다.
- 추가/확장 검증: 종료된 겹침 보컬 dim과 seek 복귀, 스크롤 여유, 커버 축소 중심, 닫기 방향 판정, Atmos 설정의 재생 설정 독립성과 계정 격리, 손실 다운로드를 원본으로 교체하면서 바이트 보존.
- 전체 병렬 실행에서는 파일 시스템 대기와 다수 실패가 발생했다. 직렬 집중 실행에서 남은 두 실패는 기존 fixture/기대값 문제였다. 캐시 동시성 테스트의 60번 입력이 `<`로 시작해 정상 HTML 차단 검사를 건드렸으므로 오디오 서명이 있는 가변 길이 입력으로 수정했다. 검색 테스트는 이미 구현된 ‘초기 페이지 선조회 없음’ 정책에 맞춰 명시적 다음 페이지 후 종료를 검증하도록 갱신했다. 테스트를 삭제하거나 실패를 skip 처리하지 않았다.
- `git diff --check`와 문자열 카탈로그 JSON 파싱 통과.

재현 명령:

```sh
xcodebuild test -project Cassette.xcodeproj -scheme CassetteTests \
  -destination 'platform=macOS' -derivedDataPath .derivedData-macos \
  -disableAutomaticPackageResolution -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO

xcodebuild build-for-testing -project Cassette.xcodeproj -scheme CassetteTests \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .derivedData-ios \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO
```

## G. 실기기 확인 절차

1. Apple Music 재생 → Cassette 재생 → 앱/잠금 화면/Bluetooth에서 일시 정지. 다른 앱이 재개되지 않는지 확인. 통화·Siri·출력 장치 변경도 별도 확인한다.
2. 비몰입형 보기에서 세로/양쪽 가로 회전, 빠른 연속 회전 뒤 재생·정지. 커버 확대·축소와 컨트롤 위치를 확인한다. Reduce Motion ON/OFF를 각각 확인한다.
3. 긴 번역·발음·백킹 보컬이 있는 TTML로 종료 시 dim, 이전/다음 행 겹침, 마지막 줄, 가로 하단 잘림을 확인한다. 화면보다 긴 행은 정상적으로 수동 스크롤할 수 있어야 한다.
4. 다운로드 음질 AAC 128, Lossless OFF, Atmos 다운로드 ON으로 알려진 Atmos 파일을 저장한다. 기내 모드에서 그 버전을 선택하여 출력 장치의 공간 음향 지원과 실제 재생을 확인한다. 매칭이 없는 곡은 일반 다운로드를 확인한다.
5. 같은 iPhone 16 Pro, 밝기·온도·출력·음량·네트워크·콘텐츠 조건을 고정한다. 일반/TTML 화면 각각 30분, 화면 OFF 60분을 Instruments로 측정한다. CPU/wakeups, 전력, 메모리, 디스크 쓰기, 요청 수·바이트, startup/stall/transition, UI hitch를 기록한다. 곡 넘김·앨범 진출입 100회, 반복 seek, 네트워크 단절·복구, Gapless/Crossfade를 별도로 수행한다. 여러 번 측정한 중앙값·변동폭을 비교하며 배터리 표시 1%만으로 절감률을 계산하지 않는다.
