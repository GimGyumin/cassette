import Foundation

/// A cancelled waiter never receives a permit. Producers shared by multiple views retain
/// their task; cancelling one view does not cancel the other views' shared decode.
actor CoverDecodeGate {
    private let limit: Int
    private var available: Int
    private var order: [UUID] = []
    private var head = 0
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    var waitingCount: Int { waiters.count }

    init(limit: Int) { precondition(limit > 0); self.limit = limit; available = limit }

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if available > 0 { available -= 1; return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                order.append(id)
                waiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: false)
        if waiters.isEmpty { order.removeAll(keepingCapacity: true); head = 0 }
    }

    func release() {
        while head < order.count {
            let id = order[head]
            head += 1
            guard let waiter = waiters.removeValue(forKey: id) else { continue }
            waiter.resume(returning: true)
            if head >= 64, head * 2 >= order.count { order.removeFirst(head); head = 0 }
            return
        }
        order.removeAll(keepingCapacity: true)
        head = 0
        precondition(available < limit, "A permit must be released exactly once")
        available += 1
    }
}
