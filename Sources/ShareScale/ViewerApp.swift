import AppKit
import Combine
import ColorSync
import Foundation
import ShareScaleCore
import ShareScaleHostCore
import ShareScaleProtocol
import ShareScaleUI
import SystemConfiguration

/// アプリ本体の組み立て（帳簿・`ViewerModel`・`ViewerTargets`・「この Mac の接続先」・接続先の追加の窓・ログイン項目・取り除き）
/// - 帳簿: `SecretStore(role: .viewer)`（`~/Library/Application Support/ShareScale/pairings/viewer/`）と `UserDefaults.standard`（`selectedTarget`）。
///   この Mac の識別子が読めなければ帳簿なしで動き、案内と診断に出す（終了しない）。読めないファイルも案内と診断に出す
/// - ディスプレイは `NSScreen`、選んだ倍率は `UserDefaults.standard`
/// - 名乗る名前は `SCDynamicStoreCopyComputerName`（`NameRules.validate` を通らなければ「Mac」）
/// - ログイン項目（`LoginItemController`）と取り除き（`UninstallFlow`）は役（複製・開発の組み立て）で押せるものが変わる（計画 2e-1）
@MainActor
final class ViewerApp: ObservableObject {
    let book: TargetBook?
    let model: ViewerModel
    let targets: ViewerTargets
    let host: HostPanelStore
    let role: AppRole
    let distribution: DistributionStatus
    let loginItems: LoginItemController
    let uninstall: UninstallFlow
    /// 変わった時の通知（既定はオフ。計画 2f-1 案 7）
    let notifications: ViewerNotifications
    /// 窓を開く口（メニューバー・Dock・ガイドから。計画 2f-2）
    let router = AppRouter()
    /// 初回のガイド（計画 2f-2 案 3）
    let guide: OnboardingGuide
    /// 「Dock に表示する」「ShareScale Host のアイコンを常に表示する」（計画 2f-2 案 1・2）
    let appearance: AppearanceSettings
    /// 「ログイン時に ShareScale を開く」（`SMAppService.mainApp`。複製だけ。計画 2f-2 案 1）
    let openAtLogin: OpenAtLoginController
    /// 裏での取り直し（通知のため。計画 2f-2）
    private var refresher: BackgroundRefresher?
    /// 常駐している間に新しい版を見つける（点検 2f-2。複製だけ）
    let updates: UpdateWatcher
    /// 眠りの様子（システムと画面を別々に持つ。眠っている間と戻った直後は裏で取り直さない。点検 2f-2）
    private var sleepState = SleepState()
    /// 開いている（または名乗りを進めている）追加の窓の中身。窓を閉じ、名乗りが終われば消える（弱い参照）
    private weak var adding: AddTargetModel?
    private var removal: AnyCancellable?
    private var yieldSink: AnyCancellable?

