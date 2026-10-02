import AppKit
import CoreGraphics
import ShareScaleEngine
import ShareScaleHostCore
import ShareScaleProtocol

/// `HostRuntime` を持つ箱（`ChildProcessDisplayProvider` の `onUpdating` と画面構成の変化の C の呼び出しから、main を経ずに触るため）
final class RuntimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var r: HostRuntime?
    var runtime: HostRuntime? {
        get { lock.withLock { r } }
        set { lock.withLock { r = newValue } }
    }
}

/// 常駐の組み立て役（`NSApplicationDelegate`）: `HostRuntime` を作って `start` し、メニューバー・確認の窓・コードの窓・診断の窓・
/// host-control・画面構成の変化・スリープからの復帰をつなぐ。起動時の問題（読めないファイルなど）は終了せずにメニューと診断に出す。
/// 実行体のパスは `Bundle.main.executableURL` のまま使う（realpath にしない。`RENAME_SWAP` で同じパスの中身が新版に替わる設計のため）
@MainActor
public final class HostAppController: NSObject, NSApplicationDelegate, StatusMenuActions {
    public let language = HostLanguage.detect(Locale.preferredLanguages)
    public let identity = SelfIdentity.current()
    public let shortVersion: String
    public var versionText: String { "\(shortVersion) (\(identity.version))" }
    private let box = RuntimeBox()
    private var runtime: HostRuntime? { box.runtime }
    private var control: HostControlService?
    private lazy var menu = StatusMenu(entries: { [weak self] in self?.menuEntries() ?? [] })
    private lazy var approver = ApprovalWindowController(language: language)
    private lazy var codeWindow = CodeWindowController(language: language, onRevoke: { [weak self] in self?.revokeCode() })
    private lazy var diagnosticsWindow = DiagnosticsWindowController(language: language, reload: { [weak self] in self?.showDiagnostics() })
    private lazy var menuBarNotice = MenuBarNoticeWindowController(language: language)
    private var lastCode: CodePresentation?
    private var prefs = HostPreferences.load(from: HostPreferences.defaults())
    private let system = Locked(SystemDiagnostics())
    private var readingSystem = false, readSystemAgain = false
    private var startProblem: String?
    private var executable: URL { Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]) }
    /// メニューバーの受け持ちの印を読む場所（`host-control/`。計画 2f-2 案 2）
    private let controlFolder = HostControlFolder.standard()
    /// 印の pid の終了を見張る（ShareScale.app が落ちた時にすぐアイコンを出し直す）
    private var ownerExit: DispatchSourceProcess?
    private var watchedOwner: pid_t?
    private var iconTimer: Timer?

    public override init() {
        shortVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        menu.actions = self
        NSApp.mainMenu = makeEditMenu(language)   // ⌘C・⌘A を選択した文字に届ける（Host の窓の中だけ。メニューバーには出ない）
        // ShareScale.app が受け持っている間はアイコンを出さない（初回の知らせは、アイコンを出した時に 1 回だけ）。見張りは Host の組み立ての後に始める
        // （組み立ての前は Host が健全かを決められない。点検 2f-2）
        guard var c = HostRuntime.Configuration.standard() else {
            startProblem = language.t("この Mac の識別子を読み取れないため、起動できません", "Can’t start because this Mac’s identifier can’t be read")
            watchMenuBarOwner()   // 起動に失敗したので、アイコンを出す（メニューに理由を出す）
            return
        }
        c.tailscaleOnly = prefs.tailscaleOnly; c.allowGlobal = prefs.allowGlobal; c.port = UInt16(prefs.port)
        let box = box
        let displays = ChildProcessDisplayProvider(command: ChildArguments.command(executable: executable, version: identity.version, cdhash: identity.cdhash),
                                                   onUpdating: { box.runtime?.noteUpdating() })
        let r = HostRuntime(configuration: c, displays: displays, approver: approver,
                            onChange: { [weak self] in Task { @MainActor in self?.refresh() } })
        box.runtime = r
        r.start()
        if identity.cdhash == "0" { r.log.write("own CDHash unavailable (unsigned executable); children are matched by version only") }
        let system = system
        let svc = HostControlService(folder: .standard(), runtime: r, version: shortVersion, build: Int64(identity.version), system: { system.value },
                                     onShowCode: { [weak self] code in Task { @MainActor in self?.showIssued(code) } },
                                     // ShareScale.app のメニューの「接続コードを表示…」「診断…」（計画 2f-2）
                                     onShow: { [weak self] w in
                                         Task { @MainActor in
                                             switch w {
                                             case .currentCode: self?.showCode()
                                             case .diagnostics: self?.showDiagnostics()
                                             }
                                         }
                                     },
                                     onSetting: { [weak self] op, v in Task { @MainActor in self?.persist(op, v) } },
                                     onQuit: { Task { @MainActor in NSApp.terminate(nil) } },
                                     // state.json を書けなくなったら（ShareScale の「この Mac の接続先」の節が出ないので）アイコンを出す（点検 2f-2）
                                     onStateHealth: { [weak self] _ in Task { @MainActor in self?.updateIconVisibility() } })
        control = svc
        svc.start()
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(box).toOpaque())
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
            box.runtime?.didWake()
        }
        readSystemDiagnostics()
        refresh()
        watchMenuBarOwner()
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // アイコンを出した状態に戻して終わる（`NSStatusItem` の表示の状態が残っても、前の版に戻した時に消えたままにならないように。点検 2f-2）
        menu.isVisible = true
        codeWindow.clearClipboardIfUnchanged()
        control?.stop()
        runtime?.stop()
        runtime?.flushLog()
        return .terminateNow
    }

    /// メニューの項目（開くたびに `StatusMenu` が呼ぶ。残り時間・最終接続はその時点の値）
    private func menuEntries() -> [MenuEntry] {
        guard let r = runtime else {
            return [.status(startProblem ?? "…"), .separator, .quit(language.t("ShareScale Host を終了", "Quit ShareScale Host"))]
        }
        return MenuModel.build(diagnostics: r.diagnostics, pairings: r.pairings, code: r.currentCode, now: Date(), language: language)
    }

    /// 何か変わった（`HostRuntime.onChange` と操作の後。main）: 窓の整合（コードが消えたら閉じる・クリップボードを消す）と、`state.json` の予約
    func refresh() {
        guard let r = runtime else { return }
        if r.currentCode == nil, lastCode != nil {
            lastCode = nil
            codeWindow.close()
            codeWindow.clearClipboardIfUnchanged()
        }
        control?.noteChanged()
    }

    // ---- StatusMenuActions ----

    public func addViewer() {
        guard let r = runtime else { return }
        guard let code = r.issueCode() else {
            alert(language.t("接続コードを作成できません", "Can’t create a pairing code"),
                  language.t("接続元の Mac が上限の \(Limits.maxPairings) 台に達しているか、この Mac のアドレスが見つからないか、接続を受け付けていません。詳しくはメニューの「診断…」で確認できます。",
                             "The limit of \(Limits.maxPairings) Macs has been reached, this Mac’s address can’t be found, or connections aren’t being accepted. Choose Diagnostics… in the menu for details."))
            return
        }
        showIssued(code)
    }
    public func showCode() {
        guard runtime?.currentCode != nil, let p = lastCode else { return }
        codeWindow.show(p)
    }
    public func unpair(_ id: PairingID) {
        guard let r = runtime, let m = r.pairings[id] else { return }
        let name = language.displayName(m.name)
        let a = NSAlert()
        a.messageText = language.t("「\(name)」の登録を解除しますか？", "Remove “\(name)”?")
        a.informativeText = language.t("登録を解除すると、その Mac からはこの Mac に接続できなくなります。もう一度使うには、ペアリングし直してください。",
                                       "That Mac will no longer be able to connect to this Mac. To use it again, pair it again.")
        a.addButton(withTitle: language.t("登録を解除", "Remove")); a.addButton(withTitle: language.t("キャンセル", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        // 生のエラー文は出さない（DESIGN.md「文言」）。何をすればよいかだけを書く
        do { try r.unpair(id) } catch {
            alert(language.t("「\(name)」の登録を解除できませんでした", "Couldn’t remove “\(name)”"),
                  language.t("~/Library/Application Support/ShareScale/pairings/host/ のアクセス権を確認してから、もう一度試してください。",
                             "Check the permissions of ~/Library/Application Support/ShareScale/pairings/host/, then try again."))
        }
        refresh()
    }
    public func snooze(_ id: PairingID) { runtime?.snoozeNotice(id) }
    public func togglePause() {
        guard let r = runtime else { return }
        r.setPaused(!r.diagnostics.paused)
    }
    public func showDiagnostics() {
        guard let r = runtime else { return }
        diagnosticsWindow.show(DiagnosticsReport.items(host: r.diagnostics, system: system.value, pairings: r.pairings, version: versionText,
                                                       now: Date(), language: language))
        readSystemDiagnostics()   // 読み終えたら窓を書き直す
    }
    public func openLog() {
        let dir = HostLog.standardDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(dir)
    }
    public func quit() { NSApp.terminate(nil) }

    // ---- 内部 ----

    /// ShareScale.app がメニューバーを受け持っているかを見張り、アイコンを出し入れする（計画 2f-2 案 2）。見直すのは:
    /// ShareScale.app の起動・終了（`NSWorkspace` の知らせ。落ちた時も届く）、印の pid の終了（`DispatchSource` の process exit）、
    /// host-control の「読み直して」（ShareScale.app が印を書いた・消した後に送る）、保険に 30 秒ごと
    private func watchMenuBarOwner() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == BundleIdentifiers.app else { return }
                MainActor.assumeIsolated { self?.updateIconVisibility() }
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(HostControlFolder.notificationName), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateIconVisibility() }
        }
        iconTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateIconVisibility() }
        }
        updateIconVisibility()
    }

    /// 印を読み、アイコンを出すかを決める（`HostIconPolicy`）。隠す時は印の pid の終了を見張る。
    /// Host 自身が健全でない（起動に失敗した・`state.json` を書けていない）時は、ShareScale の節が出ないので印があっても出す（点検 2f-2）
    func updateIconVisibility() {
        let claim = controlFolder.readMenuBarClaim()
        // まだ 1 回も書こうとしていない間（起動の直後。最初の読み直しがすぐ書く）は健全とみなし、書けなかったと分かった時に出す
        let healthy = runtime != nil && control != nil && startProblem == nil && control?.stateHealth != false
        let show = HostIconPolicy.showsIcon(claim: claim, hostHealthy: healthy) { pid in
            HostIconPolicy.isShareScale(pid) { p in
                NSRunningApplication(processIdentifier: p).map { HostIconPolicy.RunningApp(bundleIdentifier: $0.bundleIdentifier, isTerminated: $0.isTerminated) }
            }
        }
        menu.isVisible = show
        if show {
            ownerExit?.cancel(); ownerExit = nil; watchedOwner = nil
            showMenuBarNoticeOnce()
        } else if let c = claim, let p = pid_t(exactly: c.pid), watchedOwner != p {
            // 見張りを作る前に pid が終わっていると、終了の知らせは届かないことがある（競走）。その時は `NSWorkspace` の終了の知らせか
            // 30 秒ごとの保険が拾う（`isShareScale` が偽になり、アイコンを出す）
            ownerExit?.cancel()
            let src = DispatchSource.makeProcessSource(identifier: p, eventMask: .exit, queue: .main)
            src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.updateIconVisibility() } }
            src.resume()
            ownerExit = src; watchedOwner = p
        }
    }

    /// 初回だけ「メニューバーで動作しています」を出す（出したら印を保存する。次からは出さない）。
    /// アイコンを出している時だけ呼ぶ（ShareScale.app が受け持っている間は、アイコンが無いので出さない）
    private func showMenuBarNoticeOnce() {
        guard !prefs.menuBarNoticeShown else { return }
        menuBarNotice.show()
        prefs.menuBarNoticeShown = true
        prefs.save(to: HostPreferences.defaults())
    }

    private func showIssued(_ code: PairingCode) {
        let p = CodePresentation(code, language: language)
        lastCode = p
        codeWindow.show(p)
        refresh()
    }
    private func revokeCode() {
        runtime?.revokeCode()
        lastCode = nil
        codeWindow.close()
        codeWindow.clearClipboardIfUnchanged()
        refresh()
    }
    private func persist(_ op: HostControlOp, _ v: Bool) {
        switch op {
        case .setTailscaleOnly: prefs.tailscaleOnly = v
        case .setAllowGlobal: prefs.allowGlobal = v
        default: return
        }
        prefs.save(to: HostPreferences.defaults())
    }
    /// ファイアウォール・FileVault・ログイン項目を裏で読む（`socketfilterfw` は数百ミリ秒）。読み終えたら診断の窓を書き直す。
    /// 読んでいる間にもう一度頼まれたら、終わってから 1 回だけ読み直す
    private func readSystemDiagnostics() {
        if readingSystem { readSystemAgain = true; return }
        readingSystem = true
        let exe = executable.path
        let bundle = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL.path : nil
        let system = system
        DispatchQueue.global(qos: .utility).async { [weak self] in
            system.value = SystemChecks.read(executable: exe, bundle: bundle)
            Task { @MainActor in
                guard let self else { return }
                self.readingSystem = false
                if let r = self.runtime {
                    self.diagnosticsWindow.update(DiagnosticsReport.items(host: r.diagnostics, system: system.value, pairings: r.pairings,
                                                                          version: self.versionText, now: Date(), language: self.language))
                }
                self.control?.noteChanged()
                if self.readSystemAgain { self.readSystemAgain = false; self.readSystemDiagnostics() }
            }
        }
    }
    private func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

