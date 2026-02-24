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
        case .progressive(let url):
            let asset = AVURLAsset(url: url, options: httpAssetOptions(headers: stream.headers))
            return AVPlayerItem(asset: asset)
        case .dash(let videoURL, let audioURL):
            guard let audioURL else {
                let videoAsset = AVURLAsset(url: videoURL, options: httpAssetOptions(headers: stream.headers))
                return AVPlayerItem(asset: videoAsset)
            }
            do {
                return try await makeDashComposedItem(
                    videoURL: videoURL,
                    audioURL: audioURL,
                    headers: stream.headers
                )
            } catch {
                let videoAsset = AVURLAsset(url: videoURL, options: httpAssetOptions(headers: stream.headers))
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

    private func makeDashComposedItem(
        videoURL: URL,
        audioURL: URL,
        headers: PlaybackHeaders
    ) async throws -> AVPlayerItem {
        let options = httpAssetOptions(headers: headers)
        let videoAsset = AVURLAsset(url: videoURL, options: options)
        let audioAsset = AVURLAsset(url: audioURL, options: options)

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

        let videoDuration = try await videoAsset.load(.duration)
        let videoRange = CMTimeRange(start: .zero, duration: videoDuration)
        try composedVideoTrack.insertTimeRange(videoRange, of: sourceVideoTrack, at: .zero)
        composedVideoTrack.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)

        if let sourceAudioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let composedAudioTrack = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let audioDuration = try await audioAsset.load(.duration)
            let insertDuration = minDuration(videoDuration, audioDuration)
            let audioRange = CMTimeRange(start: .zero, duration: insertDuration)
            try composedAudioTrack.insertTimeRange(audioRange, of: sourceAudioTrack, at: .zero)
        }

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
}
