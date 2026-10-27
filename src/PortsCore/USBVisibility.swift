import Foundation

enum USBVisibility {
    static func removability(_ value: Any?) -> Bool? {
        if let text = value as? String {
            switch text.lowercased() {
            case "yes", "true": return true
            case "no", "false": return false
            default: return nil
            }
        }
        return (value as? NSNumber)?.boolValue
    }
}
