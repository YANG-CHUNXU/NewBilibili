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
        let root = JSONHelpers.dict(decoded) ?? [:]
        let data = JSONHelpers.dict(root["data"]) ?? root

        if let progressive = parseProgressiveStream(data: data) {
            return progressive
        }

        if let dash = try parseDashStream(data: data) {
            return dash
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
        var candidateDicts: [[String: Any]] = []
        JSONHelpers.collectDicts(in: root, where: { dict in
            JSONHelpers.string(dict["bvid"]) != nil && JSONHelpers.string(dict["title"]) != nil
        }, output: &candidateDicts)

        var seen = Set<String>()
        var mapped: [VideoCard] = []

        for dict in candidateDicts {
            guard let bvid = JSONHelpers.string(dict["bvid"]), !bvid.isEmpty else {
                continue
            }
            guard seen.insert(bvid).inserted else {
                continue
            }

            let title = htmlEntityDecode(JSONHelpers.string(dict["title"])) ?? ""
            let author = htmlEntityDecode(
                JSONHelpers.string(dict["author"]) ??
                JSONHelpers.string(dict["author_name"]) ??
                JSONHelpers.string(dict["name"]) ??
                JSONHelpers.string(dict["uname"])
            ) ?? "未知UP主"
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
                    authorName: author,
                    authorUID: JSONHelpers.string(dict["mid"]) ?? JSONHelpers.string(dict["uid"]) ?? JSONHelpers.string(dict["author_mid"]),
                    durationText: durationText,
                    publishTime: publishTime
                )
            )
        }

        return mapped
    }

    private func normalizeImageURL(_ text: String?) -> URL? {
        guard var text else {
            return nil
        }

        if text.hasPrefix("//") {
            text = "https:\(text)"
        }

        return URL(string: text)
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
        guard let first = durl.first,
              let firstDict = JSONHelpers.dict(first),
              let url = firstURL(from: firstDict)
        else {
            return nil
        }

        let format = JSONHelpers.string(data["format"]) ?? inferFormat(from: url)
        let qualityLabel = resolveQualityLabel(data: data, fallbackQuality: nil)
        return PlayableStream(
            transport: .progressive(url: url),
            headers: .bilibiliDefault,
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
                  let id = JSONHelpers.int(dict["id"]),
                  let url = firstURL(from: dict)
            else {
                return nil
            }

            return DashVideoTrack(
                id: id,
                url: url,
                codecs: JSONHelpers.string(dict["codecs"]),
                bandwidth: JSONHelpers.int(dict["bandwidth"])
            )
        }

        guard !videoTracks.isEmpty else {
            throw BiliClientError.unsupportedDashStream("缺少可用视频轨")
        }

        let preferredQuality = JSONHelpers.int(data["quality"])
        let selectedVideo = selectBestVideoTrack(videoTracks, preferredQuality: preferredQuality)

        let rawAudios = JSONHelpers.array(dash["audio"]) ?? []
        let audioTracks = rawAudios.compactMap { raw -> DashAudioTrack? in
            guard let dict = JSONHelpers.dict(raw),
                  let url = firstURL(from: dict)
            else {
                return nil
            }

            return DashAudioTrack(
                url: url,
                bandwidth: JSONHelpers.int(dict["bandwidth"])
            )
        }
        let selectedAudio = audioTracks.max { lhs, rhs in
            (lhs.bandwidth ?? 0) < (rhs.bandwidth ?? 0)
        }

        var displayData = data
        displayData["quality"] = selectedVideo.id

        return PlayableStream(
            transport: .dash(videoURL: selectedVideo.url, audioURL: selectedAudio?.url),
            headers: .bilibiliDefault,
            qualityLabel: resolveQualityLabel(data: displayData, fallbackQuality: selectedVideo.id),
            format: JSONHelpers.string(data["format"]) ?? "dash"
        )
    }

    private func firstURL(from dict: [String: Any]) -> URL? {
        let directCandidates = [
            JSONHelpers.string(dict["url"]),
            JSONHelpers.string(dict["baseUrl"]),
            JSONHelpers.string(dict["base_url"])
        ]
        for text in directCandidates {
            if let text, let url = URL(string: text) {
                return url
            }
        }

        let backupArray = (JSONHelpers.array(dict["backupUrl"]) ?? JSONHelpers.array(dict["backup_url"]) ?? [])
            .compactMap(JSONHelpers.string)
        for text in backupArray {
            if let url = URL(string: text) {
                return url
            }
        }

        let backupSingle = [
            JSONHelpers.string(dict["backupUrl"]),
            JSONHelpers.string(dict["backup_url"])
        ]
        for text in backupSingle {
            if let text, let url = URL(string: text) {
                return url
            }
        }

        return nil
    }

    private func selectBestVideoTrack(_ tracks: [DashVideoTrack], preferredQuality: Int?) -> DashVideoTrack {
        let qualityMatched = preferredQuality.flatMap { quality in
            let matches = tracks.filter { $0.id == quality }
            return matches.isEmpty ? nil : matches
        }
        let candidates: [DashVideoTrack]
        if let qualityMatched {
            candidates = qualityMatched
        } else if let maxID = tracks.map(\.id).max() {
            candidates = tracks.filter { $0.id == maxID }
        } else {
            candidates = tracks
        }

        return candidates.sorted { lhs, rhs in
            let lhsCodec = codecRank(lhs.codecs)
            let rhsCodec = codecRank(rhs.codecs)
            if lhsCodec != rhsCodec {
                return lhsCodec < rhsCodec
            }
            if lhs.bandwidth != rhs.bandwidth {
                return (lhs.bandwidth ?? 0) > (rhs.bandwidth ?? 0)
            }
            return lhs.id > rhs.id
        }.first ?? tracks[0]
    }

    private func codecRank(_ codec: String?) -> Int {
        guard let codec = codec?.lowercased() else {
            return 2
        }
        if codec.contains("avc") || codec.contains("h264") {
            return 0
        }
        if codec.contains("hev") || codec.contains("hvc") || codec.contains("h265") {
            return 1
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

        if let first = descriptions.first {
            return first
        }

        if let current {
            return "Q\(current)"
        }

        return "默认清晰度"
    }

    private struct DashVideoTrack {
        let id: Int
        let url: URL
        let codecs: String?
        let bandwidth: Int?
    }

    private struct DashAudioTrack {
        let url: URL
        let bandwidth: Int?
    }

    private func inferFormat(from url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "unknown" : ext
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
