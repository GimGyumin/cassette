# AMLL 네이티브 Swift 포트

## 기준 소스

사용자가 제공한 `/Users/kyumin/Downloads/applemusic-like-lyrics`의 커밋
`5fee356362353dbb24ce9bea3a62536478040de7`을 기준으로 이식했다.
`@applemusic-like-lyrics/core`의 package 버전은 0.6.0, 라이선스는 AGPL-3.0-only다.

이번 변경은 아이디어 참고만 한 이전 수정과 달리 실제 AMLL 계산 로직을 Swift로 옮긴다.
웹 페이지를 감싸는 방식이 아니라 기존 iOS/macOS 화면과 오디오 시계에 연결한다.

## 이식 및 적용

| 원본 | Swift 구현 | 앱 연결 |
| --- | --- | --- |
| `base/timeline.ts` | `AMLLTimeline` | 단어 타이밍이 있는 가사의 활성/강조 집합과 간주 구간 |
| `base/seek-detector.ts` | `AMLLSeekDetector` | 미디어/단조 시계 차이로 탐색 감지, 화면 복귀 시 기준 재설정 |
| `base/spring.ts` | `AMLLSpringPolicy` | 줄 시작 간격에 따른 stiffness/damping, 탐색·간주 별도 정책 |
| `base/index.ts`의 stagger | `AMLLSpringPolicy.stagger` | 보이는 행 주변 강조·크기·흐림 전환의 순차 지연 |
| `utils/lyric-split-words.ts`, `dom/lyric-line.ts` | `AMLLTextPlan` | 공백을 유지한 음절 그룹, 긴 단어의 강조, 한글 등 CJK 분할 |
| `dom/animation/float`, `emphasize` | `AMLLGlyphStyle` | 보통 단어 상승, 긴 음절의 글리프별 지연·확대·이동·glow |
| `dom/animation/mask/animator-calc.ts` | `AMLLWordMask` | 각 음절 시각과 실제 조판 너비를 사용하는 부드러운 채우기 |
| `base/interlude-dots.ts` | `AMLLInterlude` | 3개 점의 진입·호흡·순차 점등·퇴장 |

이식 계산 코드는 `Cassette/Utilities/AMLL/`에 모았다.
`LyricsViewModel`은 값이 바뀔 때만 행 상태를 발행하고, 현재 가사 및 간주 표현만 프레임 시계를 읽는다.
기존 숨김·백그라운드·일시정지·저전력 정책을 사용한다. 별도의 상시 실행 타이머를 추가하지 않았다.

## 네이티브 환경에 맞춘 부분

- DOM/CSS/WAAPI 대신 SwiftUI `TextRenderer`, `ScrollView`, 시스템 스프링을 사용한다. 전체 문장의 시스템 조판과 공백 복원은 유지한다.
- 원본은 UTF-16 단위를 사용하지만 Swift에서는 결합 문자와 이모지가 깨지지 않도록 grapheme cluster를 사용한다.
- 원본의 Web Animations 마스크와 CSS 계산 마스크 중, 오디오 시각에서 직접 구하는 계산 마스크를 이식했다.
- 일반 단어의 최종 상승 상태는 원본의 `fill: both`를 따른다. 긴 음절의 추가 확대와 glow는 해당 강조 구간이 끝나면 해제된다. 비활성 행은 확장된 마지막 단어/글자 지연까지 종료된 시각으로 그려 잔광이 정지 상태로 남지 않게 한다.
- 직접 탐색과 비정상적인 시각 이동에는 행 stagger를 적용하지 않는다. 먼 탐색은 중간 가사를 쓸고 지나가지 않고 즉시 정렬한다.
- 웹의 행별 절대 위치/터치 관성 엔진을 그대로 대체하지는 않았다. 실제 행 높이를 측정하는 기존 네이티브 스크롤을 유지하며, 이식한 스프링 정책을 적용한다.
- LRC처럼 종료 시각이 불확실한 가사는 기존 보수적 타임라인을 유지한다. 단어 타이밍이 있는 문서는 AMLL의 겹침·강조 유지·7초 이상 간주 판정을 사용한다.
- 메인 보컬 뒤까지 이어지는 코러스의 종료 시각을 그룹 종료에 포함해 노래 중간에 간주 표시가 나오지 않게 한다.
- TTML 파서, 번역/발음 데이터, 배경의 Metal 렌더러는 기존 네이티브 구현을 재사용한다. React/Vue 래퍼, 웹 편집기, 모든 가사 포맷 변환기, WebGL 배경 전체를 Swift로 옮겼다는 의미는 아니다.

## 원본 대조 검증

`node scripts/amll/generate-reference.mjs /path/to/applemusic-like-lyrics`가 원본 TypeScript의 타입만 제거하고 실제 알고리즘을 실행한다. npm 설치나 네트워크 접근은 필요하지 않다.

- 타임라인 464개: 일반 진행, 보컬 겹침, 짧은 공백, 긴 간주, 곡 끝, 앞뒤 탐색
- 탐색 감지 180개: 시간 점프, 정지 상태, 단조 시계 진행
- 스프링 7개: 시간 간격 경계와 범위 밖 입력

위 651개 기준값은 `CassetteTests/Fixtures/amll-reference.json`에 저장했다. Swift 결과와 일치함을 확인했다. 추가로 단어 그룹·원문 공백·한글·결합 문자·이모지, 긴 음절 강조, 간주 퇴장, 앱에 연결된 타임라인과 번들 라이선스를 검증했다.

최종 검증:

- macOS 회귀 테스트 95개 정의, 매개변수 포함 **102회 통과**, 실패 0.
- 원본 기준값 **651개 일치** 검증 포함.
- iOS Simulator 범용 빌드 성공.
- 최종 테스트/빌드 로그에 컴파일 경고·오류 없음. `git diff --check` 통과.
- 로그: `/tmp/cassette-amll-verified-tests.log`, `/tmp/cassette-amll-verified-ios.log`.
- 원본 라이선스 파일과 앱에 포함한 전문이 동일함을 확인했다.

실기기에서 수정 버전을 재녹화하거나 Instruments로 전력 사용량을 측정하지는 않았다.

## 출처와 라이선스

이식 파일은 AGPL-3.0-only이며 파일마다 원본 경로·커밋·저작권 안내를 남겼다. 원본 라이선스 전문을 `Cassette/Resources/Licenses/AMLL-AGPL-3.0.txt`에 포함하고 설정 → 정보 → Open Source에서 열 수 있게 했다.

기존 Cassette 파일의 MPL-2.0 고지는 보존했다. AGPL 구성요소의 출처 안내가 라이선스 예외를 부여하는 것은 아니다. 결합한 앱의 배포 조건은 포함된 AGPL 전문을 따른다. 이번 작업은 로컬 코드 통합과 검증이며 외부 배포는 수행하지 않았다.
