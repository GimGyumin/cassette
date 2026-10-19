// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

extension View {
    @ViewBuilder func cassetteSectionIndexLabel(_ label: String?) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) { sectionIndexLabel(label) }
        else { self }
    }

    /// iOS owns index layout, dragging and accessibility. Keep the existing fallback
    /// for older systems and macOS, which has no List section-index control.
    @ViewBuilder func cassetteListIndex(letters: Set<String>, isVisible: Bool,
                                       onSelect: @escaping (String) -> Void) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            listSectionIndexVisibility(isVisible ? .visible : .hidden)
        } else {
            legacyListIndex(letters: letters, isVisible: isVisible, onSelect: onSelect)
        }
        #else
        legacyListIndex(letters: letters, isVisible: isVisible, onSelect: onSelect)
        #endif
    }

    private func legacyListIndex(letters: Set<String>, isVisible: Bool,
                                 onSelect: @escaping (String) -> Void) -> some View {
        safeAreaInset(edge: .trailing, spacing: 0) {
            if isVisible {
                AlphabetJumpBar(availableLetters: letters, onLetterTap: onSelect)
                    .padding(.trailing, 4)
            }
        }
    }
}

struct AlphabetJumpBar: View {
    let availableLetters: Set<String>
    let onLetterTap: (String) -> Void

    @State private var accessibilityFocusedLetter: String?

    #if os(iOS)
    @State private var lastLetterReported: String?
    @State private var lastHapticTime: Date = .distantPast
    #endif

    private static let letters = [
        "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
        "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "#"
    ]

    var body: some View {
        #if os(iOS)
        iOSBody.modifier(alphabetAccessibilityModifier)
        #else
        macOSBody.modifier(alphabetAccessibilityModifier)
        #endif
    }

    private var alphabetAccessibilityModifier: AlphabetJumpBarAccessibility {
        AlphabetJumpBarAccessibility(
            availableLetters: availableLetters,
            letters: Self.letters,
            focusedLetter: $accessibilityFocusedLetter,
            onLetterTap: onLetterTap
        )
    }

    #if os(iOS)
    private var iOSBody: some View {
        VStack(spacing: 2) {
            ForEach(Self.letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14, height: 16)
                    .foregroundStyle(
                        availableLetters.contains(letter)
                            ? Color.cassetteAccent
                            : Color.secondary.opacity(0.3)
                    )
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let index = max(0, min(Self.letters.count - 1, Int((value.location.y - 8) / 18)))
                    let letter = Self.letters[index]
                    let now = Date()
                    guard letter != lastLetterReported,
                          availableLetters.contains(letter),
                          now.timeIntervalSince(lastHapticTime) > 0.04 else { return }
                    lastLetterReported = letter
                    lastHapticTime = now
                    accessibilityFocusedLetter = letter
                    HapticFeedback.selection.trigger()
                    onLetterTap(letter)
                }
                .onEnded { _ in
                    lastLetterReported = nil
                }
        )
    }
    #else
    private var macOSBody: some View {
        VStack(spacing: 2) {
            ForEach(Self.letters, id: \.self) { letter in
                Button {
                    if availableLetters.contains(letter) {
                        accessibilityFocusedLetter = letter
                        onLetterTap(letter)
                    }
                } label: {
                    Text(letter)
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 14, height: 14)
                        .foregroundStyle(
                            availableLetters.contains(letter)
                                ? Color.cassetteAccent
                                : Color.secondary.opacity(0.3)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!availableLetters.contains(letter))
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }
    #endif
}

private struct AlphabetJumpBarAccessibility: ViewModifier {
    let availableLetters: Set<String>
    let letters: [String]
    @Binding var focusedLetter: String?
    let onLetterTap: (String) -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Alphabet index", bundle: AppUILanguage.localizationBundle, locale: AppUILanguage.locale))
            .accessibilityValue(focusedLetter ?? "")
            .accessibilityAdjustableAction { direction in
                let available = letters.filter { availableLetters.contains($0) }
                guard !available.isEmpty else { return }

                let currentIndex = focusedLetter.flatMap { available.firstIndex(of: $0) }

                let nextIndex: Int
                switch direction {
                case .increment:
                    nextIndex = currentIndex.map { min($0 + 1, available.count - 1) } ?? 0
                case .decrement:
                    nextIndex = currentIndex.map { max($0 - 1, 0) } ?? available.count - 1
                @unknown default:
                    return
                }

                let letter = available[nextIndex]
                focusedLetter = letter
                onLetterTap(letter)
            }
    }
}

// MARK: - Helpers

/// Returns the uppercased first letter of `name`, or "#" for names starting with a non-letter.
func alphabetFirstLetter(of name: String) -> String {
    guard let first = name.first else { return "#" }
    let upper = String(first).uppercased()
    return upper.first?.isLetter == true ? upper : "#"
}

extension Collection {
    /// Computes the set of first letters present in the collection for a given string key path.
    func availableAlphabetLetters(keyPath: KeyPath<Element, String>) -> Set<String> {
        Set(self.map { alphabetFirstLetter(of: $0[keyPath: keyPath]) })
    }
}

/// Returns the ID of the first item whose key-path value starts with `letter`.
func firstAlphabetItemID<T: Identifiable>(
    forLetter letter: String,
    in items: [T],
    keyPath: KeyPath<T, String>
) -> T.ID? {
    items.first { alphabetFirstLetter(of: $0[keyPath: keyPath]) == letter }?.id
}
