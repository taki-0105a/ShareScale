import AppKit
import ShareScaleCore
import ShareScaleUI
import SwiftUI

/// ShareScale.app（見る側の画面・設定）。窓は主の窓（`Window` 1 つ）・診断の窓・完全な削除の窓・設定（`Settings`）と、メニューバーの項目（`MenuBarExtra`。計画 2f-2 案 1）。
/// 起動の入り口は `Entry`（`Launch.swift`）で、見る側として動く役（複製・開発の組み立て）の時だけここに来る。
/// 組み立て（`ViewerApp`）は `AppDelegate` が持ち、前面に来た時・画面の構成が変わった時・メニューバーのメニューを開いた時の知らせも `AppDelegate` で受ける（窓に依らない）。
/// 取り直し（`ViewerModel.refresh`）は、起動時（`ViewerTargets.reload` が接続先を決めた時）・前面に来た時・メニューバーのメニューを開いた時・更新ボタン・接続先の切り替え・
/// 裏での取り直し（通知のため。`BackgroundRefresher`）で、画面に結び付かない `Task` から呼ぶ（`.task {}` は使わない。2d-1「2d-2 への注記」）。
/// 主の窓を閉じても終了しない（メニューバーに残る。計画 2f-2 案 1）
struct ShareScaleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        let app = delegate.app
        Window("ShareScale", id: WindowID.main) {
            MainWindow(model: app.model, targets: app.targets, host: app.host, uninstall: app.uninstall, guide: app.guide, loginItems: app.loginItems,
                       router: app.router, updates: app.updates, onUpdate: { app.startUpdate() }, version: AppInfo.version, makeAddTarget: app.makeAddTarget)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) { DiagnosticsMenuItem() }
            // 「ヘルプ」: 標準の「ShareScale ヘルプ」は、ヘルプの本が無いので選んでも何も出ない。公開のリポジトリを開く項目だけにする（計画 2h）
            CommandGroup(replacing: .help) { HelpMenuItem() }
        }

        // 診断と完全な削除のウインドウは、「ウインドウ」のメニューに開く項目を出さない（`Window` の場面は、自動で「ウインドウ › <題名>」を足す。
        // 「ShareScale を完全に削除」がふつうのウインドウの一覧に並んで紛らわしかった。計画 2h・実機確認 A）。
        // 開く道は今までどおり: 診断は「ShareScale › 診断…」（⇧⌘D）と案内の「診断…」、完全な削除は 設定 › 一般 の「ShareScale を完全に削除…」と起動時の問いかけ。
        // 開いている間は、「ウインドウ」のメニューの開いているウインドウの一覧に出る（macOS の標準の動き）
        Window(tr("診断", "Diagnostics"), id: WindowID.diagnostics) {
            DiagnosticsWindow(model: app.model, targets: app.targets, distribution: app.distribution, version: AppInfo.version)
        }
        .windowResizability(.contentSize)
        .commandsRemoved()

        Window(tr("ShareScale を完全に削除", "Remove ShareScale Completely"), id: WindowID.uninstall) {
            UninstallWindow(flow: app.uninstall)
        }
        .windowResizability(.contentSize)
        .commandsRemoved()

        Settings {
            SettingsWindow(targets: app.targets, host: app.host, loginItems: app.loginItems, uninstall: app.uninstall,
                           notifications: app.notifications, router: app.router, appearance: app.appearance, openAtLogin: app.openAtLogin,
                           guide: app.guide, version: AppInfo.version, makeAddTarget: app.makeAddTarget)
        }

        // メニューバー（`.menu` の形。項目は `ViewerMenu.items`。開いた時の取り直しは `AppDelegate` が `NSMenu` の知らせで行う）
        MenuBarExtra {
            ViewerMenuBar(model: app.model, targets: app.targets, host: app.host, router: app.router, updates: app.updates,
                          onUpdate: { app.startUpdate() }, onQuit: { NSApp.terminate(nil) })
        } label: {
            MenuBarLabel(router: app.router)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// メニュー「ShareScale › 診断…」（⇧⌘D）
struct DiagnosticsMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button { openWindow(id: WindowID.diagnostics) } label: { Text(verbatim: tr("診断…", "Diagnostics…")) }
            .keyboardShortcut("d", modifiers: [.command, .shift])
    }
}

