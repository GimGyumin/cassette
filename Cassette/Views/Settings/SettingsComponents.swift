// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

// MARK: - Section chrome

/// Apple Music-style section header: small, secondary, never uppercase.
/// Use instead of a bare `Text` in a `Section { } header: { }` so the whole
/// settings surface keeps one quiet hierarchy.
struct SettingsSectionHeader: View {
    private let content: Text

    init(_ title: LocalizedStringKey) {
        self.content = Text(title)
    }

    /// For headers that already resolved their localized string.
    init(verbatim title: String) {
        self.content = Text(verbatim: title)
    }

    var body: some View {
        content
            .font(.cassetteSettingsHeader)
            .foregroundStyle(.secondary)
            .textCase(nil)
    }
}

/// Compact footer used only where a setting genuinely needs explaining.
struct SettingsSectionFooter: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.cassetteFootnote)
            .foregroundStyle(.secondary)
            .textCase(nil)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Rows

/// Row label for toggles and navigation links: title plus an optional
/// secondary subtitle, mirroring Apple Music's quality rows.
struct SettingsRowTitle: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?

    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CassetteSpacing.xs) {
            Text(title)
                .font(.cassetteBody)
            if let subtitle {
                Text(subtitle)
                    .font(.cassetteCellSubtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Trailing value + chevron row that pushes a detail screen.
struct SettingsNavigationRow<Destination: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var value: String?
    @ViewBuilder let destination: () -> Destination

    init(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        value: String? = nil,
        @ViewBuilder destination: @escaping () -> Destination
    ) {
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.destination = destination
    }

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            SettingsValueRow(title, subtitle: subtitle, value: value)
        }
    }
}

/// Static title + secondary trailing value (no chevron) — status read-outs.
struct SettingsValueRow: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var value: String?

    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, value: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.value = value
    }

    var body: some View {
        LabeledContent {
            if let value {
                Text(value)
            }
        } label: {
            SettingsRowTitle(title, subtitle: subtitle)
                .foregroundStyle(.primary)
        }
    }
}

/// Button row. Only destructive actions use red, matching Apple Music.
struct SettingsActionRow: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var isDestructive = false
    var isBusy = false
    let action: () -> Void

    init(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        isDestructive: Bool = false,
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.isDestructive = isDestructive
        self.isBusy = isBusy
        self.action = action
    }

    var body: some View {
        Button(role: isDestructive ? .destructive : nil, action: action) {
            HStack(spacing: CassetteSpacing.s) {
                SettingsRowTitle(title, subtitle: subtitle)
                    .foregroundStyle(isDestructive ? Color.red : Color.blue)
                Spacer(minLength: CassetteSpacing.s)
                if isBusy {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .disabled(isBusy)
    }
}

// MARK: - Single-choice list

/// Any model that can be presented in a `SettingsChoiceList`.
protocol SettingsChoiceItem: Hashable {
    var choiceTitle: String { get }
    var choiceSubtitle: String? { get }
}

extension SettingsChoiceItem {
    var choiceSubtitle: String? { nil }
}

/// Whole-row choices with a stable trailing checkmark and VoiceOver selection state.
struct SettingsChoiceList<Item: SettingsChoiceItem>: View {
    let navigationTitle: LocalizedStringKey
    var footer: LocalizedStringKey?
    let items: [Item]
    @Binding var selection: Item
    var subtitle: ((Item) -> String?)?

    init(
        navigationTitle: LocalizedStringKey,
        footer: LocalizedStringKey? = nil,
        items: [Item],
        selection: Binding<Item>,
        subtitle: ((Item) -> String?)? = nil
    ) {
        self.navigationTitle = navigationTitle
        self.footer = footer
        self.items = items
        self._selection = selection
        self.subtitle = subtitle
    }

    var body: some View {
        Form {
            Section {
                ForEach(items, id: \.self) { item in
                    Button {
                        selection = item
                    } label: {
                        HStack(spacing: CassetteSpacing.l) {
                            VStack(alignment: .leading, spacing: CassetteSpacing.xs) {
                                Text(item.choiceTitle)
                                    .font(.cassetteBody)
                                    .foregroundStyle(Color.primary)
                                if let detail = subtitle?(item) ?? item.choiceSubtitle {
                                    Text(detail)
                                        .font(.cassetteCellSubtitle)
                                        .foregroundStyle(Color.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: CassetteSpacing.s)
                            Image(systemName: "checkmark")
                                .font(.cassetteSettingsHeader)
                                .foregroundStyle(.blue)
                                .opacity(selection == item ? 1 : 0)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(selection == item ? [.isSelected] : [])
                }
            } footer: {
                if let footer {
                    SettingsSectionFooter(footer)
                }
            }
        }
        .modifier(SettingsSubpageStyle())
        .navigationTitle(navigationTitle)
        #if os(iOS)
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Shared icon component

/// Fixed-size setting tiles keep symbols and row labels aligned across subpages.
struct SettingsIcon: View {
    let systemImage: String
    let color: Color
    @Environment(\.settingsSubduedIcons) private var subdued

    private let side: CGFloat = 30

    var body: some View {
        Image(systemName: systemImage)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(subdued ? Color.secondary : Color.white)
            .frame(width: subdued ? 28 : side, height: subdued ? 28 : side)
            .background(subdued ? Color.secondary.opacity(0.10) : color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.black.opacity(subdued ? 0 : 0.08), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

private struct SettingsSubduedIconsKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var settingsSubduedIcons: Bool {
        get { self[SettingsSubduedIconsKey.self] }
        set { self[SettingsSubduedIconsKey.self] = newValue }
    }
}

// MARK: - Shared subpage chrome

struct SettingsSubpageStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            // One restrained icon treatment everywhere: no per-row rainbow.
            .environment(\.settingsSubduedIcons, true)
            .font(.cassetteBody)
            .tint(.blue)
            .toggleStyle(SettingsToggleStyle())
            .headerProminence(.standard)
            #if os(iOS)
            .environment(\.defaultMinListRowHeight, CassetteSettingsLayout.minimumRowHeight)
            .listStyle(.insetGrouped)
            .listRowInsets(CassetteSettingsLayout.rowInsets)
            .listSectionSpacing(CassetteSpacing.xxl)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            #endif
    }
}

/// Settings use the system green switch independently of the blue links/checkmarks.
private struct SettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(isOn: configuration.$isOn) { configuration.label }
            .toggleStyle(.switch)
            .tint(.green)
    }
}

struct SettingsRowLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    let color: Color

    var body: some View {
        Label {
            Text(title)
        } icon: {
            SettingsIcon(systemImage: systemImage, color: color)
        }
    }
}

struct SettingsTextFieldRow<Field: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let color: Color
    @ViewBuilder let field: () -> Field

    var body: some View {
        LabeledContent {
            field()
                .multilineTextAlignment(.trailing)
        } label: {
            SettingsRowLabel(title: title, systemImage: systemImage, color: color)
        }
    }
}
