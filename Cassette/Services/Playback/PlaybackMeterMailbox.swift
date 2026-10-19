import Synchronization

/// Fixed storage shared by render callbacks and the UI consumer. Neither side waits:
/// one atomic claim protects the whole snapshot, and contention drops a visual sample.
nonisolated final class PlaybackMeterMailbox: Sendable {
    private let busy = Atomic<Bool>(false)
    private let first = Atomic<UInt64>(0)
    private let second = Atomic<UInt64>(0)
    private let generation = Atomic<UInt64>(0)
    private let revision = Atomic<UInt64>(0)

    func publish(_ values: SIMD4<Float>, generation token: UInt64) {
        guard busy.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged else { return }
        defer { busy.store(false, ordering: .releasing) }
        first.store(UInt64(values.x.bitPattern) | UInt64(values.y.bitPattern) << 32, ordering: .relaxed)
        second.store(UInt64(values.z.bitPattern) | UInt64(values.w.bitPattern) << 32, ordering: .relaxed)
        generation.store(token, ordering: .relaxed)
        revision.wrappingAdd(1, ordering: .relaxed)
    }

    func latest() -> (bands: SIMD4<Float>, generation: UInt64, revision: UInt64)? {
        // Claim before reading instead of relying on optimistic checks around relaxed
        // loads. The acquire/release pair keeps all lanes and the generation together.
        guard busy.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged else { return nil }
        defer { busy.store(false, ordering: .releasing) }
        let currentRevision = revision.load(ordering: .relaxed)
        guard currentRevision != 0 else { return nil }
        let a = first.load(ordering: .relaxed), b = second.load(ordering: .relaxed)
        let token = generation.load(ordering: .relaxed)
        return (SIMD4(Float(bitPattern: UInt32(truncatingIfNeeded: a)), Float(bitPattern: UInt32(truncatingIfNeeded: a >> 32)),
                      Float(bitPattern: UInt32(truncatingIfNeeded: b)), Float(bitPattern: UInt32(truncatingIfNeeded: b >> 32))), token, currentRevision)
    }
}
