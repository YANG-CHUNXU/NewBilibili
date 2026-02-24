import Foundation

public enum HomeFeedAssembler {
    public static func merge(_ lists: [[VideoCard]], limit: Int) -> [VideoCard] {
        var seen = Set<String>()
        var merged: [VideoCard] = []

        for list in lists {
            for video in list where seen.insert(video.bvid).inserted {
                merged.append(video)
            }
        }

        merged.sort {
            let lhs = $0.publishTime ?? .distantPast
            let rhs = $1.publishTime ?? .distantPast
            if lhs == rhs {
                return $0.bvid < $1.bvid
            }
            return lhs > rhs
        }

        if merged.count > limit {
            return Array(merged.prefix(limit))
        }
        return merged
    }
}
