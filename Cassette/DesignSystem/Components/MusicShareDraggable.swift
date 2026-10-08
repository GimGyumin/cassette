import SwiftUI

/// Generate the public link only when a receiving app requests the dragged URL.
/// No credentials, playback URLs, or title-only substitutes leave the app.
private struct MusicShareDragModifier: ViewModifier {
    let itemID: String
    let title: String
    @Environment(\.appContainer) private var container

    func body(content: Content) -> some View {
        if let container {
            content.onDrag {
                let server = container.serverService
                let options = ShareSettings.shared.makeOptions(trackTitle: title)
                return MusicShareDragProvider.make(title: title) {
                    let client = try await server.makeSwiftSonicClient()
                    return try await client.createShareURL(id: itemID, options: options)
                }
            }
        } else {
            content
        }
    }
}

extension View {
    func musicShareDraggable(itemID: String, title: String) -> some View {
        modifier(MusicShareDragModifier(itemID: itemID, title: title))
    }
}

/// Uses NSURL's system representations so receiving apps can request a URL directly.
enum MusicShareDragProvider {
    static func make(title: String, loadURL: @escaping @Sendable () async throws -> URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = title
        provider.registerObject(ofClass: NSURL.self, visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            let task = Task {
                do {
                    let url = try await loadURL()
                    try Task.checkCancellation()
                    completion(url as NSURL, nil)
                    progress.completedUnitCount = 1
                } catch {
                    completion(nil, error)
                }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        return provider
    }
}
