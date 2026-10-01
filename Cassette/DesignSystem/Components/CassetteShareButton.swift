// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
import OSLog
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import UIKit
#endif

private let logger = Logger(subsystem: "app.cassette", category: "ShareButton")

// MARK: - Platform share helper

private func shareURLToUser(_ url: URL) {
#if os(iOS)
    presentActivityViewController(with: url.absoluteString)
#elseif os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
#endif
}

/// A share button that creates a Navidrome share URL using saved `ShareSettings`,
/// then opens the system share sheet (iOS) or copies to clipboard (macOS).
struct CassetteShareButton: View {
    let itemID: String
    let itemDescription: String
    let fallbackText: String

    @Environment(\.appContainer) private var container
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var shareSettings = ShareSettings.shared

    var body: some View {
        Button {
            logger.debug("🔵 CassetteShareButton tapped — itemID=\(self.itemID, privacy: .public)")
            guard !isLoading else { return }
            isLoading = true
            Task {
                await performShare()
            }
        } label: {
            if isLoading {
                Label {
                    Text(String(localized: "Creating Link…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale, comment: "Share button: creating share link progress"))
                } icon: {
                    ProgressView()
                }
            } else {
                Label {
                    Text(String(localized: "Share", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale, comment: "Share button"))
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .disabled(isLoading)
        .alert(
            String(localized: "Share Error", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale, comment: "Alert title: share error"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(String(localized: "OK", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale, comment: "Dismiss button")) { errorMessage = nil }
        } message: {
            if let msg = errorMessage {
                Text(msg)
            }
        }
    }

    private func performShare() async {
        let itemID = self.itemID
        let itemDescription = self.itemDescription
        logger.debug("🟡 performShare() — id=\(itemID, privacy: .public)")
        do {
            let url = try await createShareURL(itemID: itemID, itemDescription: itemDescription)
            logger.debug("🟢 Share URL created: \(url.absoluteString, privacy: .public)")
            await MainActor.run {
                self.isLoading = false
                shareURLToUser(url)
            }
        } catch {
            logger.error("🔴 Share failed: \(error.localizedDescription, privacy: .public)")
            await MainActor.run {
                self.isLoading = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func createShareURL(itemID: String, itemDescription: String) async throws -> URL {
        guard let server = container?.serverState.activeServer else {
            logger.error("🔴 No active server")
            throw ShareError.invalidShareURL
        }
        guard let baseURL = URL(string: server.baseURL) else {
            logger.error("🔴 Invalid baseURL: \(server.baseURL, privacy: .public)")
            throw ShareError.invalidShareURL
        }
        logger.debug("🟡 Server: \(server.baseURL, privacy: .public) user=\(server.username, privacy: .private)")

        let creds = try await container?.serverService.activeCredentials()
        logger.debug("🟡 Credentials: password=\(creds?.password.isEmpty == false ? "SET" : "MISSING", privacy: .public)")
        guard let password = creds?.password, !password.isEmpty else {
            logger.error("🔴 No password in credentials")
            throw ShareError.invalidShareURL
        }

        let config = ServerConfiguration(
            serverURL: baseURL,
            username: server.username,
            password: password
        )
        let transport = CustomHeadersTransport(headers: creds?.customHeaders ?? [:])
        let client = SwiftSonicClient(configuration: config, transport: transport)

        let options = shareSettings.makeOptions(trackTitle: itemDescription)
        logger.debug("🟡 Options: allowDL=\(options.allowDownloads) original=\(options.shareOriginal) expires=\(String(describing: options.expires))")
        return try await client.createShareURL(
            id: itemID,
            options: options
        )
    }
}

/// Visual style for the share control.
enum CassetteShareButtonStyle {
    /// Standard menu item (icon + label).
    case menu
    /// Pill/capsule button (album action bar) with explicit tint + foreground.
    case pill(tint: Color?, foreground: Color)
    /// Icon-only circular hero button (toolbar, next to the ellipsis).
    case circle(foreground: Color)
}

/// A share button variant for album/playlist sharing that uses pre-built options.
struct CassetteShareButtonWithOptions: View {
    let itemID: String
    let shareOptions: ShareOptions
    let fallbackText: String
    var style: CassetteShareButtonStyle = .menu

    @Environment(\.appContainer) private var container
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Button {
            logger.debug("🔵 CassetteShareButtonWithOptions tapped — itemID=\(self.itemID, privacy: .public)")
            guard !isLoading else { return }
            isLoading = true
            Task {
                await performShare()
            }
        } label: {
            shareLabel
        }
        .disabled(isLoading)
        .alert(
            String(localized: "Share Error", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale, comment: "Alert title: share error"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(String(localized: "OK", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale, comment: "Dismiss button")) { errorMessage = nil }
        } message: {
            if let msg = errorMessage {
                Text(msg)
            }
        }
    }

    @ViewBuilder
    private var shareLabel: some View {
        switch style {
        case .menu:
            if isLoading {
                Label {
                    Text(String(localized: "Creating Link…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale, comment: "Share button: creating share link progress"))
                } icon: {
                    ProgressView()
                }
            } else {
                Label {
                    Text(String(localized: "Share", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale, comment: "Share button"))
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        case .pill(let tint, let foreground):
            HStack(spacing: CassetteSpacing.xs) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "square.and.arrow.up")
                }
                Text(String(localized: "Share", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale, comment: "Share button"))
            }
            .font(.cassetteCellTitle)
            .foregroundStyle(foreground)
            .padding(.horizontal, CassetteSpacing.l)
            .frame(height: 44)
            .cassetteGlassCapsule(tint: tint)
        case .circle(let foreground):
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(foreground)
            .cassetteHeroButton(size: 34)
        }
    }

    private func performShare() async {
        let itemID = self.itemID
        let shareOptions = self.shareOptions
        logger.debug("🟡 performShare(options) — id=\(itemID, privacy: .public)")
        do {
            let url = try await createShareURL(itemID: itemID, options: shareOptions)
            logger.debug("🟢 Share URL created (options): \(url.absoluteString, privacy: .public)")
            await MainActor.run {
                self.isLoading = false
                shareURLToUser(url)
            }
        } catch {
            logger.error("🔴 Share(options) failed: \(error.localizedDescription, privacy: .public)")
            await MainActor.run {
                self.isLoading = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func createShareURL(itemID: String, options: ShareOptions) async throws -> URL {
        guard let server = container?.serverState.activeServer else {
            logger.error("🔴 No active server")
            throw ShareError.invalidShareURL
        }
        guard let baseURL = URL(string: server.baseURL) else {
            logger.error("🔴 Invalid baseURL: \(server.baseURL, privacy: .public)")
            throw ShareError.invalidShareURL
        }
        logger.debug("🟡 Server: \(server.baseURL, privacy: .public)")

        let creds = try await container?.serverService.activeCredentials()
        guard let password = creds?.password, !password.isEmpty else {
            logger.error("🔴 No password in credentials")
            throw ShareError.invalidShareURL
        }

        let config = ServerConfiguration(
            serverURL: baseURL,
            username: server.username,
            password: password
        )
        let transport = CustomHeadersTransport(headers: creds?.customHeaders ?? [:])
        let client = SwiftSonicClient(configuration: config, transport: transport)
        logger.debug("🟡 Options: allowDL=\(options.allowDownloads) original=\(options.shareOriginal)")
        return try await client.createShareURL(
            id: itemID,
            options: options
        )
    }
}

// MARK: - UIKit share sheet helper (iOS only)

#if os(iOS)
/// Presents UIActivityViewController from the topmost view controller.
/// Passes the URL as a String to avoid LaunchServices sandbox extension
/// errors (Error -54) that occur when passing URL objects directly.
private func presentActivityViewController(with urlString: String) {
    guard let windowScene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive }),
          let root = windowScene.keyWindow?.rootViewController else {
        logger.error("🔴 Cannot find root view controller for share sheet")
        return
    }
    let top = root.topmostPresentedViewController
    let vc = UIActivityViewController(activityItems: [urlString], applicationActivities: nil)
    vc.popoverPresentationController?.sourceView = top.view
    top.present(vc, animated: true)
}

private extension UIViewController {
    var topmostPresentedViewController: UIViewController {
        presentedViewController?.topmostPresentedViewController ?? self
    }
}
#endif