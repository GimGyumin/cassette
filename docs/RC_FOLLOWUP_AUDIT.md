# Cassette RC 추가 결함·성능 감사 — 2026-10-12

앞선 수정본을 다시 검토했다. 이번 감사에서는 앱 소스, 테스트, 프로젝트 설정을 수정하지 않았다. 실제 앱의 `Cassette.debug.dylib`에 연결한 별도 프로그램으로 메모리 SwiftData와 합성 SwiftSonic 응답을 사용했다. 사용자 서버에 요청하거나 실제 다운로드를 삭제하지 않았다. 아래의 삭제 대상은 모두 감사용 임시 파일이다.

실행으로 확인한 기능 결함 17건과 성능 낭비 4건을 정리했다. 큐 관련 추가 후보 3건은 정적 근거와 별도로 표시했다. 실제 iOS 기기에서의 재현이나 배터리·온도 계측 결과는 아니다. 서비스 재현의 [기록된 출력 발췌](/Users/kyumin/Cassette/.derivedData-followup-audit/observed-results.txt)를 보존했다. 충돌과 비교 측정에는 별도의 재실행 가능한 코드와 원본 로그를 함께 남겼다.

앞선 계정·다운로드 수정이 적용된 경로 밖에도 같은 종류의 문제가 남아 있다. 특히 재생목록 **생성·삭제**, 즐겨찾기의 **실패 롤백**, 다른 서비스의 **조회 캐시**를 추가로 보호해야 한다.

## 우선 수정할 기능 결함

### 1. 높음 — 연속 삭제의 실패 롤백이 앱을 종료시킴

목록 `[a,b]`에서 b 삭제를 보류한 다음 a 삭제를 성공시킨다. 화면 목록이 비어 있는 상태에서 첫 요청을 실패시키면 `songs.insert(removed, at: 1)`이 범위를 벗어난다. 별도 프로세스는 종료 코드 **133, SIGTRAP**으로 종료됐다. 두 번째 삭제가 없는 대조군은 `[a,b]`로 정상 복구됐다.

근거: [PlaylistDetailViewModel.swift:197](/Users/kyumin/Cassette/Cassette/ViewModels/PlaylistDetailViewModel.swift:197), [실행 코드](/Users/kyumin/Cassette/.derivedData-followup-audit/QuickAudit.swift), [충돌 로그](/Users/kyumin/Cassette/.derivedData-followup-audit/rollback.log), [대조군](/Users/kyumin/Cassette/.derivedData-followup-audit/control.log).

변경 작업을 순서대로 처리하고, 실패 시 현재 목록을 서버의 최신 결과로 복원해야 한다. 오래된 배열 인덱스나 전체 스냅샷으로 되돌리는 방식은 다음 편집을 보호하지 못한다.

### 2. 높음 — 서버 A의 삭제가 서버 B의 오프라인 음원을 삭제함

A에서 `deletePlaylist(purgeDownloads: true)`를 시작하고 응답을 보류했다. B로 전환하고 서비스 캐시도 무효화한 뒤 응답을 반환했다. **B의 오프라인 목록과 실제 임시 음원 파일이 삭제됐고 A의 사본은 남았다.** 삭제 완료 후에 활성 서버 ID를 새로 읽는 것이 원인이다.

근거: [PlaylistService.swift:86](/Users/kyumin/Cassette/Cassette/Services/Implementations/PlaylistService.swift:86), [대상 계정 선택:109](/Users/kyumin/Cassette/Cassette/Services/Implementations/PlaylistService.swift:109).

삭제를 시작할 때의 서버·클라이언트를 고정하고, 로컬 삭제에도 같은 서버 ID를 사용해야 한다.

### 3. 높음 — 상세 화면의 다운로드 삭제가 공유 파일 보호를 우회함

음원 하나를 두 오프라인 재생목록과 다운로드 앨범이 공유하도록 구성했다. 첫 재생목록 상세 화면의 `deleteDownload()`를 실행하자 **공유 음원이 삭제되고, 다른 목록의 songIds가 비고, 앨범 기록도 삭제됐다.**

`DownloadService.remove(playlistId:)`에는 공유 파일 보호가 있지만, 화면 모델이 그 전에 곡마다 `remove(songId:)`를 실행한다.

근거: [PlaylistDetailViewModel.swift:186](/Users/kyumin/Cassette/Cassette/ViewModels/PlaylistDetailViewModel.swift:186), [보호된 삭제 구현](/Users/kyumin/Cassette/Cassette/Services/Implementations/DownloadService.swift:1135).

기존 재생목록 단위 삭제를 직접 호출하면 수정 범위가 작다. 공유 파일이 남은 곡의 배지는 실제 다운로드 상태로 다시 계산해야 한다.

### 4. 높음 — 재생목록 생성의 후속 요청이 다른 계정으로 넘어감

