import Foundation

enum BridgeJSON {
    static func string(_ value: Any) -> String? {
        guard let json = normalized(value),
              JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private static func normalized(_ value: Any) -> Any? {
        switch value {
        case let dict as [String: Any]:
            var result: [String: Any] = [:]
            for (key, nested) in dict {
                guard let normalizedNested = normalized(nested) else { continue }
                result[key] = normalizedNested
            }
            return result
        case let dict as NSDictionary:
            return normalized(dict as? [String: Any] ?? [:])
        case let array as [Any]:
            return array.compactMap { normalized($0) }
        case let array as NSArray:
            return array.compactMap { normalized($0) }
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            let doubleValue = number.doubleValue
            if doubleValue.rounded(.towardZero) == doubleValue {
                return number.int64Value
            }
            return doubleValue
        case let string as String:
            return string
        case let string as NSString:
            return string as String
        case is NSNull:
            return NSNull()
        default:
            return String(describing: value)
        }
    }
}
