import Foundation

/// The tutor server this build connects to out of the box. The URL is public. The access token is
/// never committed or built in CI (this repo is public): it's added to the finished .ipa's
/// Info.plist as `MarginServerToken` just before sideloading. Without it, the app asks in Settings.
enum BuildConfig {
    static let serverURL = "tutor-server-production.up.railway.app"
    static var serverToken: String {
        (Bundle.main.object(forInfoDictionaryKey: "MarginServerToken") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
