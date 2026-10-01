// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI
#if os(iOS)
import AVFoundation
import MediaPlayer
#endif

/// Custom volume slider matching Apple Music Now Playing:
/// thin pill at rest, thick white pill while pressed/dragging — no circular thumb.
/// Displays `AVAudioSession.outputVolume` (KVO). Writes system volume via hidden `MPVolumeView`
/// only for user-posted `userTarget` values (no KVO feedback loop).
struct SystemVolumeView: View {
    var contentColor: Color = .white

    #if os(iOS)
    @State private var observer = SystemVolumeObserver()

    var body: some View {
        ProgressSlider(
            value: Binding(
                get: { TimeInterval(observer.displayVolume) },
                set: { newValue in
                    let v = Float(max(0, min(1, newValue)))
                    #if !targetEnvironment(simulator)
                    observer.setUserVolume(v)
                    #else
                    observer.displayVolume = v
                    #endif
                }
            ),
            total: 1.0,
            onEditingChanged: { editing in observer.setEditing(editing) },
            trackColor: contentColor.opacity(0.22),
            fillColor: contentColor,
            height: 36,
            trackHeight: 6,
            activeTrackHeight: 28,
            dragMinimumDistance: 0,
            // A tap only shows the active bar — it must not slam the volume to that position.
            ignoresTapForValueChange: true
        )
        .background {
            #if !targetEnvironment(simulator)
            // Keep one MPVolumeView attached for the lifetime of this control. Re-creating a
            // zero-sized view for every drag sample occasionally left its internal UISlider
            // unavailable, so the visual slider moved while the system volume did not.
            //
            // Mounted lazily: MPVolumeView talks to MediaRemote, which is denied to third-party
            // apps (`getSystemIsMuted` → ClientNotEntitled). There is no reason to pay that (or
            // log it) at launch when the volume slider is never touched.
            if observer.needsVolumeWriter {
                HiddenVolumeWriter(observer: observer)
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            #endif
        }
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(observer.displayVolume * 100))%")
        .task {
            // Initialize from the REAL current volume on appear — covers a cold-start init that read a stale
            // outputVolume before the session was configured. Display-only, so it can't clobber the system.
            observer.refreshFromSystem()
        }
    }
    #else
    var body: some View {
        EmptyView()
    }
    #endif
}

#if os(iOS)
// MARK: - Volume observer

/// Mirrors `AVAudioSession.outputVolume` into `displayVolume` (KVO) so physical buttons / Control Center move
/// the slider. `displayVolume` drives the slider position; `userTarget` (set ONLY by the slider's `set`) is the
/// value to push to the system. The KVO/init never set `userTarget`, so observation and the cold-start read
/// never write back.
@Observable
@MainActor
private final class SystemVolumeObserver {
    /// Slider position. Updated by the user's input (immediate) and by the KVO (animated, when not dragging).
    var displayVolume: Float = AVAudioSession.sharedInstance().outputVolume
    /// True once the user has touched the control. Gates the hidden `MPVolumeView`, so the
    /// MediaRemote round-trip it performs only happens for someone who actually changes volume.
    private(set) var needsVolumeWriter = false
    /// True while the user is dragging — keeps the KVO from yanking the slider position out from under the finger.
    private var isEditing = false
    /// Retained until MPVolumeView has created its private UISlider.
    private var pendingUserTarget: Float?
    private weak var volumeView: MPVolumeView?
    private var observation: NSKeyValueObservation?

    init() {
        displayVolume = AVAudioSession.sharedInstance().outputVolume
        observation = AVAudioSession.sharedInstance().observe(
            \.outputVolume, options: [.new]
        ) { [weak self] _, change in
            guard let newVolume = change.newValue else { return }
            Task { @MainActor [weak self] in
                // The drag drives the value while editing — don't fight it with the observation.
                guard let self, !self.isEditing else { return }
                // Spring is cosmetic on the DISPLAY only; the write value (`userTarget`) is separate + un-animated.
                withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                    self.displayVolume = newVolume
                }
            }
        }
    }

    /// Re-sync the displayed value to the real system volume — used on appear to correct a cold-start init that
    /// read `outputVolume` before the audio session was configured (it can return a stale value then).
    /// Display-only; never writes back (`userTarget` is untouched).
    func refreshFromSystem() {
        displayVolume = AVAudioSession.sharedInstance().outputVolume
    }

    func setEditing(_ editing: Bool) {
        if editing {
            // A press on the slider is enough to need the writer: the value may follow immediately.
            needsVolumeWriter = true
        }
        isEditing = editing
        if !editing {
            // outputVolume KVO can arrive while the drag is active. Refresh after the final
            // MPVolumeView event so the displayed value reflects the value iOS accepted.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, !self.isEditing else { return }
                self.refreshFromSystem()
            }
        }
    }

    func setUserVolume(_ volume: Float) {
        needsVolumeWriter = true
        displayVolume = volume
        pendingUserTarget = volume
        applyPendingUserVolume()
    }

    func attach(_ view: MPVolumeView) {
        volumeView = view
        // MPVolumeView may create its slider after the first layout pass.
        applyPendingUserVolume()
        Task { @MainActor [weak self, weak view] in
            await Task.yield()
            guard let self, let view else { return }
            self.volumeView = view
            self.applyPendingUserVolume()
        }
    }

    private func applyPendingUserVolume() {
        guard let target = pendingUserTarget,
              let slider = volumeView?.subviews.compactMap({ $0 as? UISlider }).first else { return }
        pendingUserTarget = nil
        slider.setValue(target, animated: false)
        // On newer iOS releases assigning UISlider.value alone is not guaranteed to invoke
        // MPVolumeView's volume route. Deliver the same control event as a native drag.
        slider.sendActions(for: .valueChanged)
    }

    // NSKeyValueObservation auto-invalidates on dealloc — no deinit needed.
}

// MARK: - Hidden MPVolumeView for writing system volume

/// Pushes a USER-posted `userTarget` to `MPVolumeView`'s internal `UISlider` (the only iOS API to set the
/// system volume) once, then signals it consumed. A KVO/init-driven display change is never routed here, so
/// there is no feedback loop and the cold-start read can't clobber the real volume. The write is never animated.
private struct HiddenVolumeWriter: UIViewRepresentable {
    let observer: SystemVolumeObserver

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.isUserInteractionEnabled = false
        observer.attach(view)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        observer.attach(uiView)
    }
}
#endif
