import Foundation

enum JSONHelpers {
    static func dict(_ any: Any?) -> [String: Any]? {
        any as? [String: Any]
    }

    static func array(_ any: Any?) -> [Any]? {
        any as? [Any]
    }

    static func string(_ any: Any?) -> String? {
        if let value = any as? String {
            return value
        }
        if let number = any as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    static func int(_ any: Any?) -> Int? {
        if let value = any as? Int {
            return value
        }
        if let stringValue = any as? String {
            return Int(stringValue)
        }
        if let number = any as? NSNumber {
            return number.intValue
        }
        return nil
    }

    static func double(_ any: Any?) -> Double? {
        if let value = any as? Double {
            return value
        }
        if let number = any as? NSNumber {
            return number.doubleValue
        }
        if let stringValue = any as? String {
            return Double(stringValue)
        }
        return nil
    }

    static func dateFromTimestamp(_ any: Any?) -> Date? {
        guard let ts = double(any) else {
            return nil
        }
        if ts > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: ts / 1000)
        }
        return Date(timeIntervalSince1970: ts)
    }

    static func findFirstDict(in root: Any, where predicate: ([String: Any]) -> Bool) -> [String: Any]? {
        if let dict = root as? [String: Any] {
            if predicate(dict) {
                return dict
            }
            for value in dict.values {
                if let result = findFirstDict(in: value, where: predicate) {
                    return result
                }
            }
        } else if let array = root as? [Any] {
            for item in array {
                if let result = findFirstDict(in: item, where: predicate) {
                    return result
                }
            }
        }
        return nil
    }

    static func collectDicts(in root: Any, where predicate: ([String: Any]) -> Bool, output: inout [[String: Any]]) {
        if let dict = root as? [String: Any] {
            if predicate(dict) {
                output.append(dict)
            }
            for value in dict.values {
                collectDicts(in: value, where: predicate, output: &output)
            }
        } else if let array = root as? [Any] {
            for item in array {
                collectDicts(in: item, where: predicate, output: &output)
            }
        }
    }
}
