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

    static func extractJSONValue(after marker: String, in html: String) -> String? {
        guard let markerRange = html.range(of: marker) else {
            return nil
        }

        var index = markerRange.upperBound
        return extractJSONValue(startingAt: &index, in: html)
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

    static func extractWindowAssignmentJSONValues(in html: String, limit: Int = 24) -> [String] {
        let pattern = "(?:window|self)\\.[A-Za-z0-9_$]+\\s*="
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, options: [], range: range)

        var values: [String] = []
        values.reserveCapacity(min(matches.count, limit))

        for match in matches {
            guard let matchRange = Range(match.range, in: html) else {
                continue
            }

            var index = matchRange.upperBound
            if let value = extractJSONValue(startingAt: &index, in: html) {
                values.append(value)
                if values.count >= limit {
                    break
                }
            }
        }

        return values
    }

    private static func extractJSONValue(startingAt index: inout String.Index, in text: String) -> String? {
        skipDelimiters(from: &index, in: text)
        guard index < text.endIndex else {
            return nil
        }

        if text[index...].hasPrefix("JSON.parse") {
            return parseJSONParseExpression(startingAt: &index, in: text)
        }

        let char = text[index]
        switch char {
        case "{", "[":
            return extractBalancedCollection(startingAt: index, in: text)
        case "\"", "'":
            guard let decoded = decodeJavaScriptStringLiteral(startingAt: &index, in: text) else {
                return nil
            }
            let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.first == "{" || trimmed.first == "[" else {
                return nil
            }
            return trimmed
        case "(":
            index = text.index(after: index)
            skipWhitespace(from: &index, in: text)
            if let parsed = parseJSONParseExpression(startingAt: &index, in: text) {
                return parsed
            }
            return extractJSONValue(startingAt: &index, in: text)
        default:
            return nil
        }
    }

    private static func parseJSONParseExpression(startingAt index: inout String.Index, in text: String) -> String? {
        let prefix = "JSON.parse"
        guard text[index...].hasPrefix(prefix) else {
            return nil
        }

        index = text.index(index, offsetBy: prefix.count)
        skipWhitespace(from: &index, in: text)
        guard index < text.endIndex, text[index] == "(" else {
            return nil
        }

        index = text.index(after: index)
        skipWhitespace(from: &index, in: text)
        guard index < text.endIndex else {
            return nil
        }

        let parsed: String?
        if text[index...].hasPrefix("decodeURIComponent") {
            parsed = parseDecodeURIComponentExpression(startingAt: &index, in: text)
        } else if text[index...].hasPrefix("atob") {
            parsed = parseAtobExpression(startingAt: &index, in: text)
        } else {
            parsed = decodeJavaScriptStringLiteral(startingAt: &index, in: text)
        }

        guard let parsed else {
            return nil
        }

        skipWhitespace(from: &index, in: text)
        if index < text.endIndex, text[index] == ")" {
            index = text.index(after: index)
        }

        let trimmed = parsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[" else {
            return nil
        }
        return trimmed
    }

    private static func parseDecodeURIComponentExpression(startingAt index: inout String.Index, in text: String) -> String? {
        let prefix = "decodeURIComponent"
        guard text[index...].hasPrefix(prefix) else {
            return nil
        }

        index = text.index(index, offsetBy: prefix.count)
        skipWhitespace(from: &index, in: text)
        guard index < text.endIndex, text[index] == "(" else {
            return nil
        }

        index = text.index(after: index)
        skipWhitespace(from: &index, in: text)
        guard let encoded = decodeJavaScriptStringLiteral(startingAt: &index, in: text) else {
            return nil
        }

        skipWhitespace(from: &index, in: text)
        if index < text.endIndex, text[index] == ")" {
            index = text.index(after: index)
        }

        return encoded.removingPercentEncoding
    }

    private static func parseAtobExpression(startingAt index: inout String.Index, in text: String) -> String? {
        let prefix = "atob"
        guard text[index...].hasPrefix(prefix) else {
            return nil
        }

        index = text.index(index, offsetBy: prefix.count)
        skipWhitespace(from: &index, in: text)
        guard index < text.endIndex, text[index] == "(" else {
            return nil
        }

        index = text.index(after: index)
        skipWhitespace(from: &index, in: text)
        guard let encoded = decodeJavaScriptStringLiteral(startingAt: &index, in: text),
              let data = Data(base64Encoded: encoded),
              let decoded = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        skipWhitespace(from: &index, in: text)
        if index < text.endIndex, text[index] == ")" {
            index = text.index(after: index)
        }

        return decoded
    }

    private static func extractBalancedCollection(startingAt start: String.Index, in text: String) -> String? {
        let opening = text[start]
        guard opening == "{" || opening == "[" else {
            return nil
        }

        var stack: [Character] = [opening == "{" ? "}" : "]"]
        var current = text.index(after: start)
        var inString = false
        var escape = false

        while current < text.endIndex {
            let char = text[current]

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
                    stack.append("}")
                } else if char == "[" {
                    stack.append("]")
                } else if char == "}" || char == "]" {
                    guard stack.last == char else {
                        return nil
                    }
                    stack.removeLast()
                    if stack.isEmpty {
                        let end = text.index(after: current)
                        return String(text[start..<end])
                    }
                }
            }

            current = text.index(after: current)
        }

        return nil
    }

    private static func decodeJavaScriptStringLiteral(startingAt index: inout String.Index, in text: String) -> String? {
        guard index < text.endIndex else {
            return nil
        }

        let quote = text[index]
        guard quote == "\"" || quote == "'" else {
            return nil
        }

        index = text.index(after: index)
        var output = ""

        while index < text.endIndex {
            let char = text[index]

            if char == quote {
                index = text.index(after: index)
                return output
            }

            if char == "\\" {
                index = text.index(after: index)
                guard index < text.endIndex else {
                    return nil
                }

                let escaped = text[index]
                switch escaped {
                case "\"":
                    output.append("\"")
                case "'":
                    output.append("'")
                case "\\":
                    output.append("\\")
                case "/":
                    output.append("/")
                case "b":
                    output.append("\u{08}")
                case "f":
                    output.append("\u{0C}")
                case "n":
                    output.append("\n")
                case "r":
                    output.append("\r")
                case "t":
                    output.append("\t")
                case "u":
                    guard let scalar = decodeUnicodeEscape(startingAt: &index, in: text, digits: 4) else {
                        return nil
                    }
                    output.unicodeScalars.append(scalar)
                case "x":
                    guard let scalar = decodeUnicodeEscape(startingAt: &index, in: text, digits: 2) else {
                        return nil
                    }
                    output.unicodeScalars.append(scalar)
                default:
                    output.append(escaped)
                }
            } else {
                output.append(char)
            }

            index = text.index(after: index)
        }

        return nil
    }

    private static func decodeUnicodeEscape(
        startingAt index: inout String.Index,
        in text: String,
        digits: Int
    ) -> UnicodeScalar? {
        var value = 0
        var cursor = index

        for _ in 0..<digits {
            cursor = text.index(after: cursor)
            guard cursor < text.endIndex else {
                return nil
            }

            let char = text[cursor]
            guard let hex = char.hexDigitValue else {
                return nil
            }
            value = (value << 4) | hex
        }

        index = cursor
        return UnicodeScalar(value)
    }

    private static func skipWhitespace(from index: inout String.Index, in text: String) {
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
    }

    private static func skipDelimiters(from index: inout String.Index, in text: String) {
        while index < text.endIndex {
            let char = text[index]
            if char.isWhitespace || char == "=" || char == ":" || char == ";" {
                index = text.index(after: index)
                continue
            }
            break
        }
    }
}
