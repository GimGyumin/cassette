# 홈·발견하기 화면 및 커버 다운로드 변경

2026-10-13. 사용자가 제공한 8장의 화면을 기준으로 수정했다. 이번 요청 시작 시의 작업 트리를 `/tmp/cassette-home-discover-baseline/sources.zip`에 보관하고 비교했다. 기존 변경을 유지했으며, 시작 스냅샷의 파일이 모두 남아 있음을 확인했다.

## 화면과 이동 경로

- **홈:** 큰 정사각형 플레이리스트 카드, 좋아하는 곡 3개, 최근 재생, 자주 듣는 앨범, 다시 발견하기, 좋아하는 아티스트의 최근 추가 음악, 최근 추가, 장르별 앨범, 무드 순서다. 각 목록의 더 보기와 기존 곡 메뉴를 연결했다. 설정 버튼은 홈 상단의 기어로 표시한다.
- **발견하기:** 추천 아티스트 스테이션, 앨범 커버가 겹치는 Smart Shuffle 배너, 집중·Chill·Get Up 무드 카드 순서다. 기존 새 발매, 공간 음향, Replay, 인터넷 라디오 기능도 이어서 제공한다. 탭 아이콘은 사진처럼 네 개의 타일이다.
- **플레이리스트:** 서버 플레이리스트와 자동 믹스 모두 `PlaylistDetailView`의 같은 헤더·재생/셔플/다운로드 버튼·곡 목록을 사용한다. 무드·자동 믹스의 독립 상세 화면은 호출하지 않는다. 기존 `PersonalMixDetailView` 타입은 호환성을 위해 공통 플레이리스트 화면을 감싸는 코드만 남겼다.
- 상세 화면은 큰 제목, 중앙의 제목·사용자·갱신 정보, 아래 곡 목록을 사용한다. 상단의 추가/공유 기능은 더 보기 메뉴에 모았다. 사진의 미니 플레이어와 시스템 탭 바는 기존 기능을 사용한다.

자동 믹스에는 마지막 생성 시각을 기록한다. 기존 캐시 만료 시 이전 목록의 날짜만 갱신하던 경로를 수정해 실제로 다시 생성하도록 했다. 상세 화면의 당겨서 새로고침·앱 복귀, 홈의 새로고침에서도 갱신한다. 생성 가능한 음악이 부족한 경우 기존 최소 곡 수 정책에 따라 비어 있거나 갱신 실패 안내가 표시된다. 음악·아티스트·곡 수를 가짜로 채우지 않는다.

`GeneratedPlaylistSource`는 자동 믹스와 아티스트 스테이션의 로컬 식별자를 제공한다. 생성 목록의 다운로드는 원래 곡 메타데이터를 조회해 기존 다운로드 서비스에 로컬 스냅샷으로 저장한다. 생성 ID로 서버의 플레이리스트 조회·편집·삭제 API를 호출하지 않는다. 오프라인에서는 저장한 곡 순서를 사용하고, 계정 전환이나 더 늦게 끝난 이전 갱신은 현재 목록에 반영하지 않는다. 사용자 데이터 모델이나 영구 스키마는 바꾸지 않았다.

## 이미지 다운로드

같은 계정의 같은 **커버 ID**는 하나의 원본 다운로드를 공유한다. 앨범 대표 커버와 같은 ID를 가진 곡들은 다시 받지 않고, 다른 ID의 곡 커버는 별도로 보존한다. 전체 커버 준비와 앨범/곡 다운로드도 이 원본 경로를 공유한다. 저장된 원본이 있으면 다시 네트워크 요청하지 않는다. 준비 중인 원본에 화면 요청이 합류한 경우에도 해당 화면의 히어로 캐시를 준비한다.

판정은 서버가 제공한 커버 ID를 기준으로 한다. 서버가 서로 다른 ID에 같은 이미지 바이트를 제공하는 경우, 미리 같은 이미지라는 사실을 알 수 있다고 주장하지 않는다. 앨범 ID만 보고 곡별 별도 커버를 합치지 않았다.

셀룰러·비용이 있는 연결에서는 새 이미지 요청을 시작하지 않고 저장된 이미지를 계속 표시한다. 실제 이미지 `URLSession` 및 `URLRequest`에서도 셀룰러/expensive 접근을 차단해, 요청 직후 경로가 바뀌는 경우를 방어한다. 서버 커버, 외부 커버, 잠금 화면, 전체 플레이어와 이미지 전용 background session에 적용한다. 오디오의 셀룰러 재생/다운로드 정책에는 적용하지 않는다. Wi-Fi로 돌아오면 화면의 이미지 로드를 다시 시도한다.

한 소비자가 취소해도 공유 다운로드는 다른 소비자를 위해 유지한다. 마지막 소비자가 취소하면 실제 요청을 종료하고, 이후 재시도가 취소된 요청에 계속 합류하지 않게 한다. 커버를 교체할 때 진행 중인 원본 쓰기도 취소·종료한 뒤 파일을 갱신한다. 별도 `AsyncImage` fallback의 중복 요청은 제거했다.

