import Foundation

final class ReconnectPolicy: @unchecked Sendable {
    private let delays: [TimeInterval] = [5, 15, 30, 60]
    private var attemptIndex = 0

    var nextDelay: TimeInterval {
        let delay = delays[min(attemptIndex, delays.count - 1)]
        attemptIndex = min(attemptIndex + 1, delays.count - 1)
        return delay
    }

    func reset() {
        attemptIndex = 0
    }
}
