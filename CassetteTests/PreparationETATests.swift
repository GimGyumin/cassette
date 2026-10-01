import Foundation
import Testing
@testable import Cassette

@Suite("Preparation completion estimate")
struct PreparationETATests {
    @Test func waitsForMeasuredWorkAndResetsAcrossPhases() {
        var estimator = PreparationETA()
        let start = Date(timeIntervalSince1970: 1_000)
        var progress = LibraryPreparationProgress(phase: .covers, coversCompleted: 10, coversTotal: 30)
        #expect(estimator.estimate(progress, now: start) == nil)
        progress.coversCompleted = 15
        #expect(estimator.estimate(progress, now: start.addingTimeInterval(10)) == start.addingTimeInterval(40))
        progress.phase = .syncing
        #expect(estimator.estimate(progress, now: start.addingTimeInterval(11)) == nil)
        progress.phase = .covers
        #expect(estimator.estimate(progress, now: start.addingTimeInterval(12)) == nil)
        progress.coversCompleted = 30
        #expect(estimator.estimate(progress, now: start.addingTimeInterval(20)) == nil)
    }
}
