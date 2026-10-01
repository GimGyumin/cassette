import SwiftUI
import Testing
@testable import Cassette

@Suite("Setup appearance")
@MainActor
struct OnboardingAppearanceTests {
    @Test("Setup headings wrap within small phone widths and large text sizes")
    func headingLayout() throws {
        for width in [280.0, 380.0] {
            for size in [DynamicTypeSize.large, .accessibility3] {
                let renderer = ImageRenderer(content:
                    SetupHeader(icon: "globe", title: "Choose Your Language",
                                subtitle: "You can change this later in system Settings.")
                        .frame(width: width)
                        .environment(\.dynamicTypeSize, size)
                )
                renderer.scale = 1
                #if os(iOS)
                let image = try #require(renderer.uiImage)
                #elseif os(macOS)
                let image = try #require(renderer.nsImage)
                #endif
                #expect(abs(image.size.width - width) < 0.5)
                #expect(image.size.height > 150)
            }
        }
    }

    @Test("Continue maintains its touch target when disabled")
    func buttonLayout() throws {
        for enabled in [true, false] {
            let renderer = ImageRenderer(content:
                Button("Continue") {}
                    .buttonStyle(SetupPrimaryButtonStyle())
                    .disabled(!enabled)
                    .frame(width: 280)
            )
            renderer.scale = 1
            #if os(iOS)
            let image = try #require(renderer.uiImage)
            #elseif os(macOS)
            let image = try #require(renderer.nsImage)
            #endif
            #expect(image.size.height >= 52)
            #expect(abs(image.size.width - 280) < 0.5)
        }
    }
}