/// メニュー「ヘルプ › ShareScale の説明を GitHub で開く」（公開のリポジトリを、利用者のブラウザで開く。アプリ自身は通信しない）
struct HelpMenuItem: View {
    var body: some View {
        Button { NSWorkspace.shared.open(AppLinks.repository) } label: { Text(verbatim: AppLinks.helpTitle) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 組み立て（最初に使われた時に作る。起動時に使う接続先を決めて取り直す）。役は `Entry` が決めた `LaunchContext.role`
    lazy var app = ViewerApp(role: LaunchContext.role)

    // 起動後: 複製なら、起動時の判定を診断・問いかけに出し、ログイン項目を確かめる（CDHash が変わっていれば登録し直す）。
    // Dock の表示・メニューバーの受け持ち・初回のガイド・裏での取り直し・メニューを開いた時の取り直しを始める（計画 2f-2）
    func applicationDidFinishLaunching(_ notification: Notification) {
        let atLogin = LaunchedAtLogin.detect()
        app.startup(LaunchContext.copyLaunch)
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] n in
            // メインメニューの中のメニューは除く（メニューバーの項目のメニューだけ。ほかの単独のメニューでも取り直すが、2 秒の間引きがある）
            guard let menu = n.object as? NSMenu, menu.supermenu == nil else { return }
            let opened = ObjectIdentifier(menu)
            MainActor.assumeIsolated {
                guard NSApp.mainMenu.map(ObjectIdentifier.init) != opened else { return }
                self?.app.menuOpened()
            }
        }
        // ログイン時に開かれた時は、主の窓を出さずにメニューバーにだけ出す（初回のガイドを出す時は除く）
        if atLogin, app.guide.flow == nil {
            DispatchQueue.main.async { NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix(WindowID.main) == true }.forEach { $0.close() } }
        }
    }
    // 取り除いた後なら、環境設定をもう一度消してから終わる。メニューバーの受け持ちの印を消す（Host がアイコンを出し直す）
    func applicationWillTerminate(_ notification: Notification) { app.willTerminate() }
    // 取り除いた後は窓の状態を保存しない（最終の点検）
    func applicationShouldSaveApplicationState(_ sender: NSApplication) -> Bool { !app.uninstall.didRemove }
    // 主の窓を閉じても終了しない（メニューバーに残る。計画 2f-2 案 1）。
    // ただし完全に削除した後は、最後の窓を閉じたら終了する（点検 2f-2。残っても使えないため）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { app.uninstall.didRemove }
    // Dock のアイコンをクリックした時、窓が無ければ主の窓を開く
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { app.router.openMain() }
        return true
    }
    // 前面に来たら帳簿を読み直し、状態を取り直す（直前に取得済みなら `ViewerModel` が省く）
    func applicationDidBecomeActive(_ notification: Notification) { app.becameActive() }
    // ディスプレイの抜き差し・蓋の開閉でカードを作り直す
    func applicationDidChangeScreenParameters(_ notification: Notification) { app.model.reloadDisplays() }
}

/// ログイン項目として開かれたか（開いた時の Apple Event の `keyAEPropData` が `keyAELaunchedAsLogInItem`）。
/// `SMAppService.mainApp` で開かれた時にも付くかは実機で確かめる（付かなければ、ふつうに開いた時と同じく主の窓が出るだけ）
enum LaunchedAtLogin {
    @MainActor static func detect() -> Bool {
        guard let e = NSAppleEventManager.shared().currentAppleEvent, e.eventClass == AEEventClass(kCoreEventClass),
              e.eventID == AEEventID(kAEOpenApplication) else { return false }
        return e.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}
