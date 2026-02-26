import Foundation

public struct BiliPublicHTMLParser: Sendable {
    public init() {}

    public func parseSubscriptionVideos(from html: String) throws -> [VideoCard] {
        let root = try parseStateContainer(from: html)
        return mapVideoCards(from: root)
    }

    public func parseSearchVideos(from html: String) throws -> [VideoCard] {
        let root = try parseStateContainer(from: html)
        return mapVideoCards(from: root)
    }

    public func parseVideoDetail(from html: String) throws -> VideoDetail {
        let root = try parseStateContainer(from: html)

        let videoData = JSONHelpers.dict((root as? [String: Any])?["videoData"]) ??
            JSONHelpers.findFirstDict(in: root) { dict in
                dict["bvid"] != nil && dict["title"] != nil && dict["pages"] != nil
            }

        guard let videoData else {
            throw BiliClientError.parseFailed("未找到视频详情数据")
        }

        guard let bvid = JSONHelpers.string(videoData["bvid"]), !bvid.isEmpty,
              let title = JSONHelpers.string(videoData["title"]), !title.isEmpty
        else {
            throw BiliClientError.parseFailed("视频详情缺少必要字段")
        }

        let description = htmlEntityDecode(JSONHelpers.string(videoData["desc"]))
        let owner = JSONHelpers.dict(videoData["owner"])
        let upData = JSONHelpers.dict((root as? [String: Any])?["upData"])
        let authorName = JSONHelpers.string(owner?["name"]) ??
            JSONHelpers.string(upData?["name"]) ??
            "未知UP主"

        let parts: [VideoPart] = (JSONHelpers.array(videoData["pages"]) ?? []).compactMap { raw in
            guard let partDict = JSONHelpers.dict(raw),
                  let cid = JSONHelpers.int(partDict["cid"]),
                  let page = JSONHelpers.int(partDict["page"])
            else {
                return nil
            }

            let name = htmlEntityDecode(JSONHelpers.string(partDict["part"])) ?? "P\(page)"
            return VideoPart(
                cid: cid,
                page: page,
                title: name,
                durationSeconds: JSONHelpers.int(partDict["duration"])
            )
        }

        let stat = JSONHelpers.dict(videoData["stat"])
        let stats = stat.map {
            VideoStats(
                view: JSONHelpers.int($0["view"]),
                danmaku: JSONHelpers.int($0["danmaku"]),
                reply: JSONHelpers.int($0["reply"]),
                favorite: JSONHelpers.int($0["favorite"]),
                coin: JSONHelpers.int($0["coin"]),
                share: JSONHelpers.int($0["share"]),
                like: JSONHelpers.int($0["like"])
            )
        }

        return VideoDetail(
            bvid: bvid,
            title: htmlEntityDecode(title) ?? title,
            description: description,
            authorName: authorName,
            parts: parts,
            stats: stats
        )
    }

    public func parsePlayableStream(from html: String) throws -> PlayableStream {
        guard let object = ScriptJSONExtractor.extractJSONObject(after: "window.__playinfo__=", in: html) else {
            throw BiliClientError.parseFailed("未找到 __playinfo__")
        }

        let decoded = try ScriptJSONExtractor.decodeJSONObject(from: object)
        return try parsePlayableStream(fromPlayInfoJSON: decoded)
    }

    public func parsePlayableStream(fromPlayInfoJSON rootObject: Any) throws -> PlayableStream {
        let root = JSONHelpers.dict(rootObject) ?? [:]
        if let code = JSONHelpers.int(root["code"]), code != 0 {
            let message = JSONHelpers.string(root["message"]) ?? JSONHelpers.string(root["msg"]) ?? "未知错误"
            throw BiliClientError.networkFailed("播放接口异常(code=\(code))：\(message)")
        }

        let data = JSONHelpers.dict(root["data"]) ?? root
        let progressive = parseProgressiveStream(data: data)

        do {
            if let dash = try parseDashStream(data: data) {
                return dash
            }
        } catch {
            if progressive == nil {
                throw error
            }
        }

        if let progressive {
            return progressive
        }

        throw BiliClientError.noPlayableStream
    }

