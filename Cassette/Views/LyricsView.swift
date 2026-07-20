import SwiftUI
import Translation

struct LyricsView: View {
    @Bindable var viewModel: LyricsViewModel
    @ObservedObject private var settings = LyricsTranslationSettings.shared

    @State private var translationConfiguration: TranslationSession.Configuration?
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            
            Group {
                switch viewModel.state {
                    
                case .loading:
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    
                case .empty:
                    ContentUnavailableView(
                        "가사 없음",
                        systemImage: "music.note.list",
                        description: Text("가사가 존재하지 않습니다.")
                    )
                    
                case .unsupported:
                    ContentUnavailableView(
                        "지원되지 않는 서버",
                        systemImage: "exclamationmark.triangle",
                        description: Text("현재 서버 가사 조회를 지원하지 않습니다.")
                    )
                    
                case .error(let message):
                    ContentUnavailableView(
                        "가사를 불러올 수 없음",
                        systemImage: "wifi.exclamationmark",
                        description: Text(message)
                    )
                    
                case .loaded:
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            
                            VStack(alignment: .leading, spacing: 32) {
                                
                                ForEach(
                                    Array(viewModel.translatedLyrics.enumerated()),
                                    id: \.element.id
                                ) { index, line in
                                    
                                    if line.isBlank {
                                        Spacer()
                                            .frame(height: 20)
                                        
                                    } else {
                                        
                                        let isCurrent =
                                        viewModel.currentLineIndex == index
                                        
                                        VStack(
                                            alignment: .leading,
                                            spacing: 10
                                        ) {
                                            
                                            Text(line.originalText)
                                                .font(
                                                    .system(
                                                        size: 28,
                                                        weight: .bold,
                                                        design: .rounded
                                                    )
                                                )
                                                .foregroundColor(
                                                    isCurrent
                                                    ? .white
                                                    : .white.opacity(0.4)
                                                )
                                            
                                            
                                            if settings.isTranslationEnabled &&
                                                !line.translatedText.isEmpty &&
                                                line.translatedText != line.originalText {
                                                
                                                Text(line.translatedText)
                                                    .font(
                                                        .system(
                                                            size: 20,
                                                            weight: .medium,
                                                            design: .rounded
                                                        )
                                                    )
                                                    .foregroundColor(
                                                        isCurrent
                                                        ? .white.opacity(0.85)
                                                        : .white.opacity(0.28)
                                                    )
                                            }
                                            
                                        }
                                        .padding(.horizontal, 24)
                                        .contentShape(Rectangle())
                                        .id(index)
                                        .onTapGesture {
                                            viewModel.userTapped(
                                                lineIndex: index
                                            )
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 140)
                        }
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { _ in
                                    viewModel.userStartedScrolling()
                                }
                        )
                        .onChange(
                            of: viewModel.currentLineIndex
                        ) { _, newIndex in
                            
                            guard
                                let index = newIndex,
                                !viewModel.isUserScrolling,
                                viewModel.autoScrollEnabled
                            else {
                                return
                            }
                            
                            withAnimation(
                                .spring(
                                    response: 0.4,
                                    dampingFraction: 0.8
                                )
                            ) {
                                proxy.scrollTo(
                                    index,
                                    anchor: .center
                                )
                            }
                        }
                    }
                }
            }
            
            
            // 번역 버튼
            if settings.isTranslationEnabled {
                
                VStack {
                    HStack {
                        
                        if viewModel.isTranslating {
                            ProgressView()
                                .tint(.white)
                        }

                        Button {
                            Task {
                                await viewModel.translateCurrentLyrics()
                            }
                        } label: {
                            
                            Image(systemName: "translate")
                                .font(
                                    .system(
                                        size: 16,
                                        weight: .semibold
                                    )
                                )
                                .foregroundColor(.white)
                                .padding(10)
                                .background(
                                    Color.white.opacity(0.15)
                                )
                                .clipShape(Circle())
                        }
                    }
                }
                .padding(.top, 18)
                .padding(.trailing, 68)
            }
        }
        .onAppear {
            viewModel.setVisible(true)
            if settings.provider == .apple, viewModel.isTranslating {
                triggerAppleTranslation()
            }
        }
        .onDisappear {
            viewModel.setVisible(false)
        }
        .onChange(of: viewModel.appleTranslationRequestID) { _, _ in
            guard settings.provider == .apple else { return }
            triggerAppleTranslation()
        }
        .translationTask(translationConfiguration) { session in
            guard settings.provider == .apple,
                  case .loaded(let structured) = viewModel.state else {
                return
            }

            let originalTexts = structured.line.map(\.value)
            let translator = AppleTranslator()

            do {
                let translatedTexts = try await translator.translate(
                    lyrics: originalTexts,
                    using: session
                )
                await MainActor.run {
                    viewModel.applyAppleTranslation(translatedTexts)
                }
            } catch {
                await MainActor.run {
                    viewModel.failAppleTranslation()
                }
            }
        }
    }

    private func triggerAppleTranslation() {
        guard case .loaded(let structured) = viewModel.state else { return }

        let targetCode = settings.targetLanguage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let finalTarget = targetCode.isEmpty ? "ko" : targetCode

        let sourceLanguage = structured.lang.map { Locale.Language(identifier: $0) }
        let targetLanguage = Locale.Language(identifier: finalTarget)

        if translationConfiguration != nil {
            translationConfiguration?.invalidate()
        } else {
            translationConfiguration = TranslationSession.Configuration(
                source: sourceLanguage,
                target: targetLanguage
            )
        }
    }
}
