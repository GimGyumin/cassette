# Wi-Fi 커버 다운로드·홈 프로필·재생 커버 수정

2026-10-13 후속 수정. 이전 작업 트리는 유지했고 이미지 캐시나 다운로드 파일을 삭제하지 않았다.

- `isExpensive`는 셀룰러뿐 아니라 핫스팟 Wi-Fi에도 참일 수 있다. 기존 이미지 정책은 이를 셀룰러로 간주하고 URLSession에서도 비용이 높은 연결을 차단했다. `NetworkMonitor`가 실제 인터페이스의 셀룰러 여부를 별도로 전달하도록 바꾸고, 이미지 정책은 그 값으로 판단한다. 요청과 세션의 `allowsCellularAccess = false`는 유지한다. 비용이 높은 Wi-Fi는 허용한다. 오디오 품질·다운로드 동시성의 비용 정책은 바꾸지 않았다.
- Wi-Fi/온라인 복귀 시 이전 네트워크 차단 문구를 지우고 커버 작업을 다시 확인한다. 화면의 이미지 작업과 플레이어 테마 작업도 연결 상태 변경에 다시 실행된다. 오프라인이면 Wi-Fi 요구 문구 대신 연결 오류를 표시한다.
- 홈의 톱니바퀴를 프로필 아이콘으로 되돌리고 계정 화면을 연다. 큰 홈 제목은 유지한다.
- 앨범 응답에서 곡별 커버 ID가 빠졌으면 알려진 앨범 커버 ID를 트랙 표시 데이터에 보충한다. 곡별 별도 커버는 덮어쓰지 않는다. 플레이어도 현재 계정의 라이브러리 인덱스에서 해당 곡/앨범 커버를 조회해 저장된 이미지를 재사용할 수 있다. 알 수 없는 커버는 기존 곡 ID 대체 경로를 유지한다. 조회는 기존 사전 인덱스를 사용하며 화면에서 전체 라이브러리를 탐색하지 않는다.

새 회귀 테스트: 비용이 높은 Wi-Fi 허용 및 차단 문구 해제, 저장된 앨범 커버의 셀룰러 표시와 계정 분리, 앨범 대체 커버 적용 시 별도 트랙 커버와 메타데이터 보존. 기존 셀룰러 요청 차단 및 중복 다운로드 테스트도 유지한다. 최종 결과는 `verification-results.txt`, 변경 파일 해시는 `implementation-manifest.json`에 기록한다.

검증은 macOS 테스트 호스트 및 generic iOS 빌드다. 실제 iPhone의 Wi-Fi↔셀룰러 전환, 핫스팟/VPN 경로, 재생 화면의 시각 결과는 아직 실기기에서 검증하지 않았다. 기기에 앱을 설치하거나 데이터를 삭제하지 않았다.

근거: Apple은 [`NWPath.isExpensive`](https://developer.apple.com/documentation/network/nwpath/isexpensive)에 셀룰러와 Personal Hotspot이 포함된다고 설명하며, [`allowsCellularAccess`](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/allowscellularaccess)는 실제 셀룰러 연결 허용 여부를 제어한다. 이전 보고서의 “비용이 높은 연결도 이미지 차단” 설명은 이번 수정부터 적용하지 않는다.