    private func parseStateContainer(from html: String) throws -> Any {
        var fallbackRoot: Any?
        var decodeError: Error?

        let markers = [
            "window.__INITIAL_STATE__",
            "window.__initialState__",
            "__INITIAL_STATE__",
            "window.__pinia",
            "window.__PINIA__",
            "window.__NUXT__",
            "window.__APP_DATA__",
            "window.__SSR_DATA__",
            "window.__PRELOADED_STATE__"
        ]

        for marker in markers {
            if let value = ScriptJSONExtractor.extractJSONValue(after: marker, in: html) {
                do {
                    let decoded = try ScriptJSONExtractor.decodeJSONObject(from: value)
                    if isLikelyStateContainer(decoded) {
                        return decoded
                    }
                    if fallbackRoot == nil {
                        fallbackRoot = decoded
                    }
                } catch {
                    decodeError = error
                }
            }
        }

        let scriptIDs = ["__NEXT_DATA__", "__NUXT_DATA__"]
        for scriptID in scriptIDs {
            if let script = ScriptJSONExtractor.extractScriptTagContent(id: scriptID, in: html) {
                do {
                    let decoded = try ScriptJSONExtractor.decodeJSONObject(from: script)
                    if isLikelyStateContainer(decoded) {
                        return decoded
                    }
                    if fallbackRoot == nil {
                        fallbackRoot = decoded
                    }
                } catch {
                    decodeError = error
                }
            }
        }

        for value in ScriptJSONExtractor.extractWindowAssignmentJSONValues(in: html) {
            do {
                let decoded = try ScriptJSONExtractor.decodeJSONObject(from: value)
                if isLikelyStateContainer(decoded) {
                    return decoded
                }
                if fallbackRoot == nil {
                    fallbackRoot = decoded
                }
            } catch {
                decodeError = error
            }
        }

        if let fallbackRoot {
            return fallbackRoot
        }
        if let decodeError = decodeError as? BiliClientError {
            throw decodeError
        }
        throw BiliClientError.parseFailed("未找到可解析的页面状态")
    }

    private func isLikelyStateContainer(_ root: Any) -> Bool {
        if let dict = JSONHelpers.dict(root) {
            let likelyKeys: Set<String> = [
                "videoData", "arcList", "allData", "result", "props", "pinia", "state", "store"
            ]
            if !likelyKeys.isDisjoint(with: Set(dict.keys)) {
                return true
            }
        }

        return JSONHelpers.findFirstDict(in: root) { dict in
            let hasBVID = JSONHelpers.string(dict["bvid"]) != nil
            let hasTitle = JSONHelpers.string(dict["title"]) != nil
            let hasPages = JSONHelpers.array(dict["pages"]) != nil
            return (hasBVID && hasTitle) || (hasBVID && hasPages)
        } != nil
    }

