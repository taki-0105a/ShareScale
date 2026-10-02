import AppKit
import ShareScaleHostCore
import ShareScaleProtocol

/// メニューの項目が押された時の行き先（`HostAppController` が実装）
@MainActor
public protocol StatusMenuActions: AnyObject {
    func addViewer()
    func showCode()
    func unpair(_ id: PairingID)
    func snooze(_ id: PairingID)
    func togglePause()
    func showDiagnostics()
    func openLog()
    func quit()
}

/// メニューバーのアイコンとメニュー。項目は開くたびに `entries()`（`MenuModel.build(…, now: Date())`）で作り直す
/// （`NSMenuDelegate.menuNeedsUpdate`。コードの残り時間や最終接続が開いた時点の値になる）
@MainActor
public final class StatusMenu: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private let entries: () -> [MenuEntry]
    public weak var actions: StatusMenuActions?

    /// - `entries`: 今の項目（開くたびに呼ぶ）
    public init(entries: @escaping () -> [MenuEntry]) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.entries = entries
        super.init()
        item.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "ShareScale Host")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "ShareScale Host"
        menu.delegate = self
        item.menu = menu
    }

    public func menuNeedsUpdate(_ menu: NSMenu) { update(entries()) }

    /// メニューバーにアイコンを出しているか（ShareScale.app がメニューバーを受け持っている間は隠す。計画 2f-2 案 2）
    public var isVisible: Bool {
        get { item.isVisible }
        set { if item.isVisible != newValue { item.isVisible = newValue } }
    }

    /// 項目を作り直す
    func update(_ entries: [MenuEntry]) {
        menu.removeAllItems()
        for e in entries {
            switch e {
            case let .status(text), let .notice(text):
                menu.addItem(disabled(text))
            case let .addViewer(title, enabled):
                let m = NSMenuItem(title: title, action: #selector(addViewer), keyEquivalent: "")
                m.target = self; m.isEnabled = enabled
                menu.addItem(m)
            case let .showCode(title):
                menu.addItem(action(title, #selector(showCode)))
            case let .viewer(id, title, detail, stale, unpair, later):
                let m = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                if stale { m.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil) }   // 80 日の知らせの印
                let sub = NSMenu()
                sub.addItem(disabled(detail))
                sub.addItem(.separator())
                let u = action(unpair, #selector(unpairViewer(_:))); u.representedObject = Payload(id); sub.addItem(u)
                if let later {
                    let l = action(later, #selector(snoozeViewer(_:))); l.representedObject = Payload(id); sub.addItem(l)
                }
                m.submenu = sub
                menu.addItem(m)
            case let .pause(title, _):
                menu.addItem(action(title, #selector(togglePause)))
            case let .reviewViewers(text):   // Host のメニューには出ない（ShareScale のメニューの節だけ）
                menu.addItem(disabled(text))
            case let .diagnostics(title):
                menu.addItem(action(title, #selector(showDiagnostics)))
            case let .openLog(title):
                menu.addItem(action(title, #selector(openLog)))
            case let .quit(title):
                let m = action(title, #selector(quit)); m.keyEquivalent = "q"; menu.addItem(m)
            case .separator:
                menu.addItem(.separator())
            }
        }
    }

    private final class Payload: NSObject { let id: PairingID; init(_ id: PairingID) { self.id = id } }
    private func disabled(_ text: String) -> NSMenuItem {
        let m = NSMenuItem(title: text, action: nil, keyEquivalent: ""); m.isEnabled = false; return m
    }
    private func action(_ title: String, _ sel: Selector) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: sel, keyEquivalent: ""); m.target = self; return m
    }
    @objc private func addViewer() { actions?.addViewer() }
    @objc private func showCode() { actions?.showCode() }
    @objc private func unpairViewer(_ sender: NSMenuItem) { if let p = sender.representedObject as? Payload { actions?.unpair(p.id) } }
    @objc private func snoozeViewer(_ sender: NSMenuItem) { if let p = sender.representedObject as? Payload { actions?.snooze(p.id) } }
    @objc private func togglePause() { actions?.togglePause() }
    @objc private func showDiagnostics() { actions?.showDiagnostics() }
    @objc private func openLog() { actions?.openLog() }
    @objc private func quit() { actions?.quit() }
}
