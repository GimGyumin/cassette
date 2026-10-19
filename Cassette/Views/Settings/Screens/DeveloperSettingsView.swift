import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct DeveloperSettingsView: View {
    @State private var exporting = false
    @State private var exportedURL: URL?
    @State private var errorMessage: String?
    @State private var showShare = false

    var body: some View {
        Form {
            Section {
                NavigationLink("Analytics Logs") { AnalyticsLogListView() }
                SettingsActionRow("Export Logs", isBusy: exporting) {
                    Task { await exportLogs() }
                }
                #if os(macOS)
                if let exportedURL {
                    ShareLink(item: exportedURL) { Label("Share Logs", systemImage: "square.and.arrow.up") }
                }
                #endif
            } footer: {
                Text("Exports available logs from this app session. Authentication values are removed.")
            }
        }
        .formStyle(.grouped)
        .modifier(SettingsSubpageStyle())
        .navigationTitle(Text("Developer"))
        .alert("Log Export Failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        #if os(iOS)
        .sheet(isPresented: $showShare, onDismiss: removeExport) {
            if let exportedURL { ActivityShareSheet(activityItems: [exportedURL]) }
        }
        #endif
        .onDisappear {
            #if os(macOS)
            removeExport()
            #endif
        }
    }

    private func exportLogs() async {
        guard !exporting else { return }
        exporting = true
        defer { exporting = false }
        removeExport()
        do {
            exportedURL = try await LogExportService.export()
            showShare = true
        } catch { errorMessage = error.localizedDescription }
    }

    private func removeExport() {
        if let exportedURL { try? FileManager.default.removeItem(at: exportedURL) }
        exportedURL = nil
    }
}

struct AnalyticsLogListView: View {
    @State private var files: [LogExportService.LogFile] = []
    @State private var query = ""
    @State private var selected: Set<URL> = []
    @State private var selecting = false
    @State private var newestFirst = true
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var showShare = false
    @State private var showDelete = false

    private var visibleFiles: [LogExportService.LogFile] {
        let matches = files.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
        return newestFirst ? matches : matches.reversed()
    }

    var body: some View {
        List(selection: $selected) {
            Section {
                Text("Saved Cassette logs appear here. Opening this screen refreshes the current session. Authentication values are removed; up to 20 sessions are kept.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            Section {
                ForEach(visibleFiles) { file in
                    NavigationLink {
                        AnalyticsLogDetailView(file: file)
                    } label: {
                        Text(verbatim: file.name)
                            .font(.body).lineLimit(nil)
                            .padding(.vertical, 8)
                    }
                    .tag(file.url)
                }
                if files.isEmpty && !loading {
                    Text("No saved logs").foregroundStyle(.secondary)
                } else if visibleFiles.isEmpty && !loading {
                    Text("No matching logs").foregroundStyle(.secondary)
                }
            } header: {
                Text("This Device").textCase(nil)
            } footer: {
                Text("\(visibleFiles.count) logs")
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle("Analytics Logs")
        .toolbarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .toolbar, prompt: "Search Analytics Logs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(selecting ? "Done" : "Select") {
                    selecting.toggle()
                    if !selecting { selected.removeAll() }
                }
            }
            #if os(iOS)
            ToolbarItemGroup(placement: .bottomBar) {
                sortMenu
                Spacer()
                if selecting {
                    Button("Share Logs", systemImage: "square.and.arrow.up") { showShare = true }
                        .disabled(selected.isEmpty)
                    Button("Delete", systemImage: "trash", role: .destructive) { showDelete = true }
                        .disabled(selected.isEmpty)
                } else {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                        .disabled(loading)
                }
            }
            #else
            ToolbarItemGroup {
                sortMenu
                ShareLink(items: selected.sorted(by: { $0.path < $1.path })) {
                    Label("Share Logs", systemImage: "square.and.arrow.up")
                }.disabled(selected.isEmpty)
                Button("Delete", systemImage: "trash", role: .destructive) { showDelete = true }
                    .disabled(selected.isEmpty)
            }
            #endif
        }
        #if os(iOS)
        .environment(\.editMode, .constant(selecting ? .active : .inactive))
        .sheet(isPresented: $showShare) {
            ActivityShareSheet(activityItems: selected.sorted(by: { $0.path < $1.path }))
        }
        #endif
        .overlay { if loading && files.isEmpty { ProgressView() } }
        .refreshable { await refresh() }
        .task { await refresh() }
        .confirmationDialog("Delete Selected Logs?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteSelected() }
        }
        .alert("Log Export Failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $newestFirst) {
                Text("Newest First").tag(true)
                Text("Oldest First").tag(false)
            }
            if selecting {
                Button("Select All") { selected.formUnion(visibleFiles.map(\.url)) }
            }
        } label: { Label("Sort", systemImage: "line.3.horizontal.decrease") }
    }

    private func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            try await LogExportService.captureCurrentSession()
            files = try await Task.detached(priority: .utility) { try LogExportService.list() }.value
            selected.formIntersection(files.map(\.url))
        } catch {
            // Keep older archives usable even if this process's OSLog store is unavailable.
            files = (try? LogExportService.list()) ?? files
            errorMessage = error.localizedDescription
        }
    }

    private func deleteSelected() {
        do {
            for file in files where selected.contains(file.url) {
                try FileManager.default.removeItem(at: file.url)
            }
            files = try LogExportService.list()
            selected.removeAll()
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct AnalyticsLogDetailView: View {
    let file: LogExportService.LogFile
    @State private var text: String?
    @State private var error: String?

    var body: some View {
        Group {
            if let text { ReadOnlyLogText(text: text) }
            else if let error { ContentUnavailableView(error, systemImage: "doc.text") }
            else { ProgressView() }
        }
        .navigationTitle(Text(verbatim: file.name))
        .toolbarTitleDisplayMode(.inline)
        .toolbar { ShareLink(item: file.url) { Label("Share Logs", systemImage: "square.and.arrow.up") } }
        .task {
            do { text = try await LogExportService.read(file) }
            catch { self.error = error.localizedDescription }
        }
    }
}

#if os(iOS)
private struct ReadOnlyLogText: UIViewRepresentable {
    let text: String
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.alwaysBounceVertical = true
        view.adjustsFontForContentSizeCategory = true
        view.font = UIFontMetrics.default.scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
#else
private struct ReadOnlyLogText: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            view.textContainerInset = NSSize(width: 12, height: 16)
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let view = scroll.documentView as? NSTextView, view.string != text { view.string = text }
    }
}
#endif