/// 編集のメニュー（`EditMenuModel`）。`LSUIElement` のアプリはメニューバーを出さないが、主のメニューのキーは効くため、
/// ⌘C（`copy:`）・⌘A（`selectAll:`）を最前面の窓の選択した文字に届けるためだけに置く
@MainActor func makeEditMenu(_ L: HostLanguage) -> NSMenu {
    let main = NSMenu()
    let editItem = NSMenuItem(title: EditMenuModel.title(L), action: nil, keyEquivalent: "")
    let edit = NSMenu(title: EditMenuModel.title(L))
    for i in EditMenuModel.items(L) {
        edit.addItem(NSMenuItem(title: i.title, action: NSSelectorFromString(i.action), keyEquivalent: i.key))   // 対象は nil（選択している部品へ）
    }
    editItem.submenu = edit
    main.addItem(editItem)
    return main
}

/// 画面構成の変化（`CGDisplayRegisterReconfigurationCallback`）。始まりの知らせは飛ばし、終わりで判定を予定する
private func displayReconfigured(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo, !flags.contains(.beginConfigurationFlag) else { return }
    Unmanaged<RuntimeBox>.fromOpaque(userInfo).takeUnretainedValue().runtime?.displayConfigurationChanged()
}

/// ロックで守った値
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}