A에서 생성 요청을 보류하고 B로 전환했다. 생성 응답을 반환하자 후속 설명 저장은 **B의 클라이언트**로 실행됐다. 요청 순서는 `A/createPlaylist → B/updatePlaylist`였고 B에서 상세 정보를 조회하면 A의 생성 결과를 반환했다.

근거: [PlaylistService.swift:75](/Users/kyumin/Cassette/Cassette/Services/Implementations/PlaylistService.swift:75).

생성·설명 저장을 동일한 서버 컨텍스트로 처리하고, 캐시 저장 전에 계정과 변경 세대를 검사해야 한다.

### 5. 높음 — 스트림 URL과 사용자 헤더의 계정이 섞임

MediaResolver가 A의 클라이언트를 받은 뒤 자격 증명 조회를 보류했다. B로 전환한 다음 B의 합성 헤더를 반환하자, 반환된 소스는 **A의 URL + B의 헤더**였다. 실제 외부 전송까지 실행한 것은 아니다.

근거: [MediaResolver.swift:111](/Users/kyumin/Cassette/Cassette/Services/Implementations/MediaResolver.swift:111). 재생 서비스의 결과 검사도 재생 세대 중심이며 이 조합을 서버 ID로 검증하지 않는 경로가 있다.

서버 ID·클라이언트·헤더를 일관된 컨텍스트로 획득하고, 요청된 서버 ID와 현재 계정이 다르면 결과를 폐기해야 한다.

### 6. 높음 — 로그아웃 후 즐겨찾기 실패 롤백이 데이터를 되살림

즐겨찾기 해제의 서버 응답을 보류했다. 계정을 제거하고 `LocalAccountDataCleanup.clearRecords`를 실행한 뒤 요청을 실패시키자, 삭제된 즐겨찾기 기록 **1개가 다시 저장됐다.** 동기화의 세대 보호와 별도로 실패 롤백에는 계정 종료 검사가 없다.

근거: [FavoritesService.swift:126](/Users/kyumin/Cassette/Cassette/Services/Implementations/FavoritesService.swift:126).

계정 종료 세대를 변경 작업에도 적용하고, 계정이 종료된 작업은 이전 상태를 재삽입하지 않아야 한다.

## 나머지 실행 확인 결함

| 번호 | 우선순위 | 재현 결과와 원인 | 관련 코드 |
| --- | --- | --- | --- |
| 7 | 중간 | B의 개인 믹스를 요청해도 A의 5곡을 반환했다. 서버가 달라 캐시 적중을 피한 뒤에도 `var built = cached`로 이전 목록을 이어받고 B의 캐시로 저장한다. | [PersonalMixService:105](/Users/kyumin/Cassette/Cassette/Services/Recommendations/PersonalMixService.swift:105) |
| 8 | 중간 | B 앨범 조회가 성공한 뒤 취소된 A 응답을 반환하자 다음 조회는 A 앨범이었다. 캐시 게시와 작업 정리의 계정·세대 검사가 없다. | [LibraryService:155](/Users/kyumin/Cassette/Cassette/Services/Implementations/LibraryService.swift:155) |
| 9 | 중간 | B 라디오를 조회한 뒤 A의 지연 응답이 라디오 캐시를 다시 덮어썼다. 무효화는 진행 중인 응답을 차단하지 않는다. | [RadioService:35](/Users/kyumin/Cassette/Cassette/Services/Implementations/RadioService.swift:35) |
| 10 | 중간 | `[a,b,c]`에서 삭제 두 개의 응답을 교차시키면 서버는 `[b]`, 서비스 상세 캐시는 `[b,c]`가 됐다. 오래된 편집 기준과 완료 순서가 다음 결과를 덮어쓴다. | [PlaylistService:217](/Users/kyumin/Cassette/Cassette/Services/Implementations/PlaylistService.swift:217) |
| 11 | 중간 | 조회 응답을 보류한 상태에서 목록을 삭제하고 조회를 반환하자, 삭제된 목록이 상세 캐시에 재등장했다. 서버는 삭제 상태인데 두 번째 조회는 새 요청 없이 성공했다. | [PlaylistService:61](/Users/kyumin/Cassette/Cassette/Services/Implementations/PlaylistService.swift:61) |
| 12 | 중간 | 합성 서버가 페이지를 2개로 제한하면 실제 앨범 4개 중 2개만 수집했다. `page.count < 500`을 무조건 끝으로 처리한다. | [LibraryService:297](/Users/kyumin/Cassette/Cassette/Services/Implementations/LibraryService.swift:297) |
| 13 | 중간 | 실제 파일이 없는 기록은 `isDownloaded == false`인데 다운로드 ID 집합과 오프라인 앨범에는 포함됐다. 재다운로드를 실패시켜도 재생목록은 완료 수 `1/1`로 저장했다. 목록·완료 판단과 실제 파일 검사가 일치하지 않는다. | [DownloadService:158](/Users/kyumin/Cassette/Cassette/Services/Implementations/DownloadService.swift:158), [완료 집계:854](/Users/kyumin/Cassette/Cassette/Services/Implementations/DownloadService.swift:854) |
| 14 | 중간 | A의 `shared-art`를 저장한 뒤 B로 전환해도 같은 파일을 반환했다. 영구 커버와 메모리 커버의 키에 서버 ID가 없다. 캐시를 비워도 공용 디스크 파일은 재사용된다. | [DownloadService:180](/Users/kyumin/Cassette/Cassette/Services/Implementations/DownloadService.swift:180), [ArtworkImageCache:622](/Users/kyumin/Cassette/Cassette/Services/Implementations/ArtworkImageCache.swift:622) |
| 15 | 중간 | `folder/art` 커버 저장이 실패하고 조회는 nil이었다. 음원 캐시의 안전한 저장 키 수정은 커버 경로에는 적용되지 않았다. | [DownloadService:212](/Users/kyumin/Cassette/Cassette/Services/Implementations/DownloadService.swift:212) |
| 16 | 중간 | A의 `album:shared`를 고정한 뒤 B에서 같은 ID를 고정해도 B 기록은 생성되지 않았다. 고정 해제도 A 기록을 삭제한다. 키와 조회가 서버를 포함하지 않는다. | [PinService:63](/Users/kyumin/Cassette/Cassette/Services/Implementations/PinService.swift:63) |
| 17 | 중간 | ‘다운로드 전체 삭제’ 뒤 오프라인 재생목록 기록 1개가 남았다. 앨범과 곡은 지우지만 재생목록 기록을 정리하지 않는다. 진행 중인 다운로드 취소도 이 작업에 포함되지 않는다. 후자의 늦은 재생성은 정적 우려이며 별도 실행 재현하지 않았다. | [StorageManagementService:238](/Users/kyumin/Cassette/Cassette/Services/Implementations/StorageManagementService.swift:238) |

