// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import Combine

@Observable
@MainActor
final class LyricsViewModel {

    private let lyricsService: LyricsService
    private let playerService: any PlayerServiceProtocol
    private let playerState: PlayerState
    private let songId: String
    private let serverId: UUID

    var state: State = .loading
    var currentLineIndex: Int?
    var availableLanguages: [String] = []
    var selectedLanguage: String?
    var autoScrollEnabled = true
    var isUserScrolling = false

    // MARK: Translation

    var translatedLyrics: [TranslatedLyric] = []
    var isTranslating = false
    var translationErrorMessage: String?
    /// SwiftUI `.translationTask` 트리거용 — Apple 번역이 필요할 때 증가합니다.
    var appleTranslationRequestID = 0

    private var translationTask: Task<Void, Error>?

    private var lyricsList: LyricsList?
    private var trackingTimer: Timer?
    private var resumeTask: Task<Void, Never>?
    private var isShown = false


    nonisolated enum State: Equatable {
        case loading
        case loaded(StructuredLyrics)
        case empty
        case unsupported
        case error(String)
    }


    init(
        songId: String,
        serverId: UUID,
        lyricsService: LyricsService,
        playerService: any PlayerServiceProtocol,
        playerState: PlayerState
    ) {
        self.songId = songId
        self.serverId = serverId
        self.lyricsService = lyricsService
        self.playerService = playerService
        self.playerState = playerState
    }


    // MARK: Load

    func load() async {

        state = .loading

        do {

            let list = try await lyricsService.fetchLyrics(
                forSongId: songId,
                serverId: serverId
            )

            lyricsList = list
            applyCurrentLanguage()

        } catch LyricsError.notSupportedByServer {

            state = .unsupported

        } catch LyricsError.notFound {

            state = .empty

        } catch let error as LyricsError {

            state = .error(
                networkErrorMessage(from: error)
            )

        } catch {

            state = .error(
                error.localizedDescription
            )
        }
    }



    // MARK: Line Tracking

    func update(elapsedMs: Int) {

        guard case .loaded(let structured) = state else {

            currentLineIndex = nil
            return
        }


        let adjustedMs = elapsedMs - structured.offset

        var newIndex: Int?


        for index in 0..<structured.line.count {

            guard let start = structured.line[index].start
            else {
                continue
            }


            if start <= adjustedMs {

                newIndex = index

            } else {

                break
            }
        }


        if newIndex != currentLineIndex {

            withAnimation(.easeInOut(duration: 0.25)) {

                currentLineIndex = newIndex
            }
        }
    }



    // MARK: Seek

    func userTapped(lineIndex: Int) {

        guard case .loaded(let structured) = state,
              structured.synced,
              lineIndex < structured.line.count,
              let start = structured.line[lineIndex].start
        else {
            return
        }


        let seconds =
        TimeInterval(start + structured.offset) / 1000


        Task {

            await playerService.seek(
                to: seconds
            )
        }
    }



    // MARK: Scroll

    func userStartedScrolling() {

        isUserScrolling = true

        resumeTask?.cancel()


        resumeTask = Task {

            try? await Task.sleep(
                for: .seconds(1.5)
            )


            guard !Task.isCancelled else {
                return
            }


            self.isUserScrolling = false
        }
    }



    func userStoppedScrolling() {

        userStartedScrolling()
    }



    // MARK: Language

    func selectLanguage(_ lang: String) {

        guard selectedLanguage != lang else {
            return
        }


        selectedLanguage = lang
        currentLineIndex = nil

        applyCurrentLanguage()
    }



    // MARK: Timer

    var isPlaying: Bool {

        playerState.playbackState == .playing
    }


    private var hasSyncedLyrics: Bool {

        if case .loaded(let structured) = state {

            return structured.synced
        }

        return false
    }



    func setVisible(_ visible: Bool) {

        isShown = visible


        if !visible {

            resumeTask?.cancel()
            translationTask?.cancel()

            stopTimer()

        } else {

            reconcileTracking()
        }
    }



    func reconcileTracking() {

        if isShown && isPlaying && hasSyncedLyrics {

            startTimer()

        } else {

            stopTimer()
        }
    }



    private func startTimer() {

        guard trackingTimer == nil else {
            return
        }


        let timer = Timer(
            timeInterval: 0.1,
            repeats: true
        ) { [weak self] _ in


            guard let self else {
                return
            }


            Task { @MainActor in

                self.update(
                    elapsedMs:
                        Int(self.playerState.position * 1000)
                )
            }
        }


        RunLoop.main.add(
            timer,
            forMode: .common
        )


        trackingTimer = timer
    }



    private func stopTimer() {

        trackingTimer?.invalidate()
        trackingTimer = nil
    }



    // MARK: Translation Core (컴파일 타겟 에러 원천 해결 리팩토링)

