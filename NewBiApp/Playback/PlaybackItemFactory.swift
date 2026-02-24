import Foundation
import AVFoundation
import NewBiCore

protocol PlaybackItemFactoryProtocol {
    func makePlayerItem(from stream: PlayableStream) async throws -> AVPlayerItem
    func releaseResources(for item: AVPlayerItem?)
}

final class PlaybackItemFactory: PlaybackItemFactoryProtocol {
    init() {}

    func makePlayerItem(from stream: PlayableStream) async throws -> AVPlayerItem {
        switch stream.transport {
        case .progressive(let url, let fallbackURLs):
            let videoAsset = try await resolveVideoAsset(
                candidates: [url] + fallbackURLs,
                headers: stream.headers
            )
            return AVPlayerItem(asset: videoAsset)
        case .dash(let videoURL, let audioURL, let videoFallbackURLs, let audioFallbackURLs):
            let videoAsset = try await resolveVideoAsset(
                candidates: [videoURL] + videoFallbackURLs,
                headers: stream.headers
            )

            // Some "dash video" resources already contain audio; composing another audio track causes echo.
            let embeddedAudioTracks = try await videoAsset.loadTracks(withMediaType: .audio)
            if !embeddedAudioTracks.isEmpty {
                return AVPlayerItem(asset: videoAsset)
            }

            guard let audioURL else {
                return AVPlayerItem(asset: videoAsset)
            }

            let audioCandidates = [audioURL] + audioFallbackURLs
            let audioAsset: AVURLAsset
            do {
                audioAsset = try await resolveAudioAsset(candidates: audioCandidates, headers: stream.headers)
            } catch {
                return AVPlayerItem(asset: videoAsset)
            }

            do {
                return try await makeDashComposedItem(
                    videoAsset: videoAsset,
                    audioAsset: audioAsset
                )
            } catch {
                // Fallback to video-only to avoid hard "cannot open" failures on problematic audio streams.
                return AVPlayerItem(asset: videoAsset)
            }
        }
    }

    func releaseResources(for item: AVPlayerItem?) {
        // Direct asset/composition playback has no proxy session to release.
        _ = item
    }

    private func httpAssetOptions(headers: PlaybackHeaders) -> [String: Any] {
        let headerFields: [String: String] = [
            "Referer": headers.referer,
            "Origin": headers.origin,
            "User-Agent": headers.userAgent
        ]
        return [
            "AVURLAssetHTTPHeaderFieldsKey": headerFields,
            "AVURLAssetHTTPUserAgentKey": headers.userAgent
        ]
    }

    private func resolveVideoAsset(candidates: [URL], headers: PlaybackHeaders) async throws -> AVURLAsset {
        var lastError: Error?
        for candidate in deduplicatedURLs(candidates) {
            let asset = AVURLAsset(url: candidate, options: httpAssetOptions(headers: headers))
            do {
                let playable = try await asset.load(.isPlayable)
                guard playable else {
                    throw BiliClientError.unsupportedDashStream("视频流不可播放: \(candidate.absoluteString)")
                }
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                if !videoTracks.isEmpty {
                    return asset
                }
            } catch {
                lastError = error
            }
        }

        throw lastError ?? BiliClientError.noPlayableStream
    }

    private func resolveAudioAsset(candidates: [URL], headers: PlaybackHeaders) async throws -> AVURLAsset {
        var lastError: Error?
        for candidate in deduplicatedURLs(candidates) {
            let asset = AVURLAsset(url: candidate, options: httpAssetOptions(headers: headers))
            do {
                let playable = try await asset.load(.isPlayable)
                guard playable else {
                    throw BiliClientError.unsupportedDashStream("音频流不可播放: \(candidate.absoluteString)")
                }
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                if !audioTracks.isEmpty {
                    return asset
                }
            } catch {
                lastError = error
            }
        }

        throw lastError ?? BiliClientError.unsupportedDashStream("可用音频流探测失败")
    }

