import Foundation

actor VideoDurationHydrator {
    static let shared = VideoDurationHydrator()

    private let failureCooldown: TimeInterval
    private var cachedDurationTextByBVID: [String: String] = [:]
    private var failedAtByBVID: [String: Date] = [:]
    private var inFlightByBVID: [String: Task<String?, Never>] = [:]

    init(failureCooldown: TimeInterval = 10 * 60) {
        self.failureCooldown = max(0, failureCooldown)
    }

    func resolveDurationText(
        bvid: String,
        using client: any BiliPublicClient
    ) async -> String? {
        if let cached = cachedDurationTextByBVID[bvid] {
            return cached
        }

        if let failedAt = failedAtByBVID[bvid],
           Date().timeIntervalSince(failedAt) < failureCooldown
        {
            return nil
        }

        if let inFlight = inFlightByBVID[bvid] {
            return await inFlight.value
        }

        let task = Task<String?, Never> {
            do {
                let detail = try await client.fetchVideoDetail(bvid: bvid)
                let totalSeconds = detail.parts.reduce(into: 0) { partial, part in
                    guard let duration = part.durationSeconds, duration > 0 else {
                        return
                    }
                    partial += duration
                }
                guard totalSeconds > 0 else {
                    return nil
                }
                return Self.formatDuration(totalSeconds)
            } catch {
                return nil
            }
        }

        inFlightByBVID[bvid] = task
        let resolved = await task.value
        inFlightByBVID[bvid] = nil

        if let resolved {
            cachedDurationTextByBVID[bvid] = resolved
            failedAtByBVID[bvid] = nil
        } else {
            failedAtByBVID[bvid] = Date()
        }

        return resolved
    }

    nonisolated static func formatDuration(_ totalSeconds: Int) -> String {
        let seconds = max(0, totalSeconds)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }
}
