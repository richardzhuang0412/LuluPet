import AppKit

/// The app runs as a menu-bar ("accessory") app, so it has no visible menu bar of its own — but text
/// fields only get ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z through the main menu's key equivalents. Install a standard
/// (invisible while accessory) Edit menu so copy & paste work in Settings and the compose panel.
enum AppMenus {
    @MainActor static func install() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "噜噜桌宠")
        // No ⌘Q on purpose: it was too easy to quit the whole pet while closing a panel (quit via 🍊 → 退出).
        appMenu.addItem(withTitle: "退出噜噜桌宠", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}

/// Shows the Dock icon while something needs it (e.g. the Settings window) or when the user asked for
/// it permanently (`ConfigStore.showInDock`); otherwise the app stays a menu-bar-only accessory app.
@MainActor
final class DockPresence {
    static let shared = DockPresence()
    private var holders = Set<String>()
    var always = false { didSet { update() } }

    func acquire(_ key: String) { holders.insert(key); update() }
    func release(_ key: String) { holders.remove(key); update() }

    private func update() {
        let want: NSApplication.ActivationPolicy = (always || !holders.isEmpty) ? .regular : .accessory
        guard NSApp.activationPolicy() != want else { return }
        NSApp.setActivationPolicy(want)
        if want == .regular { NSApp.activate() }
        NSLog("[lulu] dock icon: %@", want == .regular ? "shown" : "hidden")
    }
}