    private func mapVideoCards(from root: Any) -> [VideoCard] {
        var seen = Set<String>()
        var mapped: [VideoCard] = []

        for card in mapDynamicModuleCards(from: root) {
            guard seen.insert(card.bvid).inserted else {
                continue
            }
            mapped.append(card)
        }

        var candidateDicts: [[String: Any]] = []
        JSONHelpers.collectDicts(in: root, where: { dict in
            JSONHelpers.string(dict["bvid"]) != nil && JSONHelpers.string(dict["title"]) != nil
        }, output: &candidateDicts)

        for dict in candidateDicts {
            guard let bvid = JSONHelpers.string(dict["bvid"]), !bvid.isEmpty else {
                continue
            }
            guard seen.insert(bvid).inserted else {
                continue
            }

            let title = htmlEntityDecode(JSONHelpers.string(dict["title"])) ?? ""
            let author = resolveAuthorInfo(from: dict)
            let coverURL = normalizeImageURL(
                JSONHelpers.string(dict["pic"]) ??
                JSONHelpers.string(dict["cover"]) ??
                JSONHelpers.string(dict["arcurl_cover"]) ??
                JSONHelpers.string(dict["cover_url"])
            )

            let publishTime =
                JSONHelpers.dateFromTimestamp(dict["created"]) ??
                JSONHelpers.dateFromTimestamp(dict["pubdate"]) ??
                JSONHelpers.dateFromTimestamp(dict["ctime"]) ??
                JSONHelpers.dateFromTimestamp(dict["timestamp"]) ??
                JSONHelpers.dateFromTimestamp(dict["pub_ts"])

            let durationText =
                JSONHelpers.string(dict["length"]) ??
                formatDuration(
                    JSONHelpers.int(dict["duration"]) ??
                    JSONHelpers.int(dict["duration_seconds"])
                )

            mapped.append(
                VideoCard(
                    id: bvid,
                    bvid: bvid,
                    title: title,
                    coverURL: coverURL,
                    authorName: author.name,
                    authorUID: author.uid,
                    durationText: durationText,
                    publishTime: publishTime
                )
            )
        }

        return mapped
    }

    private func mapDynamicModuleCards(from root: Any) -> [VideoCard] {
        var candidateItems: [[String: Any]] = []
        JSONHelpers.collectDicts(in: root, where: { dict in
            JSONHelpers.dict(dict["modules"]) != nil
        }, output: &candidateItems)

        var seen = Set<String>()
        var mapped: [VideoCard] = []

        for item in candidateItems {
            guard let modules = JSONHelpers.dict(item["modules"]),
                  let moduleDynamic = JSONHelpers.dict(modules["module_dynamic"]),
                  let major = JSONHelpers.dict(moduleDynamic["major"]),
                  let archive = JSONHelpers.dict(major["archive"]),
                  let bvid = JSONHelpers.string(archive["bvid"]), !bvid.isEmpty,
                  let rawTitle = JSONHelpers.string(archive["title"]), !rawTitle.isEmpty
            else {
                continue
            }
            guard seen.insert(bvid).inserted else {
                continue
            }

            var authorSource = archive
            if let moduleAuthor = JSONHelpers.dict(modules["module_author"]) {
                authorSource["module_author"] = moduleAuthor
            }
            let author = resolveAuthorInfo(from: authorSource)

            let coverURL = normalizeImageURL(
                JSONHelpers.string(archive["cover"]) ??
                JSONHelpers.string(archive["pic"]) ??
                JSONHelpers.string(archive["cover_url"])
            )
            let publishTime =
                JSONHelpers.dateFromTimestamp(JSONHelpers.dict(modules["module_author"])?["pub_ts"]) ??
                JSONHelpers.dateFromTimestamp(archive["pubdate"]) ??
                JSONHelpers.dateFromTimestamp(archive["ctime"]) ??
                JSONHelpers.dateFromTimestamp(archive["created"]) ??
                JSONHelpers.dateFromTimestamp(archive["timestamp"])
            let durationText =
                JSONHelpers.string(archive["length"]) ??
                formatDuration(
                    JSONHelpers.int(archive["duration"]) ??
                    JSONHelpers.int(archive["duration_seconds"])
                )

            mapped.append(
                VideoCard(
                    id: bvid,
                    bvid: bvid,
                    title: htmlEntityDecode(rawTitle) ?? rawTitle,
                    coverURL: coverURL,
                    authorName: author.name,
                    authorUID: author.uid,
                    durationText: durationText,
                    publishTime: publishTime
                )
            )
        }

        return mapped
    }

