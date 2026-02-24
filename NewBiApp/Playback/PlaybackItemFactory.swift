import Foundation
import AVFoundation
import NewBiCore

protocol PlaybackItemFactoryProtocol {
    func makePlayerItem(from stream: PlayableStream) async throws -> AVPlayerItem
    func releaseResources(for item: AVPlayerItem?)
}

final class PlaybackItemFactory: PlaybackItemFactoryProtocol {
    private let resourceLoader: NativePlaybackResourceLoader

    init(resourceLoader: NativePlaybackResourceLoader = .shared) {
        self.resourceLoader = resourceLoader
    }

    func makePlayerItem(from stream: PlayableStream) async throws -> AVPlayerItem {
        let asset = try await resourceLoader.makeAsset(for: stream)
        return AVPlayerItem(asset: asset)
    }

    func releaseResources(for item: AVPlayerItem?) {
        resourceLoader.release(asset: item?.asset)
    }
}
