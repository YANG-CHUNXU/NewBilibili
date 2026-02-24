import Foundation

public actor RequestScheduler {
    private struct HostState {
        var inFlight: Int = 0
        var lastRequestUptimeNs: UInt64 = 0
    }

    private let maxConcurrentPerHost: Int
    private let minIntervalNs: UInt64
    private var states: [String: HostState] = [:]

    public init(maxConcurrentPerHost: Int = 3, minIntervalMs: UInt64 = 300) {
        self.maxConcurrentPerHost = maxConcurrentPerHost
        self.minIntervalNs = minIntervalMs * 1_000_000
    }

    public func acquire(host: String) async {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            var state = states[host, default: HostState()]
            let elapsed = now &- state.lastRequestUptimeNs

            if state.inFlight < maxConcurrentPerHost && elapsed >= minIntervalNs {
                state.inFlight += 1
                state.lastRequestUptimeNs = now
                states[host] = state
                return
            }

            states[host] = state
            let remainingInterval = elapsed >= minIntervalNs ? 0 : minIntervalNs - elapsed
            let sleepNs = max(remainingInterval, 50_000_000)
            try? await Task.sleep(nanoseconds: sleepNs)
        }
    }

    public func release(host: String) {
        guard var state = states[host] else {
            return
        }
        state.inFlight = max(0, state.inFlight - 1)
        states[host] = state
    }
}
