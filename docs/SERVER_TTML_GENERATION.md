# 서버 음악 폴더에 Apple Music TTML 일괄 생성

Cassette의 설정 → 계정 → 라이브러리 → **서버 TTML 파일 생성**을 누르면 모든 곡에 `getLyricsBySongId`를 `enhanced=true`로 순차 요청합니다. 앱에 이미 가사가 있어도 서버 요청을 생략하지 않으며, 외부 LRC 제공자는 사용하지 않습니다. 파일은 Navidrome의 nd-lyrics 플러그인이 저장합니다.

## 서버 설정

- nd-lyrics를 활성화합니다.
- Navidrome `LyricsPriority`에서 `nd-lyrics`를 첫 번째로 지정합니다. 기존 LRC나 embedded 가사가 먼저 반환되면 플러그인이 실행되지 않을 수 있습니다. 생성 후에는 `.ttml,.yaml,.yml,.elrc,.lrc,.srt,.txt,embedded,nd-lyrics` 순서를 사용할 수 있습니다.
- 플러그인의 Lyrics formats를 `ttml`로 설정합니다.
- 공급자는 Apple Music으로 설정하고, 활성 구독 계정의 media-user-token을 등록합니다. Cassette의 Apple Music developer token과는 다른 값입니다.
- `Write lyrics to sidecar files`와 음악 라이브러리의 `Allow write access`를 켭니다.
- `Write lyrics to a custom path`는 끕니다. 그러면 음악 파일 옆에 동일한 이름의 `.ttml`이 생성됩니다.
- 기존 TTML을 보존하려면 `Overwrite existing lyrics files`는 끕니다.
- 이전 LRC/텍스트 또는 실패 결과가 플러그인 캐시에 남아 있다면 최초 생성 전에 해당 캐시를 비우거나 캐시를 일시적으로 끄고 실행합니다. Cassette는 서버의 플러그인 캐시를 우회하거나 삭제하지 않습니다.

## 결과와 취소

앱의 진행 표시는 서버가 반환한 가사의 동기화 수준입니다. 단어 동기화 응답 자체는 TTML 파일 생성 성공의 증거가 아닙니다. 플러그인은 파일 쓰기 실패를 로그에 기록하고도 가사를 반환할 수 있으므로, 첫 실행 때 음악 폴더의 `.ttml` 및 Navidrome 로그를 확인합니다. Apple Music에 가사가 없는 곡은 생성되지 않습니다.

요청 실패와 가사 없음은 구분해 표시합니다. 취소, 계정 화면 닫기 또는 서버 변경 시 다음 요청을 중단합니다. 서버에서 이미 실행 중인 파일 저장은 취소되지 않을 수 있습니다. 재실행하면 전체 곡을 다시 요청하되, 플러그인의 기존 파일 보존 설정이 적용됩니다. 현재 작업은 앱 화면을 열어 둔 상태에서 실행하며 iOS 장기 백그라운드 완료를 보장하지 않습니다.

## 근거

- [공식 README](https://github.com/J0R6IT0/navidrome-lyrics-plugin): 요청 시 조회, Apple Music TTML, LyricsPriority 설정
- [engine.rs](https://github.com/J0R6IT0/navidrome-lyrics-plugin/blob/main/src/engine.rs): 캐시 조회 후 파일 저장 호출 및 쓰기 오류 로그
- [writing.rs](https://github.com/J0R6IT0/navidrome-lyrics-plugin/blob/main/src/writing.rs): 음악 파일 옆 저장 및 기존 파일 보존