## 효과가 큰 최적화

### 18. 오프라인 재생목록 조회의 MainActor 반복 작업

`localPlaylistData`는 서버의 모든 다운로드 기록을 가져온 뒤, 재생목록 곡마다 `tracks.first`를 실행한다. 주석은 O(1) 조회라고 설명하지만 실제로는 다운로드 수 N과 목록 길이 P에 대해 **O(N × P)** 탐색이다. 반복 탐색 안에서 SwiftData 모델 속성을 매번 읽는 비용도 있다.

1초 프로세스 샘플에서 MainActor의 `localPlaylistData → compactMap → first → DownloadedTrack.songId.getter → SwiftData` 경로가 지배적이었다.

근거: [DownloadService:317](/Users/kyumin/Cassette/Cassette/Services/Implementations/DownloadService.swift:317).

초기 macOS Debug 측정:

| 곡 수 / 다운로드 수 | 현재 서비스 소요 시간 |
| --- | ---: |
| 250 / 250 | 약 216ms |
| 500 / 500 | 약 807ms |
| 1,000 / 1,000 | 약 7,014ms |

별도 실행 환경에서 1,000곡을 다시 측정한 결과는 **3,001ms / 2,974ms**였다. 동일한 메모리 데이터의 SQL 조회, DTO 변환, 현재·이전 ID 사전 생성과 목록 순서 재구성을 포함한 비교 구현은 **85ms**였다. 두 구현의 결과 순서가 같음을 검사했다.

비교 구현은 한 서버의 통제된 데이터이고 MediaIdentityService는 주입하지 않았다. 실기기·Release 빌드 수치나 완전한 제품 구현의 속도 향상 비율로 해석하면 안 된다. 실제 개선은 후보 곡만 조회하고 값을 한 번 추출하여 ID 사전을 만든 뒤, MainActor 밖에서 순서를 조합하는 것이 우선이다. 중복 곡·현재 ID·이전 ID와 파일 가용성도 보존해야 한다.

[비교 실행 코드](/Users/kyumin/Cassette/.derivedData-followup-audit/QuickAudit.swift), [보존된 측정 로그](/Users/kyumin/Cassette/.derivedData-followup-audit/benchmark.log).

### 19. 취소된 아티스트 화면이 남은 앨범 5개를 추가 요청함

앨범 10개 중 첫 5개 요청을 보류하고 부모 작업을 취소했다. 이를 반환하자 **나머지 5개도 요청했고 취소된 전체 조회가 성공으로 반환됐다.** 화면을 나가도 불필요한 통신·디코딩을 계속한다.

근거: [LibraryService:352](/Users/kyumin/Cassette/Cassette/Services/Implementations/LibraryService.swift:352).

