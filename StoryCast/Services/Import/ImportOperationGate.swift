import Foundation

actor ImportOperationGate {
    /// Ordered (FIFO) queue of pending import requests. `OrderedDictionary` is
    /// not available in Foundation, so we keep two parallel collections and
    /// enforce ordering by only mutating both under actor isolation.
    private var pendingContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var pendingOrder: [UUID] = []
    private var isExecuting = false

    func acquire(requestID: UUID) async throws {
        try await withCheckedThrowingContinuation { continuation in
            // If we're the active execution, hand the continuation out
            // immediately without recording it in either dictionary —
            // otherwise the entry would leak into pendingOrder and
            // drainNext() would later pop a stale requestID and confuse
            // the release path.
            if !isExecuting {
                isExecuting = true
                continuation.resume()
                return
            }
            pendingContinuations[requestID] = continuation
            pendingOrder.append(requestID)
        }
    }

    func cancel(requestID: UUID) {
        if let continuation = pendingContinuations.removeValue(forKey: requestID) {
            pendingOrder.removeAll { $0 == requestID }
            continuation.resume(throwing: CancellationError())
        }
    }

    func cancelAll() {
        for (_, continuation) in pendingContinuations {
            continuation.resume(throwing: CancellationError())
        }
        pendingContinuations.removeAll()
        pendingOrder.removeAll()
        // Do NOT reset isExecuting here — the currently executing operation
        // will call release() when it finishes, which resets isExecuting.
        // Resetting here would allow a new acquire() to proceed while the
        // cancelled-but-still-running operation is still using the gate.
    }

    func release() {
        if let next = drainNext() {
            next.resume()
        } else {
            isExecuting = false
        }
    }

    var hasPendingRequests: Bool {
        !pendingContinuations.isEmpty || isExecuting
    }

    /// Removes and returns the next pending continuation in FIFO order.
    /// Returns nil if the queue is empty.
    private func drainNext() -> CheckedContinuation<Void, Error>? {
        guard let firstID = pendingOrder.first else { return nil }
        pendingOrder.removeFirst()
        return pendingContinuations.removeValue(forKey: firstID)
    }
}
