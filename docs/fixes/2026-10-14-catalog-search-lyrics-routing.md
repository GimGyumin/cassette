# 자동 재생 경로, 검색, 가사 및 SQLite 카탈로그

## 구현

- 자동 재생: 알려진 무손실 원본은 Direct Play에 해당하는 원본 스트림을 우선한다. 셀룰러의 나머지 곡은 Jellyfin PlaybackInfo가 HLS 변환을 제공하면 HLS를 선택한다. 캐시/다운로드와 공간 음향 원본 보존, 수동 재생 방식은 우선순위를 유지한다. HLS를 제공하지 않는 서버에서는 지원되는 변환 경로로 폴백한다.
- 검색: 로컬 페이지는 표시 한도보다 한 개 더 읽어 다음 결과를 판정한다. 서버 페이지는 다음 페이지를 선조회해 마지막/반복 페이지를 확인한다. 독립적인 아티스트·앨범·곡 offset과 재시도를 유지한다. 카테고리는 가로로 배치한 개별 시스템 Button으로 표시한다.
- 가사: 고빈도 시계 구독을 단어 표시 하위 View로 이동했다. 진행률 갱신마다 번역·접근성·행 배치가 재평가되는 범위를 줄이고, 변하지 않은 단어 View는 Equatable로 재사용한다. 기존 동기화, 번역, 발음, 코러스 및 Reduce Motion 동작을 보존한다.
- 저장: 계정별 SQLite에 엔터티별 payload, 검색 토큰, 표시 순서 및 스냅샷 메타데이터를 저장한다. 기존 JSON은 오프라인에서 이전하며 원본은 백업으로 남긴다. 새 DB를 같은 디렉터리에 준비한 뒤 account/generation을 검사하고 원자적으로 교체한다.
- 검색 인덱스: SQLite FTS5 trigram으로 부분 일치를 처리한다. 한글 및 로마자 토큰을 유지하며, 1~2글자는 SQLite substring 비교로 처리한다. 짧은 검색어는 전문 검색 인덱스를 활용하지 못한다. 검색 작업은 백그라운드에서 실행한다.
- 변경 감지: 곡 수 변화 외에도 마지막 서버 스캔 시각과 24시간 재검증 기한을 확인한다. 재검증은 앱의 라이브러리 확인 경로가 실행될 때 수행하며 상시 타이머가 아니다. 스캔 중인 서버의 중간 목록은 반영하지 않는다. 초기 인덱싱과 중복 실행하지 않고 앨범의 짧은 메모리 캐시를 우회한다.
- DB 갱신: 서버 목록 전체를 읽은 뒤 ID별 추가/수정/삭제를 트랜잭션으로 반영한다. 동일 payload의 토큰은 재사용하고 변경되지 않은 검색 문서는 다시 쓰지 않는다. 서버 변경 목록 API가 없는 환경에서 네트워크 수집까지 증분으로 바뀐 것은 아니다.

## 호환성과 범위

기존 앨범 버전 선택·아트워크 매핑·Siri 등의 공개 인터페이스를 유지하기 위해 메모리 카탈로그 배열은 남아 있다. 재실행 시 이 배열을 복원하지만 저장된 검색 토큰을 재사용하며 검색 결과는 SQLite에서 제한된 수만 조회한다. SQLite 사용이 불가능하면 기존 메모리 검색으로 폴백한다. 완전한 DB 페이지 기반 라이브러리 UI 전환은 이번 변경 범위에 포함하지 않았다.

`LibraryCatalogStore.swift`, `LibraryIndexService.swift`, `LibraryPreparationService.swift`, `LibraryChangeDetector.swift`, `LibraryService.swift`, `LibraryServiceProtocol.swift`, `MediaResolver.swift`, `PlaybackDecisionPolicy.swift`, `SearchViewModel.swift`, `SearchTabContent.swift`, `LyricsPlaybackLineRow.swift`, `LyricWordKaraokeLine.swift`가 주요 수정 파일이다.

## 검증

- macOS: 저장소의 생성/재개방, JSON 오프라인 이전, 1만 곡 부분 검색, 같은 곡 수에서 제목 변경·삭제, 한글 짧은 검색어, 검색 구문 문자, 정확히 80/160개인 마지막 페이지 및 서버 마지막 페이지 검증.
- 기존 검색 취소·페이지 재시도, 수동 재생 경로, 무손실·캐시 우선순위, 가사 타이밍·탐색·스크롤·코러스 회귀 테스트 유지.
- 자동 재생의 새로운 무손실 우선 정책을 테스트에 추가했으며, AAC 변환은 명시적 OpenSubsonic 선택에서 기존 URL/코덱 assertion을 그대로 검증한다.
- iOS Generic Device 빌드. 시뮬레이터는 사용하지 않음.
- 실제 iPhone의 가사 프레임 시간, 셀룰러 네트워크에서 서버별 HLS 협상·재생 및 필터 배치는 실기기 검증이 필요하다. 컴파일/단위 테스트를 체감 끊김 해결의 실측으로 간주하지 않는다.

최종 결과: macOS 115개 테스트 정의, 매개변수 포함 119회 실행, 실패/건너뜀 0. 결과 번들: `.derivedData-test/Logs/Test/Test-CassetteTests-2026.10.14_10-54-44-+0900.xcresult`. iOS Generic Device `BUILD SUCCEEDED`. 최종 로그에서 컴파일 경고/오류 없음, 수정 파일 `git diff --check` 통과. 로그: `/tmp/cassette-catalog-verified-tests.log`, `/tmp/cassette-catalog-verified-ios.log`.

## 후속 수정: 셀룰러의 명시적 손실 음질 우선

원본이 무손실이라는 이유만으로 `streamFormat`을 원본으로 바꾸던 규칙을 수정했다. 해당 네트워크의 설정이 Automatic/Lossless일 때만 무손실 원본 우선 규칙을 적용한다. AAC 256/128 및 Opus 128을 선택하면 FLAC 원본도 선택한 스트리밍 코덱/비트레이트를 사용한다. 네트워크 비용 플래그와 별도로 실제 셀룰러 연결도 셀룰러 음질 선택에 반영한다.

Wi-Fi=무손실, 셀룰러=AAC/Opus, 원본=FLAC 조합을 두 음악 클라이언트 어댑터 및 Automatic/OpenSubsonic 경로에서 검사했다. 원본·캐시·수동 경로·적응형 음질 회귀 테스트 총 63개 모두 통과. 결과: `.derivedData-test/Logs/Test/Test-CassetteTests-2026.10.14_12-00-45-+0900.xcresult`. iOS Generic Device 빌드 성공, 시뮬레이터 사용 없음. 실제 서버의 변환 결과와 셀룰러 재생은 실기기 확인이 필요하다.