    private func resolveAuthorInfo(from dict: [String: Any]) -> (name: String, uid: String?) {
        let owner = JSONHelpers.dict(dict["owner"])
        let moduleAuthor = JSONHelpers.dict(dict["module_author"])
        let name = htmlEntityDecode(
            JSONHelpers.string(dict["author"]) ??
            JSONHelpers.string(dict["author_name"]) ??
            JSONHelpers.string(dict["name"]) ??
            JSONHelpers.string(dict["uname"]) ??
            JSONHelpers.string(owner?["name"]) ??
            JSONHelpers.string(owner?["uname"]) ??
            JSONHelpers.string(moduleAuthor?["name"])
        ) ?? "未知UP主"
        let uid =
            JSONHelpers.string(dict["mid"]) ??
            JSONHelpers.string(dict["uid"]) ??
            JSONHelpers.string(dict["author_mid"]) ??
            JSONHelpers.string(owner?["mid"]) ??
            JSONHelpers.string(owner?["uid"]) ??
            JSONHelpers.string(moduleAuthor?["mid"])
        return (name, uid)
    }

    private func normalizeImageURL(_ text: String?) -> URL? {
        normalizeNetworkURL(text)
    }

    private func formatDuration(_ seconds: Int?) -> String? {
        guard let seconds, seconds > 0 else {
            return nil
        }

        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%02d:%02d", minutes, remainder)
    }

    private func parseProgressiveStream(data: [String: Any]) -> PlayableStream? {
        let durl = JSONHelpers.array(data["durl"]) ?? []
        guard !durl.isEmpty else {
            return nil
        }
        let qualityID = JSONHelpers.int(data["quality"])
        let qualityLabel = resolveQualityLabel(data: data, fallbackQuality: qualityID)
        if durl.count == 1 {
            guard let first = durl.first,
                  let firstDict = JSONHelpers.dict(first)
            else {
                return nil
            }
            let candidates = urlCandidates(from: firstDict)
            guard let url = candidates.first else {
                return nil
            }

            let format = JSONHelpers.string(data["format"]) ?? inferFormat(from: url)
            return PlayableStream(
                transport: .progressive(url: url, fallbackURLs: Array(candidates.dropFirst())),
                headers: .bilibiliDefault,
                qualityID: qualityID,
                qualityLabel: qualityLabel,
                format: format
            )
        }

        let segments = durl.compactMap { raw -> ProgressivePlaylistSegment? in
            guard let dict = JSONHelpers.dict(raw) else {
                return nil
            }
            let candidates = urlCandidates(from: dict)
            guard let url = candidates.first else {
                return nil
            }

            return ProgressivePlaylistSegment(
                url: url,
                fallbackURLs: Array(candidates.dropFirst()),
                durationSeconds: durlDurationSeconds(from: dict["length"])
            )
        }

        guard segments.count == durl.count,
              let firstURL = segments.first?.url
        else {
            return nil
        }

        let format = JSONHelpers.string(data["format"]) ?? inferFormat(from: firstURL)
        return PlayableStream(
            transport: .progressivePlaylist(segments: segments),
            headers: .bilibiliDefault,
            qualityID: qualityID,
            qualityLabel: qualityLabel,
            format: format
        )
    }