    init(role: AppRole, paths: AppPaths = .standard()) {
        self.role = role
        let defaults = UserDefaults.standard
        book = TargetBook.standard(settings: defaults)
        model = ViewerModel(client: nil, displays: ScreenDisplays.current,
                            vpnCheck: { await Task.detached { NetworkHints.checkDefaultRoute() }.value },
                            preferences: DisplayPreferences(store: defaults))
        let targets = ViewerTargets(book: book, model: model)
        self.targets = targets
        let notifications = ViewerNotifications(preferences: NotificationPreferences(store: defaults), poster: SystemNotificationPoster(),
                                                appActive: { NSApp.isActive })
        self.notifications = notifications
        model.onResult = { [weak notifications] in notifications?.handle($0) }
        let client = HostControlClient()
        host = HostPanelStore(client: client, appBuild: SelfIdentity.bundleVersion(),
                              hostProcessRunning: { NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentifiers.host).contains { !$0.isTerminated } })
        let distribution = DistributionStatus()
        self.distribution = distribution
        // app-state.json の実体は 1 つにする（読んで書き換えるを 1 つの鍵の中で行う点検 P の前提を、ログイン項目・ログイン時に開く・新しい版の 3 つの間でも守る。再点検 2f-2）
        let appStateFile = AppStateFile(url: paths.appState)
        let loginItems = LoginItemController(role: role, service: SystemLoginItemService(), stateFile: appStateFile,
                                             ownCDHash: SelfIdentity.codeHash(),
                                             hostPID: { if case let .running(s) = client.hostState() { return s.pid }; return nil },
                                             distribution: distribution,
                                             // 開発の組み立てから登録する前に、自分のバンドルの中の持ち主・権限を確かめる（点検 I）
                                             ownBundleProblem: {
                                                 let path = AppLocation.realPath(Bundle.main.bundlePath) ?? Bundle.main.bundlePath
                                                 return HandoffSafety.checkBundle(path, uid: geteuid(), reader: SystemFileFacts())
                                             },
                                             // 中に Host があるかはバンドルの中を見る（macOS 27 は登録前にも .notFound を返すため。計画 2f-1）
                                             hostEmbedded: { EmbeddedHost.isPresent(in: Bundle.main.bundleURL) })
        self.loginItems = loginItems
        let openAtLogin = OpenAtLoginController(role: role, service: SystemAppLoginItemService(), stateFile: appStateFile,
                                                ownCDHash: SelfIdentity.codeHash())
        self.openAtLogin = openAtLogin
        guide = OnboardingGuide(store: defaults)
        // 起動時の引き渡しと同じ判定を、前面に来た時・メニューを開いた時に（10 分に 1 回。ファイルを読むだけ）
        updates = UpdateWatcher(role: role, stateFile: appStateFile,
                                own: BundleFacts(identifier: Bundle.main.bundleIdentifier, version: SelfIdentity.bundleVersion(), cdhash: SelfIdentity.codeHash()),
                                safety: { HandoffSafety.check(bundle: $0, uid: geteuid(), reader: SystemFileFacts()) })
        uninstall = UninstallFlow(role: role, paths: paths, targets: targets, loginItems: loginItems, openAtLogin: openAtLogin) {
            // state.json が無い・古くても、Host の識別子のプロセスで確かめる（点検 A。組み立ては Core の `UninstallPorts.system`）
            UninstallPorts.system(client: client, unpair: { id in await targets.remove(id) },
                                  isRunning: { id in NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { !$0.isTerminated } })
        }
        // メニューバーの受け持ちの印（取り除いた後は書かない。`host-control/` を作り直さないため）と Dock の表示
        let keeper = MenuBarClaimKeeper(folder: .standard(), pid: Int64(getpid()))
        let uninstall = self.uninstall
        appearance = AppearanceSettings(preferences: AppearancePreferences(store: defaults),
                                        applyDock: { NSApp.setActivationPolicy($0 ? .regular : .accessory) },
                                        claim: { on in keeper.update(claim: on && !uninstall.didRemove) })
        // 起動時: 使う接続先を決める（決まれば `ViewerTargets` が画面に結び付かない Task で取り直す）
        targets.reload()
        // 取り除いた後は帳簿を読み直さず、相手も外す（点検 N）
        // 削除した時点で窓の復元の印も外す（`savedState` を作り直さない。AppDelegate の applicationShouldSaveApplicationState も偽を返す。最終の点検）
        // ShareScale だけが Host の状態を読めない間が 10 秒続いたら、受け持ちを外して Host にアイコンを戻させる（再点検 2f-2）
        yieldSink = host.$yieldsMenuBar.removeDuplicates().sink { [appearance] in appearance.setYieldToHost($0) }
        removal = uninstall.$didRemove.filter { $0 }.sink { [targets] _ in
            targets.freeze()
            NSApp.windows.forEach { $0.isRestorable = false }
        }
    }

    /// 終了の直前（⌘Q・メニューの「ShareScale を終了」・取り除きの窓の「終了」・取り除いた後に最後の窓を閉じる、のどれでも。点検 2f-2）: 取り除いた後なら、窓の復元の印を外し（`savedState` を作り直さない）、
    /// 終わるまでの間に書かれた環境設定をもう一度消す（点検 N・再点検 軽微 7）
    func willTerminate() {
        appearance.releaseAtQuit()   // Host がアイコンを出し直す（落ちた時は Host が pid の終了で気づく）
        guard uninstall.didRemove else { return }
        NSApp.windows.forEach { $0.isRestorable = false }
        for d in [AppIdentifiers.app, AppIdentifiers.host] { UserDefaults.standard.removePersistentDomain(forName: d) }
    }

    /// 起動後（複製・開発の組み立て）: 起動時の判定を診断と問いかけに出し、ログイン項目を確かめる（複製だけ。CDHash が変わっていれば登録し直す）
    func startup(_ launch: (decision: Handoff.CopyLaunch, stateProblem: String?)) {
        if let p = launch.stateProblem {
            distribution.set(.appState, ViewerDiagnostics.Line(.bad, tr("アップデートの情報: 読み取れません（\(p)）", "Update info: can’t be read (\(p))"),
                                                               advice: tr("~/Library/Application Support/ShareScale/app-state.json のアクセス権を確認してください（ファイル 600）。",
                                                                          "Check the permissions of ~/Library/Application Support/ShareScale/app-state.json (file 600).")))
        }
        switch launch.decision {
        case .nothing, .handoff: break
        case .askUninstall: uninstall.noteHomebrewRemoved()
        case .alreadyAttempted:
            distribution.set(.handoff, ViewerDiagnostics.Line(.bad, tr("アップデート: 失敗しました（Homebrew の新しいバージョンに切り替えられませんでした）", "Update: failed (couldn’t switch to the newer Homebrew version)"),
                                                              advice: tr("ターミナルで open \"$(brew --prefix)/opt/sharescale/ShareScale.app\" を実行してください。",
                                                                         "In Terminal, run open \"$(brew --prefix)/opt/sharescale/ShareScale.app\".")))
        case .unsafe:
            distribution.set(.handoff, ViewerDiagnostics.Line(.bad, tr("アップデート: 自動では置き換えません", "Update: not replaced automatically"), advice: HandoffSafety.message))
        case .unreadable:
            distribution.set(.handoff, ViewerDiagnostics.Line(.unknown, tr("アップデート: Homebrew の ShareScale のバージョンか署名を読み取れません", "Update: can’t read the version or signature of ShareScale in Homebrew")))
        case .notHomebrew:
            distribution.set(.handoff, ViewerDiagnostics.Line(.bad, tr("アップデート: 保存されているコピー元が Homebrew のフォルダではないため、開きません", "Update: the recorded source isn’t in the Homebrew folder, so it isn’t opened"),
                                                              advice: tr("ターミナルで open \"$(brew --prefix)/opt/sharescale/ShareScale.app\" を実行してください。",
                                                                         "In Terminal, run open \"$(brew --prefix)/opt/sharescale/ShareScale.app\".")))
        }
        Task { [loginItems, openAtLogin, host] in
            await loginItems.startup()
            await openAtLogin.startup()   // 更新の後は「ログイン時に開く」も登録し直す（点検 2f-2）
            host.reload()
        }
        // 計画 2f-2: Dock の表示とメニューバーの受け持ち、初回のガイド（接続先が 0 件・この Mac の接続先の役がオフ・見た印が無い）、裏での取り直し
        appearance.applyAtLaunch()
        guide.showIfNeeded(hasTargets: !targets.loaded.entries.isEmpty, hostRoleOn: loginItems.model.isOn || host.panel.hostIsRunning)
        watchSleep()
        let r = BackgroundRefresher(conditions: { [weak self] in
            guard let self else { return BackgroundRefreshPolicy.Conditions(notificationsOn: false, kinds: [], appActive: true, hasTarget: false, lastFailed: false) }
            return BackgroundRefreshPolicy.Conditions(notificationsOn: self.notifications.enabled, kinds: self.notifications.kinds, appActive: NSApp.isActive,
                                                      systemAsleep: self.sleepState.systemAsleep, screensAsleep: self.sleepState.screensAsleep,
                                                      wokeRecently: self.sleepState.wokeRecently(at: .now),
                                                      lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                                      hasTarget: self.model.hasTarget && !self.uninstall.didRemove,
                                                      lastFailed: self.model.connectionFailure != nil)
        }, refresh: { [weak self] in await self?.model.refresh() })
        refresher = r
        r.start()
    }

    /// スリープ・画面のスリープの間と、戻った直後（60 秒）は裏で取り直さない
    private func watchSleep() {
        let ws = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, SleepState.Event)] = [(NSWorkspace.willSleepNotification, .willSleep), (NSWorkspace.didWakeNotification, .didWake),
                                                              (NSWorkspace.screensDidSleepNotification, .screensDidSleep),
                                                              (NSWorkspace.screensDidWakeNotification, .screensDidWake)]
        for (name, event) in events {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sleepState.handle(event, at: .now) }
            }
        }
    }

    /// 前面に来た: 帳簿を読み直し（ほかの窓での追加・削除）、状態を取り直す。この Mac の Host の様子も読み直す（主の窓の案内の 1 行のため。`state.json` を読むだけ）。
    /// ログイン項目の状態も読み直す（システム設定で変えて戻ってきた時に、古い知らせを消すため。計画 2f-2）
    func becameActive() {
        guard !uninstall.didRemove else { return }
        targets.reload()
        host.reload()
        loginItems.refresh()
        openAtLogin.refresh()
        Task { await model.refresh() }
        Task { await updates.check() }
    }

    /// 「ShareScale を終了して開き直す…」: 起動時の引き渡しと同じく、試みを記録してから Homebrew 側を開き、自分は終了する（点検 2f-2）
    func startUpdate() {
        Task { await updates.handoff(open: { LaunchFlow.open($0) }, terminate: { NSApp.terminate(nil) }) }
    }

    /// メニューバーのメニューを開いた: 帳簿と Host の様子を読み直し（小さなファイルを読むだけで、間引かない）、
    /// 項目を今の時刻で作り直させ（残り時間）、状態を取り直す（取り直しは `ViewerModel.refresh` の 2 秒の間引きつき。計画 2f-2 案 1・点検）
    func menuOpened() {
        guard !uninstall.didRemove else { return }
        targets.reload()
        host.reload()
        router.noteMenuOpened()
        Task { await updates.check() }
        Task { await model.refresh() }
    }

    /// 接続先の追加の窓の中身を作る（窓を開くたびに新しく）。同時に 1 つだけ: 開いている・名乗りを進めている間は、その窓を前面に出す
    /// （主の窓と設定のどちらで開いていても。出せなければ押した側が「追加の窓はすでに開いています」を出す）
    func makeAddTarget() -> AddTargetOpening {
        if uninstall.didRemove { return .unavailable }
        if let current = adding {
            if AddTargetWindows.bringToFront(current) { return .shownExisting }
            // 窓は閉じたが名乗りを進めている（やめている途中を含む）間だけ断る。閉じた直後に中身がまだ残っているだけなら新しく開く
            if current.flow.isRunning { return .alreadyOpen }
        }
        guard let book else { return .unavailable }
        let targets = self.targets
        let m = AddTargetModel(runner: AddTargetModel.runner(book: book, computerName: { ComputerName.current() }),
                               pasteboard: SystemPasteboard(),
                               names: { targets.name(of: $0) },
                               onFinish: { targets.pairingFinished($0) })
        adding = m
        return .open(m)
    }
}

