# 재생 복원 및 잘못된 곡 종료 처리

## 확인된 경로와 수정

- AudioStreaming 종료/시작 콜백이 actor에 전달되는 사이 새로운 선택이 들어올 수 있었다. URL 비교만으로는 같은 곡을 다시 선택한 경우를 구분하지 못하므로 재생 command/epoch를 함께 검사한다. 진행률 기반 종료 감시도 MainActor 왕복 후 같은 컨텍스트인지 확인한다.
- 실제 오디오가 시작되기도 전에 EOF가 발생하면 다음 곡으로 넘어갈 수 있었다. 알려진 길이가 1초를 넘는 곡이 0.1초도 진행되지 않은 채 종료되면 현재 선택을 유지하고 재시도 가능한 오류로 처리한다. 기존 트랜스코딩 응답의 제한된 자동 복구 및 Gapless 경로는 보존한다. EOF 콜백이 제공하는 마지막 진행률도 판정에 사용한다.
- 세션 복원 시 소스 준비 실패는 미니/전체 플레이어의 재생 버튼을 비활성화했다. 곡이 선택되어 있으면 재생 버튼으로 다시 시도할 수 있도록 한다.
- 소스가 없는 복원 상태에서 resume은 일반 play를 호출해 저장 위치를 잃었다. 현재 곡의 소스를 다시 준비하고 저장 위치에서 시작한다. 늦게 끝난 resolve는 새 명령을 덮어쓰지 않는다.
- 열지 않은 복원 소스가 있고 빈 엔진이 paused 상태이면 resume만 호출해 오디오가 시작되지 않았다. 복원 체크포인트가 남아 있으면 소스를 새로 열고 pause-on-restore를 해제한다.
- 지연된 복원용 pause 작업도 재생 컨텍스트를 검사하고 상태를 게시한다.

## 주요 파일

- `PlayerService+Controls.swift`: 저장 위치를 유지하는 재시도와 복원 소스 열기.
- `AudioStreamingDelegate.swift`, `PlayerService+Gapless.swift`, `PlayerService+Progress.swift`: 종료 콜백/진행률 감시의 컨텍스트 검사와 빈 스트림 처리.
- `PlayerService+Callbacks.swift`: 지연 복원 pause 보호.
- `MiniPlayerAccessoryView.swift`, `PlayerTransportControls.swift`: 현재 곡의 재생 재시도 허용. 슬라이더 구현 변경 없음.
- `PlaybackRecoveryPositionTests.swift`, `PlaybackRequestCancellationTests.swift`: 늦은 EOF, 빈 스트림, 빈 paused 엔진, 저장 위치 복원 및 첫 실패 후 재시도 회귀 테스트.
- `PlaybackControlAppearanceTests.swift`: 기존 시작 상태 테스트에서 synthetic `/dev/null` 소스의 실제 디코더 콜백을 통제해 타이밍 의존성을 제거. 기존 assertion은 유지하며 실제 엔진 재생/실패 검증은 별도 회귀 테스트로 수행.

## 검증 범위

macOS 실제 오디오 엔진 및 관련 단위 테스트, iOS Generic Device 빌드. 시뮬레이터는 사용하지 않았다. 사용자 서버에서 발생한 원래 증상의 정확한 이벤트 순서는 로그 없이 확정할 수 없으며, iPhone에서 앱 재실행 후 재생, 빠른 연속 곡 선택, 네트워크 복귀 동작은 실기기 확인이 필요하다.

## 최종 자동 검증 결과

- macOS: 47개 테스트 정의, 매개변수 포함 60회 실행 모두 통과. `Test-CassetteTests-2026.10.14_00-18-25-+0900.xcresult`.
- 추가 TranscodeClockTests: 4개 테스트 정의, 매개변수 포함 5회 실행 모두 통과. 반복 재생의 EOF clock 초기화, 취소된 진행률 감시, 오프셋 탐색 검증. `Test-CassetteTests-2026.10.14_00-19-31-+0900.xcresult`.
- 합계 51개 테스트 정의, 65회 실행, 실패 0.
- iOS Generic Device, CODE_SIGNING_ALLOWED=NO: BUILD SUCCEEDED.
- 최종 빌드/테스트 로그에 컴파일 경고 또는 오류 없음. 수정 파일 `git diff --check` 통과.
- 로그: `/tmp/cassette-restore-eof-verified-tests.log`, `/tmp/cassette-restore-eof-repeat-tests.log`, `/tmp/cassette-restore-eof-verified-ios.log`.