    private func parseDashStream(data: [String: Any]) throws -> PlayableStream? {
        guard let dash = JSONHelpers.dict(data["dash"]) else {
            return nil
        }

        let rawVideos = JSONHelpers.array(dash["video"]) ?? []
        let videoTracks = rawVideos.compactMap { raw -> DashVideoTrack? in
            guard let dict = JSONHelpers.dict(raw),
                  let id = JSONHelpers.int(dict["id"])
            else {
                return nil
            }
            let candidates = urlCandidates(from: dict)
            guard let firstURL = candidates.first else {
                return nil
            }

            return DashVideoTrack(
                id: id,
                url: firstURL,
                fallbackURLs: Array(candidates.dropFirst()),
                codecs: JSONHelpers.string(dict["codecs"]),
                codecid: JSONHelpers.int(dict["codecid"]),
                bandwidth: JSONHelpers.int(dict["bandwidth"])
            )
        }

        guard !videoTracks.isEmpty else {
            throw BiliClientError.unsupportedDashStream("缺少可用视频轨")
        }

        let preferredQuality = JSONHelpers.int(data["quality"])
        let selectedVideo = selectBestVideoTrack(videoTracks, preferredQuality: preferredQuality)

        var audioTracks = parseDashAudioTracks(from: JSONHelpers.array(dash["audio"]) ?? [])
        if let flac = JSONHelpers.dict(dash["flac"]),
           let flacAudio = JSONHelpers.dict(flac["audio"])
        {
            audioTracks += parseDashAudioTracks(from: [flacAudio])
        }
        if let dolby = JSONHelpers.dict(dash["dolby"]) {
            if let dolbyAudios = JSONHelpers.array(dolby["audio"]) {
                audioTracks += parseDashAudioTracks(from: dolbyAudios)
            } else if let dolbyAudio = JSONHelpers.dict(dolby["audio"]) {
                audioTracks += parseDashAudioTracks(from: [dolbyAudio])
            }
        }

        let selectedAudio = selectBestAudioTrack(audioTracks)
        let format = JSONHelpers.string(data["format"]) ?? "dash"
        let selectedQualityLabel = qualityLabel(for: selectedVideo.id, data: data)
        let qualityOptions = dashQualityOptions(
            from: videoTracks,
            audioTrack: selectedAudio,
            data: data,
            format: format
        )

        return PlayableStream(
            transport: .dash(
                videoURL: selectedVideo.url,
                audioURL: selectedAudio?.url,
                videoFallbackURLs: selectedVideo.fallbackURLs,
                audioFallbackURLs: selectedAudio?.fallbackURLs ?? []
            ),
            headers: .bilibiliDefault,
            qualityID: selectedVideo.id,
            qualityLabel: selectedQualityLabel,
            format: format,
            qualityOptions: mergeQualityOptions(qualityOptions, ensuring: PlayableStream(
                transport: .dash(
                    videoURL: selectedVideo.url,
                    audioURL: selectedAudio?.url,
                    videoFallbackURLs: selectedVideo.fallbackURLs,
                    audioFallbackURLs: selectedAudio?.fallbackURLs ?? []
                ),
                headers: .bilibiliDefault,
                qualityID: selectedVideo.id,
                qualityLabel: selectedQualityLabel,
                format: format
            ))
        )
    }

    private func dashQualityOptions(
        from videoTracks: [DashVideoTrack],
        audioTrack: DashAudioTrack?,
        data: [String: Any],
        format: String
    ) -> [PlayableStream] {
        let grouped = Dictionary(grouping: videoTracks, by: \.id)
        let bestTrackByQuality: [Int: DashVideoTrack] = grouped.compactMapValues { tracks in
            tracks.sorted(by: isPreferredVideoTrack).first
        }

        var orderedQualityIDs: [Int] = []
        var seen = Set<Int>()
        let preferredOrder = (JSONHelpers.array(data["accept_quality"]) ?? []).compactMap(JSONHelpers.int)
        for quality in preferredOrder where bestTrackByQuality[quality] != nil {
            orderedQualityIDs.append(quality)
            seen.insert(quality)
        }

        let remaining = bestTrackByQuality.keys.filter { !seen.contains($0) }.sorted(by: >)
        orderedQualityIDs.append(contentsOf: remaining)

        return orderedQualityIDs.compactMap { qualityID in
            guard let videoTrack = bestTrackByQuality[qualityID] else {
                return nil
            }

            return PlayableStream(
                transport: .dash(
                    videoURL: videoTrack.url,
                    audioURL: audioTrack?.url,
                    videoFallbackURLs: videoTrack.fallbackURLs,
                    audioFallbackURLs: audioTrack?.fallbackURLs ?? []
                ),
                headers: .bilibiliDefault,
                qualityID: qualityID,
                qualityLabel: qualityLabel(for: qualityID, data: data),
                format: format
            )
        }
    }

