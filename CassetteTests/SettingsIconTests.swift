import SwiftUI
import Testing
@testable import Cassette

@Suite("Settings icons")
@MainActor
struct SettingsIconTests {
    @Test("Settings symbols exist on the current platform", arguments: [
        "photo.on.rectangle.angled", "externaldrive.connected.to.line.below",
        "person.fill", "arrow.down", "waveform", "character.bubble.fill",
        "cpu.fill", "text.badge.plus", "gearshape.fill", "trash.fill", "key.fill"
    ])
    func symbolExists(_ name: String) {
        #if os(iOS)
        #expect(UIImage(systemName: name) != nil)
        #elseif os(macOS)
        #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil)
        #endif
    }

    @Test("Settings tiles keep their size across appearance modes")
    func stableSize() throws {
        for scheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(content:
                SettingsIcon(systemImage: "gearshape.fill", color: .gray)
                    // The full-colour tile is the non-subdued variant; the default is
                    // covered by `defaultsToSubduedSize`.
                    .environment(\.settingsSubduedIcons, false)
                    .environment(\.colorScheme, scheme)
            )
            renderer.scale = 1
            #if os(iOS)
            let image = try #require(renderer.uiImage)
            #elseif os(macOS)
            let image = try #require(renderer.nsImage)
            #endif
            #expect(image.size == CGSize(width: 30, height: 30))
        }
    }

    @Test("Settings icons default to the subdued treatment")
    func defaultsToSubduedSize() throws {
        let renderer = ImageRenderer(content: SettingsIcon(systemImage: "gearshape.fill", color: .gray))
        renderer.scale = 1
        #if os(iOS)
        let image = try #require(renderer.uiImage)
        #elseif os(macOS)
        let image = try #require(renderer.nsImage)
        #endif
        #expect(image.size == CGSize(width: 28, height: 28))
    }

    @Test("Subpage symbols render at the quieter 28 point size")
    func subpageSize() throws {
        let renderer = ImageRenderer(content:
            SettingsIcon(systemImage: "gearshape.fill", color: .red)
                .environment(\.settingsSubduedIcons, true)
        )
        renderer.scale = 1
        #if os(iOS)
        let image = try #require(renderer.uiImage)
        #elseif os(macOS)
        let image = try #require(renderer.nsImage)
        #endif
        #expect(image.size == CGSize(width: 28, height: 28))
    }
}