    private func deduplicatedURLs(_ input: [URL]) -> [URL] {
        var seen = Set<String>()
        var output: [URL] = []
        for url in input {
            let key = url.absoluteString
            guard seen.insert(key).inserted else {
                continue
            }
            output.append(url)
        }
        return output
    }

    private func makeDashComposedItem(videoAsset: AVURLAsset, audioAsset: AVURLAsset) async throws -> AVPlayerItem {
        let composition = AVMutableComposition()

        guard let sourceVideoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw BiliClientError.unsupportedDashStream("DASH 视频轨不可用")
        }
        guard let composedVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw BiliClientError.playbackProxyFailed("创建合成视频轨失败")
        }

        guard let sourceAudioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw BiliClientError.unsupportedDashStream("DASH 音频轨不可用")
        }
        guard let composedAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw BiliClientError.playbackProxyFailed("创建合成音频轨失败")
        }

        let videoDuration = try await normalizedDuration(for: videoAsset, track: sourceVideoTrack)
        let audioDuration = try await normalizedDuration(for: audioAsset, track: sourceAudioTrack)
        let insertDuration = minDuration(videoDuration, audioDuration)

        let videoRange = try await normalizedSourceRange(for: sourceVideoTrack, targetDuration: insertDuration)
        let audioRange = try await normalizedSourceRange(for: sourceAudioTrack, targetDuration: insertDuration)

        let timelineStart = minTime(videoRange.start, audioRange.start)
        let videoInsertAt = CMTimeSubtract(videoRange.start, timelineStart)
        let audioInsertAt = CMTimeSubtract(audioRange.start, timelineStart)

        try composedVideoTrack.insertTimeRange(videoRange, of: sourceVideoTrack, at: videoInsertAt)
        composedVideoTrack.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
        try composedAudioTrack.insertTimeRange(audioRange, of: sourceAudioTrack, at: audioInsertAt)

        return AVPlayerItem(asset: composition)
    }

    private func minDuration(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
        if !lhs.isValid || lhs.isIndefinite {
            return rhs
        }
        if !rhs.isValid || rhs.isIndefinite {
            return lhs
        }
        return CMTimeCompare(lhs, rhs) <= 0 ? lhs : rhs
    }

    private func minTime(_ lhs: CMTime, _ rhs: CMTime) -> CMTime {
        if !isUsableTime(lhs) {
            return rhs
        }
        if !isUsableTime(rhs) {
            return lhs
        }
        return CMTimeCompare(lhs, rhs) <= 0 ? lhs : rhs
    }

    private func normalizedDuration(for asset: AVAsset, track: AVAssetTrack) async throws -> CMTime {
        let assetDuration = try await asset.load(.duration)
        if assetDuration.isValid, !assetDuration.isIndefinite, !assetDuration.isNegativeInfinity, !assetDuration.isPositiveInfinity {
            return assetDuration
        }

        let trackTimeRange = try await track.load(.timeRange)
        let trackDuration = trackTimeRange.duration
        if trackDuration.isValid, !trackDuration.isIndefinite, !trackDuration.isNegativeInfinity, !trackDuration.isPositiveInfinity {
            return trackDuration
        }

        throw BiliClientError.unsupportedDashStream("DASH 轨道时长不可用")
    }

    private func normalizedSourceRange(
        for track: AVAssetTrack,
        targetDuration: CMTime
    ) async throws -> CMTimeRange {
        let timeRange = try await track.load(.timeRange)
        let start = isUsableTime(timeRange.start) ? timeRange.start : .zero
        let trackDuration = isUsableTime(timeRange.duration) && CMTimeCompare(timeRange.duration, .zero) > 0
            ? timeRange.duration
            : targetDuration
        let duration = minDuration(trackDuration, targetDuration)
        guard isUsableTime(duration), CMTimeCompare(duration, .zero) > 0 else {
            throw BiliClientError.unsupportedDashStream("DASH 轨道时间范围无效")
        }
        return CMTimeRange(start: start, duration: duration)
    }

    private func isUsableTime(_ time: CMTime) -> Bool {
        time.isValid && !time.isIndefinite && !time.isNegativeInfinity && !time.isPositiveInfinity
    }
}
