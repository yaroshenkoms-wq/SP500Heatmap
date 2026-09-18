import Foundation

enum Config {
    static let baseURL: String = infoValue(for: "BASE_URL")
    static let websocketURL: String = infoValue(for: "WEBSOCKET_URL")

    private static func infoValue(for key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else {
            fatalError("\(key) is missing from Info.plist — check BASE_URL/WEBSOCKET_URL in the active build configuration.")
        }
        return value
    }
}