    private func mergeQualityOptions(_ options: [PlayableStream], ensuring current: PlayableStream) -> [PlayableStream] {
        var seen = Set<String>()
        var merged: [PlayableStream] = []

        for option in options {
            let key = option.qualitySelectionKey
            guard seen.insert(key).inserted else {
                continue
            }
            merged.append(option)
        }

        if seen.insert(current.qualitySelectionKey).inserted {
            merged.insert(current, at: 0)
        }

        return merged
    }

    private func parseDashAudioTracks(from rawTracks: [Any]) -> [DashAudioTrack] {
        rawTracks.compactMap { raw -> DashAudioTrack? in
            guard let dict = JSONHelpers.dict(raw)
            else {
                return nil
            }
            let candidates = urlCandidates(from: dict)
            guard let firstURL = candidates.first else {
                return nil
            }

            return DashAudioTrack(
                url: firstURL,
                fallbackURLs: Array(candidates.dropFirst()),
                codecs: JSONHelpers.string(dict["codecs"]),
                codecid: JSONHelpers.int(dict["codecid"]),
                id: JSONHelpers.int(dict["id"]),
                bandwidth: JSONHelpers.int(dict["bandwidth"])
            )
        }
    }

    private func selectBestAudioTrack(_ tracks: [DashAudioTrack]) -> DashAudioTrack? {
        tracks.sorted { lhs, rhs in
            let lhsCodec = audioCodecRank(lhs.codecs)
            let rhsCodec = audioCodecRank(rhs.codecs)
            if lhsCodec != rhsCodec {
                return lhsCodec < rhsCodec
            }
            if lhs.bandwidth != rhs.bandwidth {
                return (lhs.bandwidth ?? 0) > (rhs.bandwidth ?? 0)
            }
            return (lhs.id ?? 0) > (rhs.id ?? 0)
        }.first
    }

    private func audioCodecRank(_ codec: String?) -> Int {
        guard let codec = codec?.lowercased() else {
            return 3
        }
        if codec.contains("mp4a") || codec.contains("aac") {
            return 0
        }
        if codec.contains("opus") {
            return 1
        }
        if codec.contains("ac-3") || codec.contains("ec-3") || codec.contains("flac") {
            return 2
        }
        return 3
    }

    private func urlCandidates(from dict: [String: Any], preferBackup: Bool = false) -> [URL] {
        let directCandidates: [String?] = [
            JSONHelpers.string(dict["url"]),
            JSONHelpers.string(dict["baseUrl"]),
            JSONHelpers.string(dict["base_url"])
        ]

        let backupArray = (JSONHelpers.array(dict["backupUrl"]) ?? JSONHelpers.array(dict["backup_url"]) ?? [])
            .compactMap(JSONHelpers.string)
        let backupSingle: [String?] = [
            JSONHelpers.string(dict["backupUrl"]),
            JSONHelpers.string(dict["backup_url"])
        ]

        let orderedCandidates: [String?]
        if preferBackup {
            orderedCandidates = backupArray.map(Optional.some) + backupSingle + directCandidates
        } else {
            orderedCandidates = directCandidates + backupArray.map(Optional.some) + backupSingle
        }

        var seen = Set<String>()
        var urls: [URL] = []
        for text in orderedCandidates {
            guard let text else {
                continue
            }
            guard seen.insert(text).inserted else {
                continue
            }
            if let url = normalizeNetworkURL(text) {
                urls.append(url)
            }
        }

        return urls
    }

    private func normalizeNetworkURL(_ text: String?) -> URL? {
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }

        if text.hasPrefix("//") {
            text = "https:\(text)"
        }

        guard let url = URL(string: text) else {
            return nil
        }

        if let scheme = url.scheme?.lowercased(), scheme == "https" {
            return url
        }

