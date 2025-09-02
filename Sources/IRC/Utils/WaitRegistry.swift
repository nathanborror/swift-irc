import Foundation

public actor WaitRegistry {
    struct Waiter {
        let id: UUID
        let pred: @Sendable (Message) -> Bool
        let cont: CheckedContinuation<Message, Error>
        var timeoutTask: Task<Void, Never>?
    }

    private var pending: [UUID: Waiter] = [:]
    private let pendingLimit = 512
    private var recent: [Message] = []
    private let recentLimit = 32

    func deliver(_ m: Message) {
        // ring buffer
        recent.append(m)
        if recent.count > recentLimit { recent.removeFirst() }

        // fulfill first matching waiter
        if let (id, w) = pending.first(where: { $0.value.pred(m) }) {
            pending.removeValue(forKey: id)
            w.timeoutTask?.cancel()
            w.cont.resume(returning: m)
        }
    }

    @discardableResult
    func sendAndWait(performSend: @escaping @Sendable () async throws -> Void, expecting pred: @escaping @Sendable (Message) -> Bool, timeout: Duration) async throws -> Message {
        if pending.count >= pendingLimit {
            throw IRCSessionError.registryLimitReached
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Message, Error>) in

                // Early-arrival check
                if let hit = recent.first(where: pred) {
                    cont.resume(returning: hit)
                    return
                }

                // Register waiter
                var w = Waiter(id: id, pred: pred, cont: cont, timeoutTask: nil)
                w.timeoutTask = Task { [weak self] in
                    do {
                        try await ContinuousClock().sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.timeout(id: id)
                }
                pending[id] = w

                // Do the send, and clean up if it fails
                Task {
                    do {
                        try await performSend()
                    } catch {
                        fail(id: id, error: error)
                    }
                }
            }
        } onCancel: {
            Task { await fail(id: id, error: IRCSessionError.cancelled) }
        }
    }

    private func timeout(id: UUID) {
        if let w = pending.removeValue(forKey: id) {
            w.cont.resume(throwing: IRCSessionError.timeout)
        }
    }
    private func fail(id: UUID, error: Error) {
        if let w = pending.removeValue(forKey: id) {
            w.timeoutTask?.cancel()
            w.cont.resume(throwing: error)
        }
    }

    func cancelAll(_ error: Error) {
        let ps = pending.values
        pending.removeAll()
        for w in ps {
            w.timeoutTask?.cancel()
            w.cont.resume(throwing: error)
        }
    }
}
