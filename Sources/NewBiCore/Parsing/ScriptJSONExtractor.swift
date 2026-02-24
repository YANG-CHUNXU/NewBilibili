import Foundation

enum ScriptJSONExtractor {
    static func extractJSONObject(after marker: String, in html: String) -> String? {
        guard let markerRange = html.range(of: marker) else {
            return nil
        }

        var index = markerRange.upperBound
        while index < html.endIndex, html[index].isWhitespace {
            index = html.index(after: index)
        }

        guard index < html.endIndex, html[index] == "{" else {
            return nil
        }

        let objectStart = index
        var current = index
        var depth = 0
        var inString = false
        var escape = false

        while current < html.endIndex {
            let char = html[current]

            if inString {
                if escape {
                    escape = false
                } else if char == "\\" {
                    escape = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                if char == "\"" {
                    inString = true
                } else if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        let objectEnd = html.index(after: current)
                        return String(html[objectStart..<objectEnd])
                    }
                }
            }

            current = html.index(after: current)
        }

        return nil
    }

    static func decodeJSONObject(from json: String) throws -> Any {
        guard let data = json.data(using: .utf8) else {
            throw BiliClientError.parseFailed("JSON 编码无效")
        }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BiliClientError.parseFailed("JSON 反序列化失败")
        }
    }

    static func extractScriptTagContent(id: String, in html: String) -> String? {
        let escapedID = NSRegularExpression.escapedPattern(for: id)
        let pattern = "<script[^>]*id=[\"']\(escapedID)[\"'][^>]*>(.*?)</script>"

        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return nil
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges > 1,
              let contentRange = Range(match.range(at: 1), in: html)
        else {
            return nil
        }

        return String(html[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
