// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
@testable import Cassette

// MARK: - Pure classification

@Suite("NetworkCostPolicy")
struct NetworkCostPolicyTests {

    @Test func meteredIsLimited() {
        #expect(NetworkCostPolicy.isLimited(isExpensive: true, isConstrained: false))
    }

    @Test func constrainedIsLimited() {
        // Low Data Mode, or a Wi-Fi link the user marked as metered: not expensive, still limited.
        #expect(NetworkCostPolicy.isLimited(isExpensive: false, isConstrained: true))
    }

    @Test func meteredAndConstrainedIsLimited() {
        #expect(NetworkCostPolicy.isLimited(isExpensive: true, isConstrained: true))
    }

    @Test func unmeteredWiFiIsUnlimited() {
        #expect(!NetworkCostPolicy.isLimited(isExpensive: false, isConstrained: false))
    }

    @Test func measuredSlowLinkIsLimited() {
        // The 1 Mbps case: iOS reports plain Wi-Fi, but the measurement says it cannot carry the
        // original file or run background transfers alongside the stream.
        #expect(
            NetworkCostPolicy.isLimited(
                isExpensive: false,
                isConstrained: false,
                measuredBytesPerSecond: 125_000
            )
        )
    }

    @Test func measuredFastLinkStaysUnlimited() {
        #expect(
            !NetworkCostPolicy.isLimited(
                isExpensive: false,
                isConstrained: false,
                measuredBytesPerSecond: 2_500_000
            )
        )
    }

    @Test func missingOrZeroMeasurementDoesNotImplyLimited() {
        #expect(!NetworkCostPolicy.isLimited(isExpensive: false, isConstrained: false, measuredBytesPerSecond: nil))
        #expect(!NetworkCostPolicy.isLimited(isExpensive: false, isConstrained: false, measuredBytesPerSecond: 0))
    }

    @Test func slowFloorSitsAroundTwoMegabits() {
        #expect(NetworkCostPolicy.isSlow(measuredBytesPerSecond: NetworkCostPolicy.slowBytesPerSecond - 1))
        #expect(!NetworkCostPolicy.isSlow(measuredBytesPerSecond: NetworkCostPolicy.slowBytesPerSecond))
    }
}

// MARK: - ServerState

@MainActor
@Suite("ServerState.isLimitedNetwork")
struct ServerStateLimitedNetworkTests {

    @Test func defaultsToUnlimited() {
        let state = ServerState()
        #expect(!state.isLimitedNetwork)
    }

    @Test func meteredNetworkIsLimited() {
        let state = ServerState()
        state.isExpensive = true
        #expect(state.isLimitedNetwork)
    }

    @Test func constrainedNetworkIsLimited() {
        // The regression this guards: a throttled Wi-Fi / Low Data Mode link used to be reported
        // as unmetered, so cache, prefetch and pre-buffering all ran as if bandwidth were free.
        let state = ServerState()
        state.isNetworkConstrained = true
        #expect(state.isLimitedNetwork)
    }

    @Test func measuredSlowNetworkIsLimited() {
        let state = ServerState()
        state.measuredBytesPerSecond = 125_000
        #expect(state.isLimitedNetwork)
    }

    @Test func measuredFastNetworkIsNotLimited() {
        let state = ServerState()
        state.measuredBytesPerSecond = 5_000_000
        #expect(!state.isLimitedNetwork)
    }
}

// MARK: - Streaming format follows the limited flag

@MainActor
@Suite("StreamingSettings limited-network format")
struct StreamingSettingsLimitedFormatTests {

    @Test func limitedNetworkUsesCellularFormat() {
        let settings = StreamingSettings()
        let previousCellular = settings.cellularFormat
        let previousWiFi = settings.wifiFormat
        defer {
            settings.cellularFormat = previousCellular
            settings.wifiFormat = previousWiFi
        }

        settings.cellularFormat = .aac128
        settings.wifiFormat = .matchStream

        #expect(settings.formatForCurrentNetwork(isLimited: true) == .aac128)
        #expect(settings.formatForCurrentNetwork(isLimited: false) == .matchStream)
    }
}
