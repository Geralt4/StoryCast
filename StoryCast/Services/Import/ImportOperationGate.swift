import Foundation

actor ImportOperationGate {
    private var pendingContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var isExecuting = false

    func acquire(requestID: UUID) async throws {
        try await withCheckedThrowingContinuation { continuation in
            pendingContinuations[requestID] = continuation
            if !isExecuting {
                isExecuting = true
                if let next = pendingContinuations.removeValue(forKey: requestID) {
                    next.resume()
                }
            }
        }
    }

    func cancel(requestID: UUID) {
        if let continuation = pendingContinuations.removeValue(forKey: requestID) {
            continuation.resume(throwing: CancellationError())
        }
    }

    func cancelAll() {
        for (_, continuation) in pendingContinuations {
            continuation.resume(throwing: CancellationError())
        }
        pendingContinuations.removeAll()
        isExecuting = false
    }

    func release() {
        if pendingContinuations.isEmpty {
            isExecuting = false
        } else {
            let nextKey = pendingContinuations.keys.first!
            let next = pendingContinuations.removeValue(forKey: nextKey)!
            next.resume()
        }
    }

    var hasPendingRequests: Bool {
        !pendingContinuations.isEmpty || isExecuting
    }
}