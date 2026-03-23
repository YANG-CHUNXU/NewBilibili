import Foundation

enum DurationTextResolver {
    static func text(from values: [Any?]) -> String? {
        guard let seconds = seconds(from: values) else {
            return nil
        }
        return VideoDurationHydrator.formatDuration(seconds)
    }

    static func seconds(from values: [Any?]) -> Int? {
        for value in values {
            guard let seconds = seconds(from: value) else {
                continue
            }
            return seconds
        }
        return nil
    }

    static func seconds(from value: Any?) -> Int? {
        if let intValue = JSONHelpers.int(value), intValue > 0 {
            return intValue
        }

        guard let text = JSONHelpers.string(value)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            return nil
        }

        if let directInt = Int(text), directInt > 0 {
            return directInt
        }

        let parts = text.split(separator: ":")
        guard (2...3).contains(parts.count) else {
            return nil
        }

        let values = parts.compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard values.count == parts.count else {
            return nil
        }

        if values.count == 2 {
            let minutes = values[0]
            let seconds = values[1]
            guard seconds >= 0, seconds < 60 else {
                return nil
            }
            return minutes * 60 + seconds
        }

        let hours = values[0]
        let minutes = values[1]
        let seconds = values[2]
        guard minutes >= 0, minutes < 60, seconds >= 0, seconds < 60 else {
            return nil
        }
        return hours * 3600 + minutes * 60 + seconds
    }
}