공개 API 근거: [URLSessionConfiguration.allowsCellularAccess](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/allowscellularaccess), [URLRequest.allowsExpensiveNetworkAccess](https://developer.apple.com/documentation/foundation/urlrequest/allowsexpensivenetworkaccess).

## 검증

최종 소스 검증 결과:

| 항목 | 결과 | 원본 로그 |
|---|---|---|
| macOS 전체 | **1,136 tests / 197 suites 통과** | `/tmp/cassette-home-discover-verified-macos.log` |
| iOS 기기용 전체 빌드 | **BUILD SUCCEEDED** (서명 비활성화) | `/tmp/cassette-home-discover-verified-ios.log` |
| 관련 부분 회귀 | 74 tests / 9 suites 통과 (후속 추가 사례는 전체 실행에 포함) | `/tmp/cassette-home-discover-regressions-final.log` |
| 히어로 공유 요청 재현 | 수정 전 5개 중 1개 실패 → 최종 전체에서 동일 assertion 통과 | `/tmp/cassette-home-discover-hero-reproduction.log` |

최종 두 빌드의 compiler warning/error는 없으며 `git diff --check`도 통과했다. [검증 발췌와 원본 로그 해시](verification-results.txt)를 보관했다.

- 새 테스트 15개: 원본 공유/별도 커버 보존/한 소비자 및 마지막 소비자 취소/셀룰러 캐시와 Wi-Fi 복귀, 생성 플레이리스트의 공통 VM·다운로드·오프라인 순서·늦은 갱신 거부, 홈/발견하기 피드 공유·계정 분리·장르 중복 제거·다운로드 표시·믹스 만료 갱신, 컴포넌트 캡처.
- 수정 전 재현: 디스크 준비 요청에 합류한 히어로 요청의 RAM 캐시 누락 1개 expectation 실패를 확인했다. 동일 expectation을 유지하여 수정 후 통과했다.
- 기존 오프라인·다운로드·계정·커버 회귀 테스트도 함께 실행했다. 테스트 조건이나 시간 제한을 완화하지 않았다.
- 처음 추가한 테스트의 actor 기본 인자와 Testing 매크로 키 경로 컴파일 오류를 수정했다. iOS의 큰 SwiftUI 표현식 추론 오류는 표시/로딩 표현식을 나눠 해결했다.
- iOS 27.2 런타임이 unavailable 상태여서 iOS 앱 실행·제스처·실기기 셀룰러 전환은 확인하지 못했다. URLProtocol에서 실제 요청 횟수와 제한 속성을 검증했지만 실제 통신사 네트워크 측정과 동일하다고 주장하지 않는다.
- 컴포넌트 이미지는 실제 카드·배너 코드를 macOS에서 직접 렌더링한 미리보기다. macOS 네이티브 ScrollView는 ImageRenderer로 표시되지 않아 카드 자체를 직접 캡처했다. iPhone 화면 캡처나 실제 사용자 음악 데이터가 아니다.

명령은 기존 프로젝트 파일의 NSFileCoordinator 대기를 피하기 위해 원본 소스에 연결한 `/tmp/cassette-validation/Cassette.xcodeproj`에서 실행했다.

```sh
xcodebuild test -project /tmp/cassette-validation/Cassette.xcodeproj \
  -scheme CassetteTests -destination 'platform=macOS' \
  -derivedDataPath /Users/kyumin/Cassette/.derivedData-test \
  -disableAutomaticPackageResolution -parallel-testing-enabled NO -jobs 2 \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO

xcodebuild build -project /tmp/cassette-validation/Cassette.xcodeproj \
  -scheme Cassette -destination 'generic/platform=iOS' \
  -derivedDataPath /Users/kyumin/Cassette/.derivedData-audit-ios \
  -disableAutomaticPackageResolution -jobs 2 \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO
```

실기기에서는 저장된 커버로 셀룰러에서 홈·발견하기·상세 화면을 열기, 아직 없는 커버의 placeholder 확인, Wi-Fi 복귀, 앨범 대표/별도 곡 커버가 섞인 앨범 다운로드, 무드 다운로드 후 비행기 모드 복원, 빠른 계정 전환을 확인해야 한다. 사진의 네이티브 스크롤/축소 헤더/탭 바 배치는 iPhone에서 최종 확인해야 한다.

이번 요청의 변경은 소스·테스트 수정 31개, 추가 7개다. [해시 목록](implementation-manifest.json)은 이전 감사 수정과 분리한 이번 요청의 변경만 담는다. 성능 전후 측정이나 배터리 개선율은 산출하지 않았다.


[홈 카드 미리보기](home-components.png)와 [발견하기 컴포넌트 미리보기](discover-components.png)를 직접 확인했다. 미리보기의 아티스트·곡 수는 캡처 fixture이며, 앱 화면은 현재 계정의 실제 라이브러리 데이터를 사용한다. 사진과 동일한 음악·앨범 이미지를 코드에 하드코딩하지 않았다.
