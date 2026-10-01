// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

// MARK: - WARNING — do NOT read from ArtworkImageCache in CoverArtView.body
//
// ArtworkImageCache is @Observable. Any property access in a view's body creates
// an observation dependency on the WHOLE cache dictionary — not just the one key
// being read. When any cover arrives (i.e., cache[key] = image), every CoverArtView
// whose body observed the dictionary is invalidated and re-evaluated.
//
// With N history rows × M covers loading = N×M body re-evaluations. At 13 rows ×
// 13 covers = 169 redundant body calls on search open, cascading into parent list
// re-renders. Measured as ~20 consecutive SearchHistoryListView.body re-renders.
//
// The fix: never read artworkCache in CoverArtView.body. CoverArtViewContent owns
// @State private var cachedImage and a .task that loads exactly one id. Only THAT
// view's body re-renders when its own @State changes — cache mutations for other ids
// are invisible to it.

/// Async cover art loader. Resolves via ArtworkImageCache (RAM → disk → network).
/// Falls back to the URL/AsyncImage path only if ArtworkImageCache fails entirely.
/// Use `CoverArtCard` in views — it wraps this with clip, shadow, and border handling.
///
/// - Parameters:
///   - size: Requested pixel size, used for the AsyncImage fallback URL only.
///           Tier is auto-detected: `size >= 480` → `.hero` (1200 px decode);
///           `size < 480` → `.thumb` (240 px decode).
///   - tier: Optional explicit tier override. Pass `.hero` for detail-view hero images
///           whose pixel size is below 480 (e.g. macOS DetailHeroView at 280 px).
struct CoverArtView: View {
    let id: String
    let size: Int?
    var tier: ArtworkTier? = nil
    var cornerRadius: CGFloat = 0
    var placeholderSystemImage: String = "music.note"
    var initialImage: PlatformImage? = nil
    var contentMode: ContentMode = .fill
    /// When false, the artwork load is deferred (placeholder/initial image only) until it flips true —
    /// used to avoid firing artwork tasks for rows mounted but not yet visible (e.g. the inline queue at
    /// opacity 0). Defaults to true so every other call site is unchanged.
    var loadingEnabled: Bool = true

    var body: some View {
        // No artworkCache read here — see guard comment above.
        // CoverArtViewContent's .task handles the initial RAM check without creating
        // an @Observable observation dependency.
        CoverArtViewContent(
            id: id,
            size: size,
            tier: tier,
            cornerRadius: cornerRadius,
            placeholderSystemImage: placeholderSystemImage,
            initialImage: initialImage,
            contentMode: contentMode,
            loadingEnabled: loadingEnabled
        )
    }
}

// MARK: - Content

private struct CoverArtViewContent: View {
    let id: String
    let size: Int?
    let tier: ArtworkTier?
    let cornerRadius: CGFloat
    let placeholderSystemImage: String
    let contentMode: ContentMode
    let loadingEnabled: Bool

    @Environment(\.appContainer) private var container
    @Environment(ArtworkImageCache.self) private var artworkCache
    /// Global cover-refresh counter (UserDefaults-backed → reliably observed, no @Observable-in-body / optional-
    /// @Environment pitfalls). Bumped by PlaylistCoverManager on any cover change; folded into the load-task key
    /// so a cover change re-resolves the freshly-cached cover on EVERY surface (incl. Home Pinned).
    @AppStorage("coverArtUploadVersion") private var coverArtUploadVersion = 0
    @State private var cachedImage: PlatformImage?
    @State private var url: URL?
    @State private var originalRevision = 0
    /// The id whose image `cachedImage` currently represents. Lets a track change resolve the
    /// NEW id instead of short-circuiting on a stale image: we only keep the current image when
    /// `displayedId == id`. A failed hero load can therefore never leave the previous track's
    /// artwork on screen — the resolution below clears it and falls back against the current id.
    @State private var displayedId: String?

    init(id: String, size: Int?, tier: ArtworkTier?, cornerRadius: CGFloat, placeholderSystemImage: String, initialImage: PlatformImage?, contentMode: ContentMode = .fill, loadingEnabled: Bool = true) {
        self.id = id
        self.size = size
        self.tier = tier
        self.cornerRadius = cornerRadius
        self.placeholderSystemImage = placeholderSystemImage
        self.contentMode = contentMode
        self.loadingEnabled = loadingEnabled
        _cachedImage = State(initialValue: initialImage)
        // A caller-provided image is its best guess for THIS id, so mark it displayed for `id`:
        // it is upgraded by the load step online, but kept (not cleared) when offline.
        _displayedId = State(initialValue: initialImage == nil ? nil : id)
    }

