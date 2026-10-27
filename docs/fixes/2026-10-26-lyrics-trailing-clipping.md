# 오른쪽 정렬 가사 잘림 수정

## 재현과 원인

사용자 스크린샷의 `There's a place in your heart, and I know that it is love`를
실제 `LyricWordKaraokeLine`으로 렌더링해 오른쪽 잘림을 재현했다.

`LyricGlyphRenderer.displayPadding`의 좌우 12pt가 텍스트의 측정 너비와
그릴 때 사용하는 문단 너비를 다르게 만들었다. 가운데/오른쪽 정렬에서는
텍스트 위치가 오른쪽으로 밀리고 일부 문장은 측정 때와 다른 위치에서 줄바꿈됐다.
텍스트를 추가로 잘라내는 방식 대신 수평 displayPadding을 0으로 변경했다.
상하 여유 공간과 기존 행의 좌우 여백, 글리프 애니메이션은 유지한다.

[Apple displayPadding 문서](https://developer.apple.com/documentation/swiftui/textrenderer/displaypadding)는
이 속성을 래스터화 레이어의 추가 여백으로 설명한다. 위 측정/그리기 차이는
이번 로컬 렌더링 실험에서 확인한 현상이다.

## 검증

- 기존 네이티브 문단 비교 테스트를 세 문장 × 세 정렬로 확장했다.
- 줄 개수·높이·너비뿐 아니라 실제 픽셀의 왼쪽/오른쪽 좌표도 비교한다.
- 수정 전 가운데/오른쪽 정렬 6개 조합 실패, 수정 후 전체 통과.
- 가사 표시·공백·AMLL 포트·플레이어 배치 회귀 테스트 44회 통과, 실패 0.
- iOS Simulator 범용 빌드 성공.
- 수정 후 오른쪽 정렬 출력 이미지와 기본 SwiftUI Text 이미지를 직접 확인했다.
- `git diff --check` 통과.

로그: `/tmp/cassette-clipping-before.log`, `/tmp/cassette-clipping-after.log`,
`/tmp/cassette-clipping-ios.log`.
실기기에 설치해서 확인하지는 않았다.
