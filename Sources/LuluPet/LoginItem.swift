import Foundation
import ServiceManagement

/// 开机自动打开: a thin wrapper over `SMAppService.mainApp` (macOS 13+). The system's own status is the source of
/// truth, so nothing is stored in UserDefaults. Test instances (`--offscreen`) never touch the real login items.
enum LoginItem {
    enum State: Equatable {
        case on
        case off
        /// Registered, but the person still has to allow it in 系统设置 → 通用 → 登录项.
        case requiresApproval
        /// Not available (e.g. `swift run` from a build folder, or a test instance).
        case unavailable
    }

    /// Snapshots only: `LULU_LOGIN_ITEM_TEST=on|off|approval` shows that state without ever calling the system.
    static let testState: State? = {
        switch ProcessInfo.processInfo.environment["LULU_LOGIN_ITEM_TEST"] {
        case "on": return .on
        case "off": return .off
        case "approval": return .requiresApproval
        default: return nil
        }
    }()

    static var state: State {
        if let s = testState { return s }
        if Offscreen.enabled { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .off
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    /// Register / unregister. Returns an error text to show, or nil on success.
    @discardableResult
    static func set(_ on: Bool) -> String? {
        if Offscreen.enabled || testState != nil { return nil }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            NSLog("[lulu] launch at login %@ failed: %@", on ? "register" : "unregister", String(describing: error))
            return "没能设置成功，可以到 系统设置 → 通用 → 登录项 里手动添加"
        }
    }

    /// The status line under the toggle.
    static func hint(for state: State) -> String {
        switch state {
        case .on: return "已开启：登录 Mac 后噜噜桌宠会自动出现"
        case .off: return "登录 Mac 后自动打开噜噜桌宠（以后不用每次手动开）"
        case .requiresApproval: return "还差一步：到 系统设置 → 通用 → 登录项，把「噜噜桌宠」允许打开"
        case .unavailable: return "请先把噜噜桌宠放进「应用程序」文件夹再打开，才能设置开机自动打开"
        }
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
