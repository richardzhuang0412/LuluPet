import Foundation

/// v0.11.2: where my own app version comes from. nil outside a bundle (swift run): nothing is published or nudged.
enum AppVersionSource {
    /// Hidden `--fake-app-version X` (testing): replaces the reported version.
    static var override: String?

    static var current: String? {
        override ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    }
}