    private var resolvedTier: ArtworkTier {
        tier ?? ((size ?? 0) >= 480 ? .hero : .thumb)
    }

    var body: some View {
        ZStack {
            if let cached = cachedImage {
                Image(platformImage: cached)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                // AsyncImage safety fallback — reached only when artworkCache.load() fails.
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: contentMode)
                    case .failure:
                        placeholder
                    case .empty:
                        GeometryReader { geo in
                            SkeletonBlock(
                                width: geo.size.width,
                                height: geo.size.height,
                                cornerRadius: cornerRadius
                            )
                        }
                    @unknown default:
                        EmptyView()
                    }
                }
            }
        }
        .clipped()
        .contentShape(Rectangle())
        // Keyed on (loadingEnabled, id) so deferring/undeferring re-runs the load: a deferred row shows its
        // placeholder/initial image and fires NO artwork task until it becomes visible (loadingEnabled flips).
        .onReceive(NotificationCenter.default.publisher(for: OriginalArtwork.didInstall)) { note in
            if note.object as? String == id { originalRevision &+= 1 }
        }
        .task(id: "\(loadingEnabled):\(id):\(coverArtUploadVersion):\(originalRevision)") {
            guard loadingEnabled else { return }
            url = nil
            let t = resolvedTier
            let online = container?.serverState.isOnline ?? true

            // Resolution runs against the CURRENT id only; each successful step sets both
            // `cachedImage` and `displayedId = id`, so an image whose id != current id is never
            // shown. The previous image stays visible while we resolve (no flash) — it is only
            // swapped atomically on success, or cleared at the end if nothing resolves.

            // 1. RAM hit for the requested tier. Sync read in .task (not body) — reads in task
            //    closures are not tracked by @Observable, so this creates no observation on the
            //    global cache dictionary.
            if let local = await artworkCache.loadPlainDiskCover(coverArtId: id, tier: t) {
                guard !Task.isCancelled else { return }
                apply(local, for: id)
                return
            }
            if let ram = artworkCache.cachedImage(for: id, tier: t) { apply(ram, for: id) }

            // 2. For hero artwork, paint any already-available thumbnail immediately, then keep
            //    resolving the requested tier. This makes the full player open with the same cover
            //    the mini player has already loaded instead of showing a skeleton while hero loads.
            if t != .thumb {
                if let ramThumb = artworkCache.cachedImage(for: id, tier: .thumb) {
                    apply(ramThumb, for: id)
                } else if let diskThumb = await artworkCache.load(coverArtId: id, tier: .thumb, allowNetwork: false) {
                    guard !Task.isCancelled else { return }
                    apply(diskThumb, for: id)
                }
            }

            // A local thumbnail is preferable to fetching another copy for the player.
            if let local = await artworkCache.load(coverArtId: id, tier: t, allowNetwork: false) {
                guard !Task.isCancelled else { return }
                apply(local, for: id)
                return
            }
            if displayedId == id, cachedImage != nil { return }

            // 3. Tiered load (RAM → disk `{id}@{tier}` → optional network). Always go through the
            //    cache so disk decode is gated — never ungated ImageIO from this view.
            if let image = await artworkCache.load(coverArtId: id, tier: t, allowNetwork: online) {
                guard !Task.isCancelled else { return }
                apply(image, for: id)
                return
            }

            // The image already on screen is correct for this id (a caller-provided initialImage,
            // an unchanged id, or the immediate thumb fallback) — keep it rather than clear it.
            if displayedId == id { return }

            // 4. Legacy plain-`id` offline download file — gated decode via the shared cache.
            if let image = await artworkCache.loadPlainDiskCover(coverArtId: id, tier: t) {
                guard !Task.isCancelled else { return }
                apply(image, for: id)
                return
            }
            guard !Task.isCancelled else { return }

            // 5. Nothing local resolved and the on-screen image belongs to a previous id — clear it
            //    so a mismatched cover is never left up, then try the online URL safety net
            //    (AsyncImage falls through to the placeholder when offline).
            cachedImage = nil
            displayedId = nil
            guard online else { url = nil; return }
            let fallbackURL = await container?.libraryService.coverArtURL(id: id, size: size)
            guard !Task.isCancelled else { return }
            url = fallbackURL
        }
    }

    /// Atomically swaps in a resolved image and records the id it belongs to.
    private func apply(_ image: PlatformImage, for resolvedId: String) {
        cachedImage = image
        displayedId = resolvedId
        url = nil
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [CassetteColors.accent.opacity(0.25), CassetteColors.accent.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: placeholderSystemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }
}