/// この Mac の名前（名乗りに使う）
enum ComputerName {
    static func current() -> String {
        let raw = SCDynamicStoreCopyComputerName(nil, nil) as String?
        return raw.flatMap(NameRules.validate) ?? "Mac"
    }
}

/// 版の表示（`CFBundleShortVersionString` とコミット）。バンドルの外（`swift run`）の開発用の組み立てではリポジトリの `VERSION`。
/// その予備は `#if DEBUG` の中だけ（release の実行体に、組み立てた場所の絶対パス（`#filePath`）を入れないため）
enum AppInfo {
    static let version: String = {
        let info = Bundle.main.infoDictionary
        if let v = info?["CFBundleShortVersionString"] as? String {
            if let c = info?["ShareScaleCommit"] as? String, !c.isEmpty { return "\(v) (\(c))" }
            return v
        }
        #if DEBUG
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try? String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
        return text.flatMap { AppVersion($0)?.shortString }.map { "\($0) (dev)" } ?? "dev"
        #else
        return "unknown"
        #endif
    }()
}

/// NSScreen から見る側のディスプレイ一覧を作る
enum ScreenDisplays {
    static func current() -> [LocalDisplay] {
        NSScreen.screens.compactMap { screen -> LocalDisplay? in
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(num.uint32Value)
            let scale = Double(screen.backingScaleFactor)
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
            return LocalDisplay(id: id, name: screen.localizedName,
                                pixels: Resolution(width: Int(screen.frame.width * scale), height: Int(screen.frame.height * scale)),
                                backingScale: scale, isBuiltIn: CGDisplayIsBuiltin(id) != 0, uuid: uuid)
        }
        .sorted { !$0.isBuiltIn && $1.isBuiltIn }  // 外部ディスプレイを先に
    }
}
