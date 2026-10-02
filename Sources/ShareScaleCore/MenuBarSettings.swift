import Combine
import Foundation
import ShareScaleHostCore

/// メニューバーと Dock の設定（環境設定 `io.github.taki-0105a.ShareScale`。計画 2f-2 案 1・2）
/// - `showsInDock`: 「Dock に表示する」（`appearance.dock`。既定はオン。オフなら `NSApp.setActivationPolicy(.accessory)`）
/// - `hostIconAlwaysVisible`: 「ShareScale Host のアイコンを常にメニューバーに表示する」（`appearance.hostIcon`。既定はオフ＝ShareScale が開いている間は
///   Host のアイコンを出さず、ShareScale のメニューに「この Mac の接続先」をまとめる）
public struct AppearancePreferences {
    private let store: StringStore
    public init(store: StringStore) { self.store = store }
    public var showsInDock: Bool {
        get { store.string(forKey: "appearance.dock") != "0" }
        nonmutating set { store.set(newValue ? "1" : "0", forKey: "appearance.dock") }
    }
    public var hostIconAlwaysVisible: Bool {
        get { store.string(forKey: "appearance.hostIcon") == "1" }
        nonmutating set { store.set(newValue ? "1" : "0", forKey: "appearance.hostIcon") }
    }
}

/// メニューバーの受け持ちの印（`host-control/menubar-owner.json`）を書く・消す（ShareScale.app 側。計画 2f-2 案 2）。
/// 書いた・消した後に host-control の「読み直して」を送り、Host がすぐにアイコンを出し入れする
public struct MenuBarClaimKeeper: Sendable {
    let folder: HostControlFolder
    let pid: Int64
    let notify: @Sendable () -> Void
    let wallClock: @Sendable () -> Date
    public init(folder: HostControlFolder, pid: Int64, notify: @escaping @Sendable () -> Void = { HostControlFolder.postNotification() },
                wallClock: @escaping @Sendable () -> Date = { Date() }) {
        self.folder = folder; self.pid = pid; self.notify = notify; self.wallClock = wallClock
    }
    /// 受け持つ（`claim`）か、手放す。書けなかった時は何もしない（Host はアイコンを出したまま＝消えたままにはならない）
    public func update(claim: Bool) {
        if claim {
            guard let c = MenuBarClaim(pid: pid, at: Int64(wallClock().timeIntervalSince1970)), (try? folder.writeMenuBarClaim(c)) != nil else { return }
        } else {
            folder.removeMenuBarClaim(ownedBy: pid)
        }
        notify()
    }
}

/// 設定 › 一般 の「メニューバーと Dock」に出すもの（純粋な値）
public struct AppearanceModel: Equatable, Sendable {
    public var showsInDock: Bool
    public var dockNote: String
    public var hostIconAlwaysVisible: Bool
    public var hostIconNote: String
    public init(showsInDock: Bool, dockNote: String, hostIconAlwaysVisible: Bool, hostIconNote: String) {
        self.showsInDock = showsInDock; self.dockNote = dockNote; self.hostIconAlwaysVisible = hostIconAlwaysVisible; self.hostIconNote = hostIconNote
    }
}

/// 設定 › 一般 の「メニューバーと Dock」（計画 2f-2 案 1・2）。変えたらすぐに当てる（Dock は `applyDock`、Host のアイコンは受け持ちの印）
@MainActor
public final class AppearanceSettings: ObservableObject {
    @Published public private(set) var showsInDock: Bool
    @Published public private(set) var hostIconAlwaysVisible: Bool
    private let preferences: AppearancePreferences
    private let applyDock: (Bool) -> Void
    private let claim: (Bool) -> Void
    /// - `applyDock`: Dock に出すかを当てる（実物は `NSApp.setActivationPolicy(.regular / .accessory)`）
    /// - `claim`: メニューバーを受け持つか（実物は `MenuBarClaimKeeper.update(claim:)`）
    public init(preferences: AppearancePreferences, applyDock: @escaping (Bool) -> Void, claim: @escaping (Bool) -> Void) {
        self.preferences = preferences; self.applyDock = applyDock; self.claim = claim
        showsInDock = preferences.showsInDock
        hostIconAlwaysVisible = preferences.hostIconAlwaysVisible
    }
    /// 起動した時: 保存してある設定を当てる
    public func applyAtLaunch() {
        applyDock(showsInDock)
        claim(!hostIconAlwaysVisible && !yieldToHost)
    }
    /// 終了する時: 受け持ちの印を消す（Host がアイコンを出し直す）
    public func releaseAtQuit() { claim(false) }

    public func setShowsInDock(_ on: Bool) {
        showsInDock = on; preferences.showsInDock = on
        applyDock(on)
    }
    public func setHostIconAlwaysVisible(_ on: Bool) {
        hostIconAlwaysVisible = on; preferences.hostIconAlwaysVisible = on
        claim(!on && !yieldToHost)
    }

    /// ShareScale だけが Host の状態を読めない間（`HostPanelStore.yieldsMenuBar`）は受け持ちを外し、Host にアイコンを戻させる。
    /// 読めるようになったら受け持ち直す（「常に表示する」がオフの時だけ。再点検 2f-2）
    private var yieldToHost = false
    public func setYieldToHost(_ yield: Bool) {
        guard yield != yieldToHost else { return }
        yieldToHost = yield
        claim(!hostIconAlwaysVisible && !yield)
    }

    /// 設定 › 一般 に出すもの
    public var model: AppearanceModel {
        AppearanceModel(showsInDock: showsInDock, dockNote: dockNote, hostIconAlwaysVisible: hostIconAlwaysVisible, hostIconNote: hostIconNote)
    }

    /// 「ShareScale Host のアイコンを常にメニューバーに表示する」の説明
    public var hostIconNote: String {
        tr("オフの時は、ShareScale が開いている間、ShareScale Host のアイコンを出さずに、ShareScale のメニューの「この Mac の接続先」にまとめます。",
           "When off, ShareScale Host’s icon is hidden while ShareScale is open, and its items appear under This Mac as a Target in the ShareScale menu.")
    }
    /// 「Dock に表示する」の説明
    public var dockNote: String {
        tr("オフにしても、ShareScale はメニューバーから使えます。ウインドウを閉じても ShareScale は終了しません。",
           "When off, you can still use ShareScale from the menu bar. Closing the window doesn’t quit ShareScale.")
    }
}
