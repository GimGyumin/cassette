// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
import SwiftSonic
#if os(iOS)
import UniformTypeIdentifiers
#endif

struct CreatePlaylistSheet: View {
    private enum Field: Hashable {
        case name, description, aiPrompt
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appContainer) private var container
    @State private var viewModel: CreatePlaylistViewModel?
    @State private var selectedGradient: PlaylistGradientShape?
    /// Whether the PHOTO is the chosen cover. Separate from "a photo is picked" (pendingImage) so a picked
    /// photo's preview survives switching to another cover and back.
    @State private var photoIsCover = false
    /// Cover carousel mounts after presentation — never with the keyboard (starves AudioStreaming).
    @State private var showCoverCarousel = false
    /// True while a text field is focused, and briefly after blur until the keyboard finishes dismissing.
    @State private var coverSuspendedForKeyboard = false
    /// Image-picker covers only register after the user asks for a photo (cheaper first paint).
    @State private var coverArtPickersEnabled = false
    /// Local fields so keystrokes don't invalidate `@Observable` ViewModel (toolbar `canCreate` used to
    /// rebuild the whole sheet — including the cover carousel — on every character).
    @State private var name = ""
    @State private var playlistDescription = ""
    @State private var isPublic = false
    @FocusState private var focusedField: Field?

    @State private var aiPrompt = ""
    @State private var isGeneratingAI = false
    @State private var aiProgress: PlaylistGenerationService.Progress = .preparing
    @State private var aiProgressValue: Double = 0
    @State private var aiError: String?
    @State private var aiMatchedCount: Int?

    var onCreated: ((PlaylistWithSongs) -> Void)? = nil

    #if os(iOS)
    @State private var pendingImage: UIImage?
    @State private var showImageOptions = false
    @State private var showImagePicker = false
    @State private var showCamera = false
    @State private var showFilePicker = false
    @State private var imageToCrop: CroppableImage?
    #endif

    /// Keyboard + cover carousel on screen together stalls the main thread and underruns AudioStreaming.
    private var showsLiveCoverCarousel: Bool {
        showCoverCarousel && !coverSuspendedForKeyboard
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && viewModel?.isCreating != true
            && !isGeneratingAI
    }

