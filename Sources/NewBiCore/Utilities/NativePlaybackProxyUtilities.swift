import Foundation

public enum NativePlaybackProxyUtilities {
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
        guard let segmentURL = proxyURL(scheme: scheme, sessionID: sessionID, path: segmentPath) else {
            return nil
        }

        return [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:6",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXTINF:6.000,",
            segmentURL.absoluteString,
            "#EXT-X-ENDLIST"
        ].joined(separator: "\n")
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
}