        if let scheme = url.scheme?.lowercased(), scheme == "http" {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            if let upgraded = components?.url {
                return upgraded
            }
        }

        return url
    }

    private func selectBestVideoTrack(_ tracks: [DashVideoTrack], preferredQuality: Int?) -> DashVideoTrack {
        let globallyPreferred = tracks.sorted(by: isPreferredVideoTrack).first ?? tracks[0]
        guard let preferredQuality else {
            return globallyPreferred
        }

        let qualityMatched = tracks.filter { $0.id == preferredQuality }
        guard let preferredTrack = qualityMatched.sorted(by: isPreferredVideoTrack).first else {
            return globallyPreferred
        }

        // Keep server-selected quality only when it is broadly compatible (AVC),
        // otherwise prioritize a safer codec to avoid AVFoundation -11828 failures.
        if codecRank(preferredTrack.codecs, codecid: preferredTrack.codecid) <= 0 {
            return preferredTrack
        }

        return globallyPreferred
    }

    private func isPreferredVideoTrack(_ lhs: DashVideoTrack, _ rhs: DashVideoTrack) -> Bool {
        let lhsCodec = codecRank(lhs.codecs, codecid: lhs.codecid)
        let rhsCodec = codecRank(rhs.codecs, codecid: rhs.codecid)
        if lhsCodec != rhsCodec {
            return lhsCodec < rhsCodec
        }
        if lhs.bandwidth != rhs.bandwidth {
            return (lhs.bandwidth ?? 0) > (rhs.bandwidth ?? 0)
        }
        return lhs.id > rhs.id
    }

    private func codecRank(_ codec: String?, codecid: Int?) -> Int {
        if let codecid {
            switch codecid {
            case 7:
                return 0
            case 12:
                return 1
            case 13:
                return 3
            default:
                break
            }
        }

        guard let codec = codec?.lowercased() else {
            return 2
        }
        if codec.contains("avc") || codec.contains("h264") {
            return 0
        }
        if codec.contains("hev") || codec.contains("hvc") || codec.contains("h265") {
            return 1
        }
        if codec.contains("av1") || codec.contains("av01") || codec.contains("vp9") || codec.contains("vp09") {
            return 3
        }
        return 2
    }

    private func resolveQualityLabel(data: [String: Any], fallbackQuality: Int?) -> String {
        let descriptions = (JSONHelpers.array(data["accept_description"]) ?? []).compactMap(JSONHelpers.string)
        let qualities = (JSONHelpers.array(data["accept_quality"]) ?? []).compactMap(JSONHelpers.int)
        let current = JSONHelpers.int(data["quality"]) ?? fallbackQuality

        if let current,
           let index = qualities.firstIndex(of: current),
           index < descriptions.count
        {
            return descriptions[index]
        }

        if let current {
            return "Q\(current)"
        }

        if let first = descriptions.first {
            return first
        }

        return "默认清晰度"
    }

    private func qualityLabel(for qualityID: Int, data: [String: Any]) -> String {
        var displayData = data
        displayData["quality"] = qualityID
        return resolveQualityLabel(data: displayData, fallbackQuality: qualityID)
    }

    private struct DashVideoTrack {
        let id: Int
        let url: URL
        let fallbackURLs: [URL]
        let codecs: String?
        let codecid: Int?
        let bandwidth: Int?
    }

    private struct DashAudioTrack {
        let url: URL
        let fallbackURLs: [URL]
        let codecs: String?
        let codecid: Int?
        let id: Int?
        let bandwidth: Int?
    }

    private func inferFormat(from url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "unknown" : ext
    }

    private func durlDurationSeconds(from rawLength: Any?) -> Double? {
        guard let lengthMilliseconds = JSONHelpers.double(rawLength),
              lengthMilliseconds > 0
        else {
            return nil
        }

        return lengthMilliseconds / 1000
    }

    private func htmlEntityDecode(_ text: String?) -> String? {
        guard let text else {
            return nil
        }

        return text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
