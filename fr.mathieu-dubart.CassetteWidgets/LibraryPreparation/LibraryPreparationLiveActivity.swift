// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.

import WidgetKit
import SwiftUI

#if os(iOS)
struct LibraryPreparationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LibraryPreparationActivityAttributes.self) { context in
            LockScreenPreparationView(context: context)
                .activityBackgroundTint(activityBackground(context.state))
                .activitySystemActionForegroundColor(Color("CassetteAccent"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PreparationSymbol(state: context.state, size: 40)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cassette")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(context.state.phaseTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(progressLabel(context.state))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(activityTint(context.state))
                        .minimumScaleFactor(0.8)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        PreparationProgressBar(state: context.state)
                        PreparationDetail(state: context.state, serverName: context.attributes.serverName)
                        if let date = context.state.estimatedCompletion, !context.state.isFinished {
                            HStack {
                                Text(context.state.etaTitle ?? "")
                                Spacer()
                                Text(date, style: .time).monospacedDigit()
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)
                }
            } compactLeading: {
                PreparationSymbol(state: context.state, size: 22)
                    .accessibilityLabel(context.state.phaseTitle)
            } compactTrailing: {
                Text(progressLabel(context.state))
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .minimumScaleFactor(0.8)
            } minimal: {
                PreparationSymbol(state: context.state, size: 22)
                    .accessibilityLabel(context.state.phaseTitle)
            }
            .keylineTint(activityTint(context.state))
        }
    }
}

private struct LockScreenPreparationView: View {
    let context: ActivityViewContext<LibraryPreparationActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                PreparationSymbol(state: context.state, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cassette")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(context.state.phaseTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Text(progressLabel(context.state))
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(activityTint(context.state))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .layoutPriority(1)
            }
            VStack(alignment: .leading, spacing: 8) {
                PreparationProgressBar(state: context.state)
                PreparationDetail(state: context.state, serverName: context.attributes.serverName)
                        if let date = context.state.estimatedCompletion, !context.state.isFinished {
                            HStack {
                                Text(context.state.etaTitle ?? "")
                                Spacer()
                                Text(date, style: .time).monospacedDigit()
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
            }
        }
        .padding(16)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }
}

/// The app shares a bounded 128px frame; the extension never fetches or decodes the original.
private struct PreparationSymbol: View {
    let state: LibraryPreparationActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        Group {
            if let id = state.activeCoverArtId, let image = SharedWidgetData.image(forCoverArtId: id) {
                Image(platformImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: state.symbol)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(activityTint(state))
            }
        }
        .frame(width: size, height: size)
        .background(activityTint(state).opacity(0.13))
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
        .accessibilityHidden(true)
    }
}

private struct PreparationDetail: View {
    let state: LibraryPreparationActivityAttributes.ContentState
    let serverName: String

    var body: some View {
        HStack(spacing: 8) {
            Text(serverName)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if state.phase == .covers, state.coversTotal > 0, !state.isFinished {
                Text("\(min(max(0, state.coversCompleted), state.coversTotal).formatted()) / \(state.coversTotal.formatted())")
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

private struct PreparationProgressBar: View {
    let state: LibraryPreparationActivityAttributes.ContentState

    var body: some View {
        if let fraction = state.fraction {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(activityTint(state))
                .accessibilityLabel(state.phaseTitle)
        } else if !state.isFinished {
            // Unknown totals must not look like a stalled 0% or a completed 100%.
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(state.phaseTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private func activityBackground(_ state: LibraryPreparationActivityAttributes.ContentState) -> Color {
    guard let rgb = state.backgroundRGB else { return Color(white: 0.08) }
    // Darkened artwork tint maintains white text contrast regardless of album brightness.
    return Color(red: Double((rgb >> 16) & 255) / 255 * 0.22,
                 green: Double((rgb >> 8) & 255) / 255 * 0.22,
                 blue: Double(rgb & 255) / 255 * 0.22)
}

private func activityTint(_ state: LibraryPreparationActivityAttributes.ContentState) -> Color {
    state.failed ? .orange : Color("CassetteAccent")
}

private func progressLabel(_ state: LibraryPreparationActivityAttributes.ContentState) -> String {
    if state.isFinished { return state.failed ? "!" : "✓" }
    guard let fraction = state.fraction else { return "…" }
    return "\(Int((fraction * 100).rounded()))%"
}
#endif
