#if os(iOS)
import Testing
import UIKit
@testable import Cassette

@Suite("Phone interface rotation")
@MainActor
struct PhoneOrientationTests {
    @Test func delegateDoesNotOverrideLandscapeSupport() {
        let mask = CassetteAppDelegate().application(UIApplication.shared, supportedInterfaceOrientationsFor: nil)
        if ProcessInfo.processInfo.isiOSAppOnMac {
            #expect(mask == .portrait)
        } else if UIDevice.current.userInterfaceIdiom == .pad {
            #expect(mask == .allButUpsideDown)
        } else {
            #expect(mask == .portrait)
            let delegate = CassetteAppDelegate()
            delegate.setFullPlayerPresented(true)
            let mask = delegate.application(UIApplication.shared, supportedInterfaceOrientationsFor: nil)
            #expect(mask.contains(.portrait))
            #expect(mask.contains(.landscapeLeft))
            #expect(mask.contains(.landscapeRight))
            #expect(!mask.contains(.portraitUpsideDown))
        }
    }

    @Test func reopeningCancelsPendingPortraitReturn() async throws {
        let delegate = CassetteAppDelegate()
        delegate.setFullPlayerPresented(true)
        delegate.setFullPlayerPresented(false)
        #expect(delegate.isFullPlayerPresented)
        delegate.setFullPlayerPresented(true)
        try await Task.sleep(for: .milliseconds(180))
        #expect(delegate.isFullPlayerPresented)
        delegate.setFullPlayerPresented(false)
        try await Task.sleep(for: .milliseconds(180))
        #expect(!delegate.isFullPlayerPresented)
    }
}
#endif