    func translateCurrentLyrics() async {
        guard case .loaded(let structured) = state else { return }

        translationTask?.cancel()

        let settings = LyricsTranslationSettings.shared
        let targetLang = settings.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let finalTarget = targetLang.isEmpty ? "ko" : targetLang
        let provider = settings.provider
        let sourceLang = structured.lang ?? "auto"

        // 1. 캐시 확인 및 즉시 리턴
        if let cached = TranslationCache.shared.get(
            songID: songId,
            sourceLang: sourceLang,
            targetLang: finalTarget,
            provider: provider
        ) {
            let hasValidCache = cached.contains { lyric in
                !lyric.translatedText.isEmpty && lyric.translatedText != lyric.originalText
            }
            
            if hasValidCache {
                self.translatedLyrics = cached
                self.translationErrorMessage = nil
                return
            }
        }

        // 2. [컴파일 진단 실패 오류 해결] Task 구조의 복잡성을 낮추어 명시적으로 타입 추론 지원
        translationTask = Task { @MainActor in
            self.isTranslating = true
            self.translationErrorMessage = nil

            // 가사 원본 배열 생성
            let originalTexts: [String] = structured.line.map { $0.value }

            // OpenAI 번역기일 때만 뷰모델 내부에서 직접 네트워크 통신 처리
            // Apple 번역기는 SwiftUI 뷰의 .translationTask 환경 세션으로 위임되므로 여기서 걸러줍니다.
            if provider == .openAI {
                let translator = OpenAITranslator()
                
                do {
                    let translatedTexts = try await translator.translate(
                        lyrics: originalTexts,
                        sourceLanguage: sourceLang,
                        targetLanguage: finalTarget
                    )
                    
                    guard !Task.isCancelled else { return }
                    
                    var results: [TranslatedLyric] = []
                    let totalLines = structured.line.count
                    
                    for index in 0..<totalLines {
                        let line = structured.line[index]
                        let translated = index < translatedTexts.count ? translatedTexts[index] : ""
                        let isBlank = line.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        
                        let mappedLyric = TranslatedLyric(
                            time: TimeInterval(line.start ?? 0) / 1000,
                            originalText: line.value,
                            translatedText: translated,
                            isBlank: isBlank
                        )
                        results.append(mappedLyric)
                    }
                    
                    TranslationCache.shared.set(
                        results,
                        songID: self.songId,
                        sourceLang: sourceLang,
                        targetLang: finalTarget,
                        provider: provider
                    )
                    
                    self.translatedLyrics = results
                    
                } catch {
                    guard !Task.isCancelled else { return }
                    self.translationErrorMessage = "네트워크 상태가 불안정하여 번역을 불러오지 못했습니다."
                    self.createDefaultTranslatedLyrics(from: structured)
                }
            } else {
                // Apple 번역은 LyricsView의 .translationTask 세션으로 위임합니다.
                self.createDefaultTranslatedLyrics(from: structured)
                self.appleTranslationRequestID += 1
                return
            }

            self.isTranslating = false
        }

        do {
            _ = try await translationTask?.value
        } catch {
            // 에러 시 크래시 방지용 예외 처리
        }
    }



    func applyAppleTranslation(_ translatedTexts: [String]) {
        guard case .loaded(let structured) = state else {
            isTranslating = false
            return
        }

        let settings = LyricsTranslationSettings.shared
        let targetLang = settings.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let finalTarget = targetLang.isEmpty ? "ko" : targetLang
        let sourceLang = structured.lang ?? "auto"

        var results: [TranslatedLyric] = []
        let totalLines = structured.line.count

        for index in 0..<totalLines {
            let line = structured.line[index]
            let translated = index < translatedTexts.count ? translatedTexts[index] : ""
            let isBlank = line.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            results.append(
                TranslatedLyric(
                    time: TimeInterval(line.start ?? 0) / 1000,
                    originalText: line.value,
                    translatedText: translated,
                    isBlank: isBlank
                )
            )
        }

        TranslationCache.shared.set(
            results,
            songID: songId,
            sourceLang: sourceLang,
            targetLang: finalTarget,
            provider: .apple
        )

        translatedLyrics = results
        translationErrorMessage = nil
        isTranslating = false
    }

    func failAppleTranslation() {
        translationErrorMessage = "번역을 불러오지 못했습니다."

        if case .loaded(let structured) = state {
            createDefaultTranslatedLyrics(from: structured)
        }

        isTranslating = false
    }

    private func createDefaultTranslatedLyrics(
        from structured: StructuredLyrics
    ) {


        translatedLyrics =
        structured.line.map { line in


            TranslatedLyric(
                time:
                    TimeInterval(
                        line.start ?? 0
                    ) / 1000,

                originalText:
                    line.value,

                translatedText:
                    "",

                isBlank:
                    line.value
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                        .isEmpty
            )
        }
    }



    func clearCache() {

        TranslationCache.shared.clear()


        if case .loaded(let structured) = state {

            createDefaultTranslatedLyrics(
                from: structured
            )
        }
    }



    // MARK: Helpers

    private func applyCurrentLanguage() {

        guard let list = lyricsList
        else {
            return
        }


        var seen = Set<String>()


        availableLanguages =
        list.structuredLyrics
            .compactMap {
                $0.lang
            }
            .filter {
                seen.insert($0).inserted
            }



        let best =
        lyricsService.selectBestLanguage(
            from: list,
            preferred: selectedLanguage
        )


        currentLineIndex = nil


        state =
        best.map {
            .loaded($0)
        }
        ?? .empty



        if let structured = best {


            let settings =
            LyricsTranslationSettings.shared


            if settings.isTranslationEnabled
                &&
                settings.isAutoTranslateEnabled {


                Task {

                    await translateCurrentLyrics()
                }

            } else {


                createDefaultTranslatedLyrics(
                    from: structured
                )
            }
        }


        reconcileTracking()
    }



    private func networkErrorMessage(
        from error: LyricsError
    ) -> String {


        if case .networkError(let msg) = error {

            return msg
        }


        return error.localizedDescription
    }
}
