# RC 결함 수정 — 2026-10-12

읽기 전용 감사에서 실제 서비스 호출로 재현한 일반 결함 14개와 MP4 파서 충돌 1개를 수정했다. 기존 작업 트리의 변경을 유지하면서 해당 경로와 회귀 테스트를 보완했다.

| 감사 항목 | 수정 동작 |
| --- | --- |
| MP4 정수 오버플로 | box 크기를 남은 파일 길이와 비교한다. 손상된 MP4는 다운로드 검증에서 거부하고 리먹서에서도 안전하게 건너뛴다. |
| 늦은 세션 복원 | 재생 세대·명령·계정·현재 곡을 확인한다. 정지나 새 곡 선택 뒤 이전 소스와 45초 탐색 위치를 되살리지 않는다. 새 재생은 복원 잠금도 해제한다. |
| 다른 서버의 오프라인 재생목록 변경 | 요청 계정을 고정하고 `playlistId + serverId`로 조회·저장한다. 계정이 바뀐 응답은 반영하지 않는다. |
| 다운로드 취소 후 대기 곡 시작 | 앨범·재생목록 배치 자체를 소유하고 취소한다. 전체 취소 세대는 대기 곡, 추가·복구 배치와 후속 저장을 무효화한다. |
| 취소 후 새 다운로드 추적 소실 | 작업 UUID가 일치할 때만 정리한다. iOS의 지연된 취소도 해당 복구 UUID의 전송만 취소한다. |
| 해제한 즐겨찾기 재등장 | 동기화 시작 이후의 변경 세대와 진행 중인 변경을 확인한다. 같은 항목의 연속 star/unstar 요청은 순서를 보존한다. |
| 즐겨찾기 캐시의 옛 결과 | 변경 전후 캐시를 무효화하고 이전 조회가 새 캐시를 채우지 못하게 한다. |
| 셔플 해제 시 추가 곡 삭제 | 사용자 추가와 ‘다음에 재생’을 원래 순서 사본에도 반영한다. 중복 곡을 보존하고 자동 재생 부분을 별도로 셔플한다. |
| ‘다음에 재생’ 후 원래 곡 잘림 | 삽입 수만큼 자동 재생 경계를 이동한다. 반복 재생으로 전환해도 원래 곡이 남는다. |
| 중복 곡 삭제 시 전부 삭제 | 서버의 삭제 인덱스로 남은 순서를 계산한다. 오프라인 사본에서도 살아 있는 중복 항목을 유지한다. |
| 오프라인 재생목록 재정렬 누락 | 서버 변경이 성공하면 화면에서 사용하는 오프라인 기록의 순서와 곡 수를 갱신한다. |
| 다운로드 필터에 서버 곡 표시 | 최초 로딩·페이지 로딩·즐겨찾기 조회에 요청 세대, 필터와 계정 검사를 적용한다. |
| 옛 인덱싱 오류가 새 성공 상태 오염 | 현재 세대와 계정의 실제 오류만 표시한다. `URLError.cancelled`도 정상 취소로 취급한다. |
| 슬래시를 포함한 캐시 ID 실패 | 서버 ID와 원격 곡 ID를 SHA-256 저장 키로 바꾼다. 기존 캐시 레코드의 파일 경로는 계속 읽을 수 있다. |
| 용량 초과 파일이 자신을 삭제하고 URL 반환 | 복사·저장 전에 크기를 확인해 거부한다. 기존 재생 가능한 캐시를 보존한다. |

성능도 함께 보완했다. 캐시 조회는 서버 전체 레코드 대신 후보 ID에 한정한다. 즐겨찾기는 짧은 데이터베이스 작업과 조회 사전을 사용하여 모델을 `await` 너머로 보관하지 않는다. 인덱스 토큰 생성 작업에 취소를 전파하고 항목마다 취소를 확인한다. 다운로드 배치는 각 전송 완료 시 현재 전력 예산을 확인하여, 발열·저전력 제약이 생기면 진행 중인 작업을 마친 뒤 동시 작업 수를 3개에서 1개로 줄인다. 별도의 폴링 타이머를 추가하지 않았다.

회귀 검증은 `CassetteTests/RCAuditRegressionTests.swift`에서 실제 서비스와 메모리 SwiftData, 합성 SwiftSonic 응답, 제어 가능한 중단 지점을 사용한다. 실제 서버나 사용자 라이브러리는 변경하지 않는다. 용량 초과 검증은 큰 메모리 버퍼 대신 sparse 파일을 사용한다.

검증 결과:

- macOS 전체 테스트: **1,043개 / 183개 suite 통과**. 새 RC 감사 회귀 테스트 17개를 포함한다. [전체 로그](/tmp/cassette-rc-fix-verified-tests.log).
- iOS 앱·UI 테스트 대상: **arm64와 x86_64 빌드 성공**. [빌드 로그](/tmp/cassette-rc-fix-ios.log). UI 테스트 실행 결과는 아니다.
- 원래 감사 프로그램을 수정본의 실제 앱 서비스에 다시 연결하여 일반 재현 14개가 아래 상태로 바뀐 것을 확인했다. 용량 초과는 이제 오류로 거부하므로 해당 호출에만 정상적인 오류 처리를 추가했다. [재현 코드](/tmp/cassette-rc-fixed-verification/AuditProbe.swift), [실행 로그](/tmp/cassette-rc-fixed-verification/probe.log).
- 손상된 MP4의 검증→리먹스 경로는 **오류 거부 후 충돌 없이 반환**, 프로세스 종료 코드 0. [충돌 회귀 로그](/tmp/cassette-rc-fixed-verification/mp4.log).
- `git diff --check` 통과.

```text
CACHE_OPAQUE_ID accepted
FAVORITE_REAPPEARED 0
NEW_INDEX_SUCCEEDED true
STALE_INDEX_ERROR false USABLE_INDEX true
DOWNLOAD_FILTER_SHOWS_REMOTE true []
CACHE_RETURNED_MISSING_FILE false OVERSIZE_REJECTED 640
SHUFFLE_DROPPED_ADDED_TRACK ["a", "b", "c", "d"]
AUTOPLAY_TRUNCATED_ORIGINAL_TRACK ["a", "x", "b"]
RESTORE_REVIVED_SOURCE_AFTER_STOP false PENDING_SEEK -1 UI_IDLE true
DUPLICATE_OFFLINE_REMAINING ["track"]
OFFLINE_ORDER_UNCHANGED ["other", "track"]
FOREIGN_PLAYLIST_MUTATED ["foreign-track"]
UNSTAR_CACHED_RESULT 1 0 REMOTE_STARRED false
NEW_DOWNLOAD_UNTRACKED false NEW_TASK_STILL_WAITING true
BATCH_STARTED_AFTER_CANCEL 0
```

기존 로그의 라벨을 유지했다. `DOWNLOAD_FILTER_SHOWS_REMOTE true []`의 `true`는 Downloads 필터가 선택됐다는 뜻이고, 결과 배열은 이제 비어 있다. `PENDING_SEEK -1`은 재현 프로그램에서 탐색 정보가 없음을 표시하는 값이다.

실기기에서 iOS 프로세스 강제 종료·잠금 화면·오디오 인터럽트를 실행하거나 배터리 소모와 온도를 계측하지 않았다. 실제 절전 효과의 수치와 RC 배포 적합성을 이 결과만으로 보증하지 않는다.
