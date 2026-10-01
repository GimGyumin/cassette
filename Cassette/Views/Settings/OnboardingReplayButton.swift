import SwiftUI

struct OnboardingReplayButton: View {
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            SettingsRowLabel(title: "Review Onboarding", systemImage: "arrow.counterclockwise", color: .blue)
        }
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                OnboardingView(isReplay: true, onReplayComplete: { isPresented = false })
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "Close", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) { isPresented = false }
                        }
                    }
            }
            #if os(iOS)
            .presentationDetents([.large])
            #elseif os(macOS)
            .frame(minWidth: 640, minHeight: 680)
            #endif
        }
    }
}