    var body: some View {
        NavigationStack {
            Group {
                if let vm = viewModel {
                    content(vm)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(String(localized: "New Playlist", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) { dismiss() }
                        .disabled(viewModel?.isCreating == true || isGeneratingAI)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard let vm = viewModel, let c = container else { return }
                        focusedField = nil
                        vm.name = name
                        vm.description = playlistDescription
                        vm.isPublic = isPublic
                        Task {
                            if let created = await vm.create() {
                                await applyCover(playlistId: created.id, container: c)
                                onCreated?(created)
                                dismiss()
                            }
                        }
                    } label: {
                        if viewModel?.isCreating == true {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(String(localized: "Create", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(!canCreate)
                }
            }
        }
        .tint(Color.cassetteAccent)
        .interactiveDismissDisabled(isGeneratingAI || viewModel?.isCreating == true)
        #if os(iOS)
        .confirmationDialog(String(localized: "Add Cover Art", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), isPresented: $showImageOptions, titleVisibility: .visible) {
            Button(String(localized: "Choose from Library", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showImagePicker = true }
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button(String(localized: "Take a Photo", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showCamera = true }
                }
            }
            Button(String(localized: "Browse Files", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { showFilePicker = true }
            }
            if pendingImage != nil {
                Button(String(localized: "Remove Image", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), role: .destructive) { pendingImage = nil }
            }
            Button(String(localized: "Cancel", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), role: .cancel) {}
        }
        .modifier(CreatePlaylistCoverPickersModifier(
            enabled: coverArtPickersEnabled,
            showImagePicker: $showImagePicker,
            showCamera: $showCamera,
            imageToCrop: $imageToCrop,
            showFilePicker: $showFilePicker,
            pendingImage: $pendingImage
        ))
        #endif
        .task {
            guard let c = container else { return }
            if viewModel == nil {
                viewModel = CreatePlaylistViewModel(
                    playlistService: c.playlistService,
                    toastService: c.toastService
                )
            }
            // Never auto-focus; mount the carousel only after presentation settles, and only
            // while the keyboard is down (see `coverSuspendedForKeyboard`).
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            showCoverCarousel = true
        }
        .onChange(of: focusedField) { _, field in
            if field != nil {
                coverSuspendedForKeyboard = true
            } else {
                // Remount only after the keyboard animation finishes — stacking both hitching audio.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard focusedField == nil else { return }
                    coverSuspendedForKeyboard = false
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ vm: CreatePlaylistViewModel) -> some View {
        ScrollView {
            VStack(spacing: CassetteSpacing.xl) {
                coverSection
                    .padding(.top, CassetteSpacing.s)

                VStack(spacing: CassetteSpacing.s) {
                    TextField(String(localized: "Playlist Title", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), text: $name)
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .focused($focusedField, equals: .name)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                        .padding(.vertical, CassetteSpacing.s)
                        .disabled(isGeneratingAI)

                    TextField(String(localized: "Description", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), text: $playlistDescription, axis: .vertical)
                        .multilineTextAlignment(.center)
                        .lineLimit(1...4)
                        .focused($focusedField, equals: .description)
                        .disabled(isGeneratingAI)
                }
                .padding(.horizontal, CassetteSpacing.l)

                Toggle(isOn: $isPublic) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Public Playlist")
                            Text(isPublic ? "Other server users can open this playlist." : "Only you can open this playlist.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: isPublic ? "globe" : "lock.fill")
                    }
                }
                .tint(.cassetteAccent)
                .padding(.horizontal, CassetteSpacing.l)
                .disabled(isGeneratingAI)

                aiAssistSection(vm)
                    .padding(.horizontal, CassetteSpacing.l)
            }
            .padding(.top, CassetteSpacing.m)
            .padding(.bottom, CassetteSpacing.xl)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// Live carousel only when the keyboard is down. While typing, keep a cheap spacer so we don't
    /// pay Mesh/gradient + scroll-snap layout on every keystroke (that underruns audio).
    @ViewBuilder
    private var coverSection: some View {
        if showsLiveCoverCarousel {
            coverCarousel
        } else {
            RoundedRectangle(cornerRadius: CassetteCornerRadius.large, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
                .frame(maxWidth: 280)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    if coverSuspendedForKeyboard {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func aiAssistSection(_ vm: CreatePlaylistViewModel) -> some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.m) {
            Label(String(localized: "Apple Intelligence", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale), systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField(
                String(localized: "Describe the playlist you want…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
                text: $aiPrompt,
                axis: .vertical
            )
            .lineLimit(2...5)
            .focused($focusedField, equals: .aiPrompt)
            .padding(CassetteSpacing.m)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(isGeneratingAI)

            if isGeneratingAI {
                VStack(alignment: .leading, spacing: CassetteSpacing.s) {
                    ProgressView(value: aiProgressValue, total: 1.0)
                        .tint(Color.cassetteAccent)
                    Text(aiProgressLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let aiError {
                Text(aiError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if let aiMatchedCount {
                Text(
                    String(
                        localized: "AI filled title, description, cover, and \(aiMatchedCount) matching songs from your library. Review, then Create.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Button {
                focusedField = nil
                Task { await runAIAssist(vm) }
            } label: {
                HStack {
                    if isGeneratingAI {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(String(localized: "Fill with AI", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.cassetteAccent)
            .disabled(
                aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || isGeneratingAI
                    || vm.isCreating
            )

            Text(
                PlaylistGenerationService.isAvailable
                    ? String(localized: "Scans songs in your library, drafts several versions, and fills title, description, cover style, and tracks.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
                    : String(localized: "Apple Intelligence isn’t available — Cassette will still scan your library and keyword-match your description.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(CassetteSpacing.m)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var aiProgressLabel: String {
        switch aiProgress {
        case .preparing:
            return String(localized: "Preparing…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .scanning:
            return String(localized: "Scanning your library…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .drafting(let version, let total):
            return String(localized: "Drafting playlist \(version) of \(total)…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .matching(let version, let total):
            return String(localized: "Matching draft \(version) of \(total) to your library…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .comparing:
            return String(localized: "Comparing versions for the most natural mix…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .resolving:
            return String(localized: "Gathering selected songs…", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        case .finished:
            return String(localized: "Done", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
        }
    }

    private func updateAIProgress(_ next: PlaylistGenerationService.Progress) {
        aiProgress = next
        // Avoid withAnimation here — it re-layouts the sheet (and remounts covers) on every tick.
        aiProgressValue = Self.fraction(for: next)
    }

    private static func fraction(for progress: PlaylistGenerationService.Progress) -> Double {
        switch progress {
        case .preparing: return 0.05
        case .scanning: return 0.18
        case .drafting(let version, let total):
            return 0.25 + 0.4 * (Double(version) / Double(max(total, 1)))
        case .matching(let version, let total):
            return 0.65 + 0.15 * (Double(version) / Double(max(total, 1)))
        case .comparing: return 0.82
        case .resolving: return 0.92
        case .finished: return 1.0
        }
    }

    private func runAIAssist(_ vm: CreatePlaylistViewModel) async {
        guard let container else { return }
        let prompt = aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        isGeneratingAI = true
        aiError = nil
        aiMatchedCount = nil
        updateAIProgress(.preparing)
        defer { isGeneratingAI = false }

        do {
            let draft = try await PlaylistGenerationService.generate(
                prompt: prompt,
                libraryService: container.libraryService
            ) { updateAIProgress($0) }

            name = draft.name
            if let blurb = draft.description?.trimmingCharacters(in: .whitespacesAndNewlines),
               !blurb.isEmpty {
                playlistDescription = blurb
            } else {
                playlistDescription = prompt
            }

            if let shapeRaw = draft.coverShape,
               let shape = PlaylistGradientShape(rawValue: shapeRaw) {
                selectedGradient = shape
                photoIsCover = false
            } else if selectedGradient == nil {
                selectedGradient = .verticalFade
                photoIsCover = false
            }

            let songs: [Song]
            if !draft.songs.isEmpty {
                songs = draft.songs
                updateAIProgress(.finished)
            } else {
                songs = await PlaylistGenerationService.resolveTracks(
                    from: draft,
                    libraryService: container.libraryService
                ) { updateAIProgress($0) }
            }

            vm.pendingSongs = songs
            aiMatchedCount = songs.count
            if songs.isEmpty {
                aiError = String(localized: "Couldn’t match songs in your library. Title, description, and cover were still filled — edit and Create, or try another prompt.", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale)
            }
        } catch {
            aiError = error.localizedDescription
        }
    }

    private var photoPreviewImage: PlatformImage? {
        #if os(iOS)
        return pendingImage
        #else
        return nil
        #endif
    }

    /// Create-flow cover carousel. Title is NOT bound live to the text field — that rebuilt every
    /// gradient card on each keystroke and hitching audio. Placeholder stays until create.
    private var coverCarousel: some View {
        PlaylistCoverCarousel(
            title: "",
            selectedGradient: selectedGradient,
            isPhotoSelected: photoIsCover,
            photoPreview: photoPreviewImage,
            showsPhotoOption: {
                #if os(iOS)
                true
                #else
                false
                #endif
            }(),
            leadingLabel: String(localized: "None", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale),
            onSelectLeading: {
                selectedGradient = nil
                photoIsCover = false
            },
            onSelectPhoto: {
                selectedGradient = nil
                photoIsCover = true
            },
            onRequestPhotoPicker: {
                selectedGradient = nil
                photoIsCover = true
                #if os(iOS)
                coverArtPickersEnabled = true
                showImageOptions = true
                #endif
            },
            onSelectGradient: { shape in
                selectedGradient = shape
                photoIsCover = false
            }
        )
    }

    private func applyCover(playlistId: String, container c: AppContainer) async {
        let manager = PlaylistCoverManager(
            serverState: c.serverState,
            serverService: c.serverService,
            downloadService: c.downloadService,
            artworkImageCache: c.artworkImageCache
        )
        if let shape = selectedGradient {
            let spec = PlaylistGradientSpec.neutral(shape: shape)
            await manager.applyGradientCover(spec, playlistId: playlistId)
            if let serverId = c.serverState.activeServer?.id {
                PlaylistCoverStore(modelContainer: c.modelContainer)
                    .save(spec, playlistId: playlistId, serverId: serverId, isUserPicked: true)
            }
            return
        }
        #if os(iOS)
        if photoIsCover, let image = pendingImage, let data = image.jpegData(compressionQuality: 0.85) {
            await manager.applyImageCover(data, playlistId: playlistId)
        }
        #endif
    }
}

#if os(iOS)
/// Lazily attaches image-picker covers so opening New Playlist does not pay for them up front.
private struct CreatePlaylistCoverPickersModifier: ViewModifier {
    let enabled: Bool
    @Binding var showImagePicker: Bool
    @Binding var showCamera: Bool
    @Binding var imageToCrop: CroppableImage?
    @Binding var showFilePicker: Bool
    @Binding var pendingImage: UIImage?

    func body(content: Content) -> some View {
        if enabled {
            content
                .fullScreenCover(isPresented: $showImagePicker) {
                    ImagePickerController(
                        sourceType: .photoLibrary,
                        allowsEditing: false,
                        onPick: { presentCrop($0) },
                        onCancel: {}
                    )
                    .ignoresSafeArea()
                }
                .fullScreenCover(isPresented: $showCamera) {
                    ImagePickerController(
                        sourceType: .camera,
                        allowsEditing: false,
                        onPick: { presentCrop($0) },
                        onCancel: {}
                    )
                    .ignoresSafeArea()
                }
                .fullScreenCover(item: $imageToCrop) { croppable in
                    SquareCropView(
                        image: croppable.image,
                        onCrop: { pendingImage = $0; imageToCrop = nil },
                        onCancel: { imageToCrop = nil }
                    )
                }
                .fileImporter(
                    isPresented: $showFilePicker,
                    allowedContentTypes: [.jpeg, .png, .heic, .webP],
                    allowsMultipleSelection: false
                ) { result in
                    guard case .success(let urls) = result, let url = urls.first else { return }
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                        presentCrop(img)
                    }
                }
        } else {
            content
        }
    }

    private func presentCrop(_ image: UIImage) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            imageToCrop = CroppableImage(image: image)
        }
    }
}
#endif
