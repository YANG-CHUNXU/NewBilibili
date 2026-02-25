import Foundation

public enum NativePlaybackProxyUtilities {
    public struct MediaPlaylistSegment: Hashable, Sendable {
        public let segmentPath: String
        public let durationSeconds: Double?

        public init(segmentPath: String, durationSeconds: Double? = nil) {
            self.segmentPath = segmentPath
            self.durationSeconds = durationSeconds
        }
    }

    @_spi(PlaybackProxy)
    public enum RangeProbeResult: Equatable {
        case supports206
        case fallback200
        case failed
    }

    @_spi(PlaybackProxy)
    public struct RangeCandidateSelection: Equatable {
        public let url: URL
        public let shouldMarkPreferredCandidate: Bool

        public init(url: URL, shouldMarkPreferredCandidate: Bool) {
            self.url = url
            self.shouldMarkPreferredCandidate = shouldMarkPreferredCandidate
        }
    }

    public static func proxyURL(scheme: String, sessionID: UUID, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = sessionID.uuidString.lowercased()
        components.path = path
        return components.url
    }

    public static func makeMasterPlaylist(scheme: String, sessionID: UUID, hasAudio: Bool) -> String? {
        guard let videoPlaylistURL = proxyURL(scheme: scheme, sessionID: sessionID, path: "/video.m3u8") else {
            return nil
        }

        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-INDEPENDENT-SEGMENTS"
        ]

        if hasAudio {
            guard let audioPlaylistURL = proxyURL(scheme: scheme, sessionID: sessionID, path: "/audio.m3u8") else {
                return nil
            }
            lines.append(#"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="main",DEFAULT=YES,AUTOSELECT=YES,URI="\#(audioPlaylistURL.absoluteString)""#)
            lines.append(#"#EXT-X-STREAM-INF:BANDWIDTH=2500000,CODECS="avc1.640028,mp4a.40.2",AUDIO="audio""#)
        } else {
            lines.append(#"#EXT-X-STREAM-INF:BANDWIDTH=2500000,CODECS="avc1.640028""#)
        }

        lines.append(videoPlaylistURL.absoluteString)
        return lines.joined(separator: "\n")
    }

    public static func makeMediaPlaylist(scheme: String, sessionID: UUID, segmentPath: String) -> String? {
        makeMediaPlaylist(
            scheme: scheme,
            sessionID: sessionID,
            segments: [
                MediaPlaylistSegment(
                    segmentPath: segmentPath,
                    durationSeconds: 86_400
                )
            ]
        )
    }

    public static func makeMediaPlaylist(
        scheme: String,
        sessionID: UUID,
        segments: [MediaPlaylistSegment]
    ) -> String? {
        guard !segments.isEmpty else {
            return nil
        }

        var playlistSegments: [(url: URL, durationSeconds: Double)] = []
        for segment in segments {
            guard let segmentURL = proxyURL(scheme: scheme, sessionID: sessionID, path: segment.segmentPath) else {
                return nil
            }
            playlistSegments.append((segmentURL, normalizedSegmentDuration(segment.durationSeconds)))
        }

        let targetDuration = max(
            Int(ceil(playlistSegments.map(\.durationSeconds).max() ?? 1)),
            1
        )

        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-PLAYLIST-TYPE:VOD"
        ]

        for segment in playlistSegments {
            lines.append(String(format: "#EXTINF:%.3f,", segment.durationSeconds))
            lines.append(segment.url.absoluteString)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n")
    }

    public static func makeRangeHeader(
        requestedOffset: Int64,
        currentOffset: Int64,
        requestedLength: Int
    ) -> String? {
        let start = currentOffset > 0 ? currentOffset : requestedOffset
        if start == 0, requestedLength <= 0 {
            return nil
        }
        if requestedLength > 0 {
            let end = start + Int64(requestedLength) - 1
            return "bytes=\(start)-\(end)"
        }
        return "bytes=\(start)-"
    }

    public static func buildForwardHeaders(base: PlaybackHeaders, range: String?) -> [String: String] {
        var headers = [
            "Referer": base.referer,
            "Origin": base.origin,
            "User-Agent": base.userAgent
        ]
        if let range, !range.isEmpty {
            headers["Range"] = range
        }
        return headers
    }

    public static func deduplicatedCandidateURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var output: [URL] = []
        output.reserveCapacity(urls.count)

        for url in urls {
            let key = url.absoluteString
            guard seen.insert(key).inserted else {
                continue
            }
            output.append(url)
        }

        return output
    }

    public static func prioritizedCandidateURLs(_ urls: [URL], preferred: URL?) -> [URL] {
        var ordered = deduplicatedCandidateURLs(urls)
        guard let preferred else {
            return ordered
        }

        let preferredKey = preferred.absoluteString
        guard let preferredIndex = ordered.firstIndex(where: { $0.absoluteString == preferredKey }) else {
            return ordered
        }
        guard preferredIndex != ordered.startIndex else {
            return ordered
        }

        let preferredURL = ordered.remove(at: preferredIndex)
        ordered.insert(preferredURL, at: 0)
        return ordered
    }

    @_spi(PlaybackProxy)
    public static func selectRangeCandidate(
        orderedCandidates: [URL],
        probeResults: [URL: RangeProbeResult]
    ) -> RangeCandidateSelection? {
        var first200Fallback: URL?

        for candidate in orderedCandidates {
            switch probeResults[candidate] ?? .failed {
            case .supports206:
                return RangeCandidateSelection(url: candidate, shouldMarkPreferredCandidate: true)
            case .fallback200:
                if first200Fallback == nil {
                    first200Fallback = candidate
                }
            case .failed:
                continue
            }
        }

        if let first200Fallback {
            return RangeCandidateSelection(url: first200Fallback, shouldMarkPreferredCandidate: false)
        }

        return nil
    }

    private static func normalizedSegmentDuration(_ durationSeconds: Double?) -> Double {
        guard let durationSeconds,
              durationSeconds.isFinite,
              durationSeconds > 0
        else {
            return 10
        }
        return durationSeconds
    }
}
