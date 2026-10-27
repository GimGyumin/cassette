# 비몰입형 플레이어 커버 사진 기준 보정

사용자가 제공한 588×1280 사진에서 참고 앱의 재생 중 커버는 약 `(35, 140, 518, 518)`, 정지 중 커버는 `(105, 210, 378, 378)`이다. Cassette의 BAD 커버는 폭이 같지만 중심이 약 74px 아래에 있어 재생 중 제목과 붙어 있었다.

## 변경

- 가사 패널 전체에 커버를 세로 중앙 정렬하던 배치를 전용 정사각형 슬롯으로 교체했다. 참고 화면 높이 비율로 상단을 배치하고, 작은 화면에서는 제목과 안전 영역을 침범하지 않도록 크기를 제한한다.
- 정지 크기를 재생 크기의 73%로 맞춘다. 커버 중심과 하단 컨트롤 위치는 유지한다.
- 세로·가로 공통 커버 modifier에 response 0.5, dampingFraction 0.86의 spring을 적용한다. 동작 줄이기를 켜면 즉시 전환한다.
- 회전 중 하위 뷰 전체의 애니메이션을 차단하던 transaction 대신 회전 상태에만 애니메이션 제한을 적용한다. 커버 슬롯 밖 그림자도 잘리지 않도록 클리핑 영역을 확장했다.

## 검증

- macOS Swift Testing: 관련 4개 suite, 18개 test 통과. 참고 사진의 재생·정지 커버 경계를 실제 SwiftUI 렌더링 결과에서 ±2px로 비교했다.
- 5가지 휴대폰 크기에서 커버와 제목·안전 영역의 간격을 검증했다.
- 실제 NSHostingView에서 재생→정지→재생 전환의 animation transaction과 동작 줄이기 설정을 검증했다.
- iOS Simulator 대상 `build-for-testing` 성공. 실기기에서의 프레임 속도나 동작 영상 검증은 포함하지 않는다.
- `git diff --check` 통과.

테스트: `CassetteTests/StandardPlayerArtworkReferenceTests.swift`, `PlayerExperienceRegressionTests.swift`, `ImmersivePlayerLayoutTests.swift`, `PhoneLandscapePlayerTests.swift`.