부모 취소 이후 배치를 보충하지 않아야 한다. 이미 공유 중인 요청과 이 호출이 만든 요청의 소유권은 구분하여 취소한다.

### 20. 첫 전체 앨범 조회의 요청 병합이 깨짐

첫 전체 앨범 요청을 보류한 동안 같은 조회를 한 번 더 호출하자, 요청이 병합되지 않고 **같은 요청을 2회 실행했다.** `allAlbumsInFlight`를 등록한 후 `client()`가 처음 만들어지며 그 항목을 다시 nil로 초기화한다.

근거: [LibraryService:66](/Users/kyumin/Cassette/Cassette/Services/Implementations/LibraryService.swift:66), [초기화:80](/Users/kyumin/Cassette/Cassette/Services/Implementations/LibraryService.swift:80).

클라이언트 생성과 캐시 무효화를 분리해야 한다. 동일 계정의 초기 클라이언트 생성이 이미 등록된 조회 작업을 삭제하면 안 된다.

### 21. 반복되는 앨범 페이지에 같은 요청을 200회 실행함

offset을 무시하고 같은 500개를 반환하는 합성 서버에서는 중복 제거로 새 항목이 없어져도 루프가 계속됐다. **고유 앨범 500개를 얻는 데 200회 요청했다.** 안전 상한이 있지만 반복 데이터의 조기 종료가 없다.

근거: [LibraryService:292](/Users/kyumin/Cassette/Cassette/Services/Implementations/LibraryService.swift:292).

짧은 페이지를 곧바로 끝으로 처리하는 12번과 함께 수정한다. 실제 반환 개수로 offset을 전진시키고, 빈 페이지·새 항목 없음·반복 페이지에서 멈추는 방식이 필요하다. 사용자 취소와 계정 변경도 각 페이지에서 검사한다.

## 추가 정적 후보 — 실행 결과와 구분

- **큐에서 같은 곡이 두 번 있을 때 셔플 해제의 현재 위치가 앞의 항목으로 이동할 수 있다.** `restoreOriginalQueueOrder`는 현재 ID의 첫 인덱스를 사용한다. 현재 재생 중인 것은 두 번째 항목이어도 구분할 수 없다. [PlayerService+Queue:221](/Users/kyumin/Cassette/Cassette/Services/Implementations/PlayerService+Queue.swift:221).
- **자동 재생 꼬리가 비어진 뒤 추가한 사용자 곡이 이후 잘릴 수 있다.** 경계가 queue.count와 같은 상태에서 `addToQueue`는 append 경로를 사용하며 경계를 늘리지 않는다. 새 자동 재생 꼬리를 붙인 후 반복 모드를 켜면 추가 곡도 잘리는 코드 경로가 있다. [PlayerService+Queue:309](/Users/kyumin/Cassette/Cassette/Services/Implementations/PlayerService+Queue.swift:309).
- **자동 재생이 꺼져 있어도 목록 끝의 다음 곡 요청은 추천 조회를 실행한다.** `skipToNext`의 마지막 분기는 `isAutoExtendEnabled`를 검사하지 않고, 추천에 성공하면 해당 설정도 true로 저장한다. [PlayerService+Controls:495](/Users/kyumin/Cassette/Cassette/Services/Implementations/PlayerService+Controls.swift:495), [설정 변경:516](/Users/kyumin/Cassette/Cassette/Services/Implementations/PlayerService+Controls.swift:516).

## 효율적인 수정 순서

1. **충돌·실제 파일 삭제부터:** 1~3번. 기존 공유 파일 보호 경로를 재사용하고, 편집·실패 복원을 직렬화한다. 작은 수정으로 사용자 데이터 손실과 종료를 막을 수 있다.
2. **계정 컨텍스트와 작업 세대:** 4~11번, 14·16번. 서버 ID가 바뀐 응답·실패 롤백·캐시 게시를 공통 규칙으로 보호한다. 여러 서비스의 같은 문제를 한 번의 설계로 줄일 수 있다.
3. **MainActor 조회와 불필요한 요청:** 18~21번. 확인된 긴 실행 시간과 중복 통신을 먼저 줄인다. 전체 PlayerService를 분리하는 큰 리팩터링보다 직접적인 효과를 검증하기 쉽다.
4. **오프라인 데이터 일관성:** 12·13·15·17번. 파일 가용성, 저장 키, 페이지 종료와 삭제 후 기록 정리를 맞춘다.

수정 후에는 이번 재현을 실패→성공 회귀 테스트로 옮기고, 동일 데이터의 Release 빌드·실기기에서 MainActor 점유 시간, 요청 수, CPU 시간과 잠금 화면 재생 중 에너지를 비교한다. 이 감사의 시간 측정만으로 배터리 절감률을 제시하지 않는다.
