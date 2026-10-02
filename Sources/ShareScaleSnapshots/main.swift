// 偽のデータで見る側の各画面と Host の窓（初回の知らせ・コードの窓・確認の窓）を PNG に書き出す（`ImageRenderer` だけを使い、窓は出さない）。
// Host のメニュー（`NSMenu` は描けない）は、項目の文言を `50-host-menu-<言語>.txt` に書き出す。
// 設定のタブの高さ（`ScrollView` の中身は描けない）は、数を `62-settings-heights-<言語>.txt` に書き出す（計画 2h）。
//   swift run ShareScaleSnapshots [出力先フォルダ]   （省略時は $TMPDIR/sharescale-snapshots）
// 通信・保管・クリップボードには触れない（接続先は結果を固定した偽物、帳簿は記憶の中の値）。
// 注意: `ImageRenderer` は AppKit の部品（切り替えのセグメント・入力欄・スイッチ・メニュー・貼り付けボタンなど）を描かず、代わりの印を描く。
// それらの見た目は利用者が実機で確かめる（計画 2d-2「利用者が実機で確かめること」）
import AppKit
import ShareScaleCore
import ShareScaleHostCore
import ShareScaleHostUI
import ShareScaleProtocol
import ShareScaleUI
import SwiftUI

/// 結果を固定した接続先。`hang` なら 2 回目からの問い合わせは戻らない（処理中の見た目を書き出すため）。
/// `refusal` があれば、`set` はその失敗で断る（一時停止の間に倍率を選んだ時の見た目を書き出すため。計画 2i）
final class FixedTarget: TargetControlling, @unchecked Sendable {
    let result: Result<RemoteState, ViewerFailure>
    let hang: Bool
    let refusal: ViewerFailure?
    private let lock = NSLock()
    private var calls = 0
    init(_ result: Result<RemoteState, ViewerFailure>, hang: Bool = false, refusal: ViewerFailure? = nil) { self.result = result; self.hang = hang; self.refusal = refusal }
    func status() async -> Result<RemoteState, ViewerFailure> {
        let n = lock.withLock { calls += 1; return calls }
        if hang, n > 1 { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
        return result
    }
    func set(_ mode: DisplayMode) async -> Result<RemoteState, ViewerFailure> {
        if let refusal { return .failure(refusal) }
        return await status()
    }
}

let lg = LocalDisplay(id: 1, name: "LG ULTRAWIDE", pixels: Resolution(width: 2560, height: 1080), backingScale: 1, isBuiltIn: false)
let builtIn = LocalDisplay(id: 2, name: "内蔵Retinaディスプレイ", pixels: Resolution(width: 3024, height: 1964), backingScale: 2, isBuiltIn: true)

func state(session: Bool = true, mode: Mode = .oneX, scaling: StatusPayload.VirtualDisplay.Scaling = .oneX, vd: Bool = true, paused: Bool = false,
           lastError: String? = nil, name: String = "居間のMac Studio", model: String = "Mac Studio", setByOther: Bool = false) -> RemoteState {
    RemoteState(StatusPayload(name: name, model: model, paused: paused, session: session, mode: mode,
                              virtualDisplay: vd ? StatusPayload.VirtualDisplay(resolution: "1920x997", scaling: scaling, source: .signature) : nil,
                              ambiguous: false, lastError: lastError, setBy: setByOther ? StatusPayload.SetBy(byYou: false, at: 1_800_000_000) : nil,
                              port: 47651, addresses: ["studio.local"])!)
}

func pairingID(_ n: UInt8) -> PairingID { PairingID(bytes: [UInt8](repeating: n, count: 16))! }
func entry(_ n: UInt8, _ name: String, confirmed: Bool = true, manual: Bool = false, last: String? = "studio.local",
           addrs: [String] = ["studio.local", "100.101.1.2"], alias: String? = nil) -> TargetEntry {
    TargetEntry(id: pairingID(n), secret: Bytes32(Data(repeating: n, count: 32))!,
                meta: ViewerMeta(name: name, port: 47651, addresses: addrs, manual: manual, lastOKAddress: last, confirmed: confirmed, alias: alias)!)
}
let book: TargetBook.Loaded = {
    var l = TargetBook.Loaded()
    l.entries = [entry(1, "居間のMac Studio"), entry(2, "居間の Mac mini", confirmed: false, manual: true, last: nil, addrs: ["192.168.1.20"]),
                 entry(3, "書斎の MacBook Pro", last: "100.101.1.3", addrs: ["mbp.local", "100.101.1.3"], alias: "仕事用 MacBook Pro")]
    return l
}()

/// Host が書く形の `state.json`（試験の `stateJSON` と同じ形）
func hostSummary(paused: Bool = false, listener: String = #"{"status":"listening","port":47651}"#, code: Int64? = nil,
                 fileVault: Bool = true, firewall: String = "allowed", tailscaleOnly: Bool = false, allowGlobal: Bool = false,
                 manyViewers: Bool = false) -> HostControlState.Summary {
    let now = Int64(Date().timeIntervalSince1970)
    // 接続元の Mac が 32 台（上限）の時（計画 2h: 設定のタブの高さ）
    let many = (0..<32).map { n in #"{"id":"\#(pairingID(UInt8(40 + n)).hex)","name":"Mac \#(n + 1)","last_seen":\#(now - Int64(n) * 86_400),"confirmed":true,"stale":false}"# }
    let pairings = manyViewers ? many : [#"{"id":"\#(pairingID(4).hex)","name":"書斎の MacBook Air","last_seen":\#(now - 3600),"confirmed":true,"stale":false}"#,
                    #"{"id":"\#(pairingID(5).hex)","name":"古い iMac","last_seen":\#(now - 85 * 86_400),"confirmed":true,"stale":true}"#,
                    #"{"id":"\#(pairingID(6).hex)","name":"新しい MacBook","last_seen":null,"confirmed":false,"stale":false}"#]
    let codePart = code.map { #","code":{"expires":\#($0)}"# } ?? ""
    let json = #"{"format":1,"pid":1,"version":"1.1.0","build":10100,"running":true,"paused":\#(paused),"listener":\#(listener),"pairings":[\#(pairings.joined(separator: ","))]\#(codePart),"diagnostics":{"tailscale_only":\#(tailscaleOnly),"allow_global":\#(allowGlobal),"tailscale":"found","updating":false,"contention":false,"last_error":null,"store_problems":0,"engine_problem":null,"log_problem":null,"rejected_global_24h":0,"pairing_count":\#(manyViewers ? 32 : 3),"firewall":"\#(firewall)","filevault":\#(fileVault),"login_item":"not_found"},"updated":\#(now)}"#
    return HostControlState.decode(Data(json.utf8))!
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
                 ?? FileManager.default.temporaryDirectory.appendingPathComponent("sharescale-snapshots").path)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

@MainActor func save(_ view: some View, _ file: String, _ scheme: ColorScheme) {
    NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    let r = ImageRenderer(content: view.environment(\.colorScheme, scheme))
    r.scale = 2
    guard let img = r.nsImage, let tiff = img.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
        print("失敗: \(file)"); return
    }
    try? png.write(to: outDir.appendingPathComponent(file))
    print(file)
}

/// 主の窓（偽の接続先で 1 回取り直した後の姿）。`refusal` があれば、その後に 2x を選んで断られた姿（計画 2i）
@MainActor func mainWindow(_ result: Result<RemoteState, ViewerFailure>?, displays: [LocalDisplay] = [lg, builtIn], unconfirmed: Bool = false,
                           rows: [TargetRow] = TargetRow.rows(book, selectedID: pairingID(1)), storeNotice: ViewerNotice.Text? = nil,
                           busy: Bool = false, canAdd: Bool = true, addNote: String = "", hostRunningHere: Bool = false, update: Bool = false, updateFailed: Bool = false,
                           label: String = "居間のMac Studio", refusal: ViewerFailure? = nil) async -> some View {
    let target = result.map { FixedTarget($0, hang: busy, refusal: refusal) }
    let vm = ViewerModel(client: target, displays: { displays }, targetLabel: label, unconfirmed: unconfirmed)
    await vm.refresh()
    if refusal != nil { await vm.apply(.x2) }
    if busy {
        Task { await vm.refresh(force: true) }
        while !vm.busy { await Task.yield() }
    }
    return MainContent(model: vm, targets: result == nil ? [] : rows, storeNotice: storeNotice, canAddTarget: canAdd, addNote: addNote,
                       hostRunningHere: hostRunningHere, version: "1.1.0",
                       onSelectTarget: { _ in }, onAddTarget: {}, onDiagnostics: {},
                       update: updateFailed ? UpdateWatcher.failureText : (update ? UpdateWatcher.noticeText : nil),
                       updateFailed: updateFailed, canUpdate: !updateFailed)
}

/// 幅 560（設定の窓）に置いた時の、最小・理想・最大の高さ（窓は出さない。`NSHostingController` に聞くだけ）
@MainActor func heightsOf(_ view: some View) -> (min: CGFloat, ideal: CGFloat, max: CGFloat) {
    let framed = view.frame(width: 560)
    let c = NSHostingController(rootView: framed)
    return (c.sizeThatFits(in: NSSize(width: 560, height: 0)).height, NSHostingView(rootView: framed).fittingSize.height,
            c.sizeThatFits(in: NSSize(width: 560, height: 100_000)).height)
}

/// 接続先の追加の窓の各段
func addFlow(_ build: (inout AddTargetFlow) -> Void) -> AddTargetFlow { var f = AddTargetFlow(); build(&f); return f }
let sampleCode = PairingCode(id: pairingID(7), secret: Bytes32(Data(repeating: 7, count: 32))!, port: 47651,
                             addresses: ["studio.local", "100.101.1.2"], expiresAt: 1_800_000_000)!.encoded()
let sampleKey = ManualEntry.encodeKey(id: pairingID(7), secret: Bytes32(Data(repeating: 7, count: 32))!)
func running(_ f: inout AddTargetFlow) -> Int { f.code = sampleCode; return f.start()!.run }
@MainActor func addForm(_ flow: AddTargetFlow, expiry: String? = nil) -> some View {
    AddTargetForm(flow: flow, tab: .constant(flow.tab), code: .constant(flow.code), address: .constant(flow.address), key: .constant(flow.key),
                  expiryWarning: expiry, onPaste: { _ in }, onStart: {}, onCancel: {}, onRetry: {}, onClose: {})
}

@MainActor func settings(_ content: some View) -> some View {
    content.frame(width: 560).background(Color(nsColor: .windowBackgroundColor))
}

/// ログイン項目の状態を固定した口（登録・解除はしない）
struct FixedLoginItem: LoginItemService {
    let value: LoginItemStatus
    func status() -> LoginItemStatus { value }
    func register() throws {}
    func unregister() throws {}
    func openSystemSettingsLoginItems() {}
}
/// 「この Mac を接続先にする」の表示（`LoginItemController.model` から。書き込まない一時の置き場所）
@MainActor func hostSwitch(_ status: LoginItemStatus, role: AppRole = .copy) -> HostSwitchModel {
    LoginItemController(role: role, service: FixedLoginItem(value: status),
                        stateFile: AppStateFile(url: FileManager.default.temporaryDirectory.appendingPathComponent("sharescale-snapshots-app-state.json")),
                        ownCDHash: nil, hostPID: { nil }, hostEmbedded: { true }).model   // 書き出しは中に Host がある形
}
func report(_ change: (inout UninstallReport) -> Void) -> UninstallReport { var r = UninstallReport(); change(&r); return r }

/// 許可の状態を固定した通知の口（許可を求めない・送らない）
struct FixedPoster: NotificationPosting {
    let value: NotificationAuthorization
    func authorization() async -> NotificationAuthorization { value }
    func requestAuthorization() async -> Bool { value == .authorized }
    func post(_ n: PlannedNotification) async {}
}
/// 「通知」の表示（記憶の中の環境設定で。`turnOn` なら 1 つだけ外した状態でオンにする）
@MainActor func notificationSettings(_ a: NotificationAuthorization, turnOn: Bool = false) async -> NotificationSettingsModel {
    let n = ViewerNotifications(preferences: NotificationPreferences(store: InMemoryStringStore()), poster: FixedPoster(value: a), appActive: { false })
    await n.refreshAuthorization()
    if turnOn { await n.setEnabled(true); n.setKind(.changedByOther, false) }
    return n.model
}

/// 初回のガイドの各段（計画 2f-2 案 3）。`goal` を選び、`steps` 回「次へ」を押した姿
func onboardingFlow(_ goal: OnboardingFlow.Goal?, steps: Int = 0) -> OnboardingFlow {
    var f = OnboardingFlow()
    if let goal { f.choose(goal) }
    for _ in 0..<steps { _ = f.next(hostRunning: true) }
    return f
}
let onboardingCases: [(file: String, flow: OnboardingFlow, running: Bool, login: LoginItemStatus)] = [
    ("70-onboarding-choose", onboardingFlow(nil), false, .notRegistered),
    ("71-onboarding-a-add-target", onboardingFlow(.connectFrom), false, .notRegistered),
    ("72-onboarding-c-host-switch-off", onboardingFlow(.both), false, .notRegistered),
    ("73-onboarding-c-host-switch-running", onboardingFlow(.both), true, .enabled),
    ("74-onboarding-c-host-code", onboardingFlow(.both, steps: 1), true, .enabled),
    ("75-onboarding-c-add-target", onboardingFlow(.both, steps: 2), true, .enabled),
    ("76-onboarding-b-host-code", onboardingFlow(.beTarget, steps: 1), true, .enabled),
]
@MainActor func onboardingPage(_ c: (file: String, flow: OnboardingFlow, running: Bool, login: LoginItemStatus)) -> OnboardingPage {
    OnboardingPage.make(c.flow, hostRunning: c.running, canAddTarget: true, issueCode: (tr("接続元の Mac を追加…", "Add a Mac to Connect From…"), true))
}

/// メニューバーのメニューの文字の一覧（`NSMenu` は描けないので。計画 2f-2 案 1・2）
func menuText(_ items: [ViewerMenuItem]) -> String {
    items.flatMap { i -> [String] in
        switch i {
        case let .target(name, symbol): return ["[\(symbol)] \(name)"]
        case let .status(symbol, text): return ["(\(symbol)) \(text)"]
        case let .note(t): return [t]
        case let .addTarget(t, on): return [t + (on ? "" : "（押せない）")]
        case let .display(_, title, choices):
            return ["【\(title)】"] + choices.map { "  " + ($0.checked ? "✓ " : "   ") + $0.title + ($0.enabled ? "" : "（押せない）") }
        case let .refresh(t, on): return [t + (on ? "" : "（押せない）")]
        case let .switchTarget(t, choices): return [t + " ›"] + choices.map { "    " + ($0.checked ? "✓ " : "   ") + $0.title }
        case let .openMain(t): return [t]
        case let .settings(t): return [t + "    ⌘,"]
        case let .host(title, entries, settings):
            return ["【\(title)】"] + entries.map { e -> String in
                switch e {
                case let .status(s), let .notice(s), let .diagnostics(s), let .openLog(s), let .quit(s): return "  " + s
                case let .addViewer(t, on): return "  " + t + (on ? "" : "（押せない）")
                case let .showCode(t), let .pause(t, _), let .reviewViewers(t): return "  " + t
                case let .viewer(_, t, _, _, _, _): return "  " + t
                case .separator: return "  ────────"
                }
            } + ["  " + settings]
        case let .quit(t): return [t + "    ⌘Q"]
        case let .update(note, action): return [note, action]
        case .separator: return ["────────"]
        }
    }.joined(separator: "\n")
}

/// 設定 › 一般（計画 2f-2: 「はじめに…」・メニューバーと Dock・ログイン時に開く。記憶の中の環境設定、登録はしない）
@MainActor func general(_ n: NotificationSettingsModel, uninstallAvailable: Bool = true, role: AppRole = .copy, openAtLogin: LoginItemStatus = .notRegistered,
                        dock: Bool = true, hostIcon: Bool = false) -> some View {
    let a = AppearanceSettings(preferences: AppearancePreferences(store: InMemoryStringStore()), applyDock: { _ in }, claim: { _ in })
    if !dock { a.setShowsInDock(false) }
    if hostIcon { a.setHostIconAlwaysVisible(true) }
    return settings(GeneralSettings(version: "1.1.0 (abc1234)", uninstallAvailable: uninstallAvailable,
                                    uninstallNote: uninstallAvailable ? UninstallFlow.availableNote : UninstallFlow.unavailableNote, notifications: n,
                                    appearance: a.model, openAtLogin: OpenAtLoginController(role: role, service: FixedLoginItem(value: openAtLogin)).model,
                                    onToggleNotifications: { _ in }, onNotificationKind: { _, _ in }, onOpenNotificationSettings: {},
                                    onShowsInDock: { _ in }, onHostIconAlwaysVisible: { _ in }, onOpenAtLogin: { _ in }, onOpenLoginItems: {}, onGuide: {},
                                    onUninstall: {}))
}

@MainActor func render() async {
    for lang in [AppLanguage.ja, .en] {
        AppLanguage.current = lang
        let l = lang == .ja ? "ja" : "en"
        for scheme in [ColorScheme.light, .dark] {
            let s = scheme == .dark ? "dark" : "light"
            func name(_ base: String) -> String { "\(base)-\(s)-\(l).png" }
            // 主の窓
            save(await mainWindow(.success(state())), name("01-main-connected-1x"), scheme)
            save(await mainWindow(.success(state(mode: .twoX, scaling: .twoX))), name("02-main-connected-2x"), scheme)
            save(await mainWindow(nil), name("03-main-no-target"), scheme)
            save(await mainWindow(nil, hostRunningHere: true), name("03b-main-no-target-host-here"), scheme)
            save(await mainWindow(.failure(.unreachable)), name("04-main-unreachable"), scheme)
            save(await mainWindow(.failure(.localNetworkDenied)), name("05-main-local-network-denied"), scheme)
            save(await mainWindow(.failure(.unreachable), unconfirmed: true), name("06-main-unconfirmed"), scheme)
            save(await mainWindow(.success(state(paused: true))), name("07-main-paused"), scheme)
            // 計画 2i: 一時停止の間に 2x を選んで断られた（直前の状態は、一時停止の前のもの）。バッジは「接続中」のまま・案内は一時停止・フッタは「一時停止中」
            save(await mainWindow(.success(state()), refusal: .paused), name("07b-main-paused-refused"), scheme)
            save(await mainWindow(.success(state()), refusal: .busy), name("07c-main-busy-refused"), scheme)
            save(await mainWindow(.success(state()), busy: true), name("08-main-busy"), scheme)
            save(await mainWindow(.success(state(session: false, vd: false)), displays: [lg], rows: []), name("09-main-single-target-not-sharing"), scheme)
            // 計画 2f-1 案 4: ほかの Mac が 2x を選び、この Mac の 2 つのディスプレイで違う倍率を選んでいる
            save(await mainWindow(.success(state(session: false, mode: .twoX, vd: false, setByOther: true)), rows: []), name("09b-main-not-sharing-set-by-other"), scheme)
            save(await mainWindow(.success(state(session: false, mode: .off, vd: false)), displays: [lg], rows: []), name("09c-main-not-sharing-auto-off"), scheme)
            let noBook = ViewerTargets(book: nil, model: ViewerModel(client: nil, displays: { [lg] }), onSwitch: { _ in })
            save(await mainWindow(nil, storeNotice: noBook.storeNotice, canAdd: noBook.canAdd, addNote: noBook.addNote),
                 name("10-main-store-unavailable"), scheme)
            let longName = "とても長い名前の Mac Studio（3 階の書斎の机の左側に置いてあるもの）"
            save(await mainWindow(.success(state(name: longName)), rows: [], label: longName), name("11-main-long-target-name"), scheme)
            save(await mainWindow(.success(state(name: longName)), label: longName), name("12-main-long-target-name-menu"), scheme)
            // 常駐中に新しい版を見つけた（点検 2f-2）
            save(await mainWindow(.success(state()), update: true), name("13-main-update-available"), scheme)
            // 押した時に確かめ直して切り替えられなかった（再点検 2f-2）
            save(await mainWindow(.success(state()), updateFailed: true), name("13b-main-update-failed"), scheme)
            // 接続先の追加の窓
            save(addForm(addFlow { $0.code = sampleCode }, expiry: AddTargetText.expiryWarning), name("20-add-code-expired"), scheme)
            save(addForm(addFlow { $0.code = "sharescale1:abc" }), name("21-add-code-invalid"), scheme)
            save(addForm(addFlow { $0.tab = .manual; $0.address = "studio.local"; $0.key = String(sampleKey.prefix(30)) }), name("22-add-manual"), scheme)
            save(addForm(addFlow { _ = running(&$0) }), name("23-add-connecting"), scheme)
            save(addForm(addFlow { let r = running(&$0); $0.receive(.awaitingApproval(code: 12_345), run: r) }), name("24-add-confirmation-number"), scheme)
            save(addForm(addFlow { let r = running(&$0); $0.receive(.confirming(attempt: 2), run: r) }), name("25-add-confirming"), scheme)
            save(addForm(addFlow { let r = running(&$0); $0.finish(.success(.confirmed(pairingID(7))), run: r, name: "居間のMac Studio") }), name("26-add-confirmed"), scheme)
            save(addForm(addFlow { let r = running(&$0); $0.finish(.success(.unconfirmed(pairingID(7), reason: "status failed: timedOut")), run: r, name: "居間のMac Studio") }),
                 name("27-add-unconfirmed"), scheme)
            save(addForm(addFlow { let r = running(&$0); $0.receive(.confirming(attempt: 1), run: r); _ = $0.cancel()
                                   $0.finish(.failure(.cancelled), run: r, name: "居間のMac Studio", saved: pairingID(7)) }),
                 name("27b-add-cancelled-after-save"), scheme)
            save(addForm(addFlow { let r = running(&$0); $0.finish(.failure(.pairing(.notPaired)), run: r, name: nil) }), name("28-add-declined"), scheme)
            save(addForm(addFlow { let r = running(&$0); $0.finish(.failure(.connection(.handshakeFailed(othersUnreachable: false))), run: r, name: nil) }),
                 name("29-add-code-used"), scheme)
            // 計画 2i: 届かない（接続先でファイアウォールの確認が出ている間など）。確認することに、ファイアウォールの手がかり
            save(addForm(addFlow { let r = running(&$0); $0.finish(.failure(.connection(.unreachable)), run: r, name: nil) }), name("29b-add-unreachable"), scheme)
            // 設定
            let note = tr("接続先は 32 台まで登録できます。", "You can add up to 32 targets.")
            save(settings(TargetsSettingsContent(rows: TargetRow.rows(book, selectedID: pairingID(1)), storeNotice: nil, canAdd: true, addNote: note, removal: nil, busyIDs: [],
                                                 onAdd: {}, onEdit: { _ in }, onRemove: { _ in }, onRename: { _ in })), name("30-settings-targets"), scheme)
            save(settings(TargetsSettingsContent(rows: TargetRow.rows(book, selectedID: pairingID(1)), storeNotice: nil, canAdd: true, addNote: note,
                                                 removal: .removedLocally(name: "古い Mac"), busyIDs: [pairingID(3)],
                                                 onAdd: {}, onEdit: { _ in }, onRemove: { _ in }, onRename: { _ in })), name("31-settings-targets-removed-locally"), scheme)
            // シートは地の色を持たない（実際には窓の地の上に出る）ので、書き出しでは窓の地を敷く（明るい配色で透明の地が黒く写っていた）
            save(CandidatesSheet(name: "居間の Mac mini", editor: ManualCandidatesEditor(book.entries[1].meta), onSave: { _ in })
                    .background(Color(nsColor: .windowBackgroundColor)), name("32-settings-candidates"), scheme)
            // 名前の変更（計画 2f-1 案 6）
            save(RenameTargetSheet(row: TargetRow(book.entries[2], selected: false), onSave: { _ in })
                    .background(Color(nsColor: .windowBackgroundColor)), name("32b-settings-rename"), scheme)
            let now = Int64(Date().timeIntervalSince1970)
            save(settings(HostSettingsContent(panel: HostPanelModel.make(.running(hostSummary(code: now + 421, fileVault: false)), now: now, appBuild: 10100),
                                              hostSwitch: hostSwitch(.enabled),
                                              actionMessage: HostPanelModel.sentMessage(.issueCode), actionFailed: false, actionDetail: nil, onAction: { _ in },
                                              onToggleHost: { _ in }, onOpenLoginItems: {}, onOpenSettings: { _ in })),
                 name("33-settings-host-running"), scheme)
            // 受け付けの行の 3 つの状態（計画 2h。33 は既定）: 「インターネットからも」がオン・「Tailscale だけ」がオン
            for (file, summary) in [("33b-settings-host-internet", hostSummary(allowGlobal: true)), ("33c-settings-host-tailscale-only", hostSummary(tailscaleOnly: true)),
                                    ("33d-settings-host-32-macs", hostSummary(manyViewers: true))] {
                save(settings(HostSettingsContent(panel: HostPanelModel.make(.running(summary), now: now, appBuild: 10100), hostSwitch: hostSwitch(.enabled),
                                                  actionMessage: nil, actionFailed: false, actionDetail: nil, onAction: { _ in },
                                                  onToggleHost: { _ in }, onOpenLoginItems: {}, onOpenSettings: { _ in })), name(file), scheme)
            }
            save(settings(HostSettingsContent(panel: HostPanelModel.make(.running(hostSummary(paused: true, firewall: "blocked")), now: now, appBuild: 10200),
                                              hostSwitch: hostSwitch(.enabled), actionMessage: nil, actionFailed: false, actionDetail: nil, onAction: { _ in },
                                              onToggleHost: { _ in }, onOpenLoginItems: {}, onOpenSettings: { _ in })), name("34-settings-host-paused-older-host"), scheme)
            save(settings(HostSettingsContent(panel: HostPanelModel.make(.notRunning(last: nil), now: now), hostSwitch: hostSwitch(.notRegistered),
                                              actionMessage: HostPanelModel.notRunningAction, actionFailed: true,
                                              actionDetail: nil, onAction: { _ in }, onToggleHost: { _ in }, onOpenLoginItems: {}, onOpenSettings: { _ in })),
                 name("35-settings-host-not-running"), scheme)
            save(settings(HostSettingsContent(panel: HostPanelModel.make(.unknown(problem: "state.json: permissions"), now: now), hostSwitch: hostSwitch(.enabled, role: .development),
                                              actionMessage: nil, actionFailed: false,
                                              actionDetail: nil, onAction: { _ in }, onToggleHost: { _ in }, onOpenLoginItems: {}, onOpenSettings: { _ in })), name("36-settings-host-unknown-dev"), scheme)
            // ログイン項目がオフ: スイッチの下の説明だけ（結果の一言は同じ手順を言うので出さない。計画 2f-1）
            let approval = hostSwitch(.requiresApproval)
            save(settings(HostSettingsContent(panel: HostPanelModel.make(.notRunning(last: hostSummary()), now: now), hostSwitch: approval,
                                              actionMessage: nil, actionFailed: false, actionDetail: nil, onAction: { _ in }, onToggleHost: { _ in }, onOpenLoginItems: {},
                                              onOpenSettings: { _ in })),
                 name("38-settings-host-requires-approval"), scheme)
            save(general(await notificationSettings(.notDetermined)), name("37-settings-general"), scheme)
            save(general(await notificationSettings(.unavailable), uninstallAvailable: false, role: .development), name("39-settings-general-dev"), scheme)
            // 通知（計画 2f-1 案 7）: オン（1 つだけ外した）・許可されなかった
            save(general(await notificationSettings(.authorized, turnOn: true), openAtLogin: .enabled), name("37b-settings-general-notifications-on"), scheme)
            save(general(await notificationSettings(.denied, turnOn: true)), name("37c-settings-general-notifications-denied"), scheme)
            // 完全な削除
            let paths = AppPaths(home: URL(fileURLWithPath: "/Users/taro"))
            let items = Uninstaller.plannedItems(paths: paths, targetNames: ["居間のMac Studio", "居間の Mac mini"], homebrewRemoved: false)
            save(UninstallContent(stage: .confirming, items: items, phase: nil, report: nil, onCancel: {}, onConfirm: {}, onClose: {}, onQuit: {}),
                 name("42-uninstall-confirm"), scheme)
            save(UninstallContent(stage: .running, items: items, phase: .unpairing, report: nil, onCancel: {}, onConfirm: {}, onClose: {}, onQuit: {}),
                 name("43-uninstall-running"), scheme)
            save(UninstallContent(stage: .finished, items: items, phase: .finished,
                                  report: report { $0.appTrashed = true; $0.unreachable = ["居間の Mac mini"]; $0.brewCommand = "brew uninstall sharescale" },
                                  onCancel: {}, onConfirm: {}, onClose: {}, onQuit: {}), name("44-uninstall-finished"), scheme)
            save(UninstallContent(stage: .finished, items: items, phase: .finished,
                                  report: report {
                                      $0.aborted = tr("ログイン項目の登録は解除しましたが、ShareScale Host が停止したことを確認できなかったため、ほかのものは削除していません。ShareScale Host のメニューから終了してから、もう一度選択してください。",
                                                      "The login item was removed, but ShareScale Host couldn’t be confirmed as stopped, so nothing else was deleted. Quit it from the ShareScale Host menu, then try again.")
                                      $0.abortDetail = "ShareScale Host is still running after 10 s"
                                  },
                                  onCancel: {}, onConfirm: {}, onClose: {}, onQuit: {}), name("45-uninstall-aborted"), scheme)
            // 診断
            let t = book.entries[0]
            let ok = ViewerDiagnostics.lines(target: t, state: state(), failure: nil, chosen: .x1)
            save(DiagnosticsContent(targetName: t.displayName, lines: ok, report: "", busy: false, canRecheck: true, onRecheck: {}), name("40-diagnostics-ok"), scheme)
            let bad = ViewerDiagnostics.lines(target: t, state: nil, failure: .unreachable, chosen: .x1, readProblems: 1)
                + [ViewerDiagnostics.Line(.bad, tr("アップデート: 失敗しました（Homebrew の新しいバージョンに切り替えられませんでした）", "Update: failed (couldn’t switch to the newer Homebrew version)"),
                                          advice: tr("ターミナルで open \"$(brew --prefix)/opt/sharescale/ShareScale.app\" を実行してください。",
                                                     "In Terminal, run open \"$(brew --prefix)/opt/sharescale/ShareScale.app\"."))]
            save(DiagnosticsContent(targetName: t.displayName, lines: bad, report: "", busy: false, canRecheck: true, onRecheck: {}), name("41-diagnostics-unreachable"), scheme)
            // 「〜の設定を開く…」の行（計画 2f-1 案 5）
            let denied = ViewerDiagnostics.lines(target: t, state: nil, failure: .localNetworkDenied, chosen: .x1)
                + [ViewerDiagnostics.Line(.bad, tr("ログイン項目: ログイン項目で ShareScale がオフになっているため、登録し直しませんでした。システム設定 › 一般 › ログイン項目でオンにしてください。",
                                                   "Login item: ShareScale is turned off in Login Items, so it wasn’t registered again. Turn it on in System Settings › General › Login Items."),
                                          action: .openLoginItemsSettings)]
            save(DiagnosticsContent(targetName: t.displayName, lines: denied, report: "", busy: false, canRecheck: true, onRecheck: {}), name("41b-diagnostics-settings-actions"), scheme)
            // Host の窓（初回の知らせ・コードの窓・確認の窓）
            let hl: HostLanguage = lang == .ja ? .ja : .en
            save(MenuBarNoticeView(p: MenuBarNoticePresentation(language: hl), close: {}), name("51-host-first-launch-notice"), scheme)
            let code = PairingCode(id: pairingID(7), secret: Bytes32(Data(repeating: 7, count: 32))!, port: 47651,
                                   addresses: ["studio.local", "100.101.1.2"], expiresAt: 1_800_000_421)!
            save(CodeView(p: CodePresentation(code, language: hl), language: hl, now: Date(timeIntervalSince1970: 1_800_000_000), copy: { _ in }, revoke: {}),
                 name("52-host-code-window"), scheme)
            let request = ApprovalRequest(codeID: pairingID(7), name: "書斎の MacBook Air", confirmationCode: 12_345, source: "100.101.1.3", sourceClass: .sharedCGNAT)
            save(ApprovalView(p: ApprovalPresentation(request, language: hl), approve: {}, decline: {}), name("53-host-approval-window"), scheme)
            // 同じ Mac からの名乗り（題名に「この Mac」、下の行は出さない。実機確認 2026-09-30）
            let local = ApprovalRequest(codeID: pairingID(7), name: "MacBook Pro", confirmationCode: 12_345, source: "127.0.0.1", sourceClass: .loopback)
            save(ApprovalView(p: ApprovalPresentation(local, language: hl), approve: {}, decline: {}), name("53b-host-approval-window-this-mac"), scheme)
            // Host の診断の窓（計画 2f-1 案 5: ✗ と ? の行に「〜の設定を開く…」）
            var hd = HostDiagnostics(); hd.listener = .listening(port: 47651)
            var sys = SystemDiagnostics(); sys.firewall = .on(.blocked); sys.fileVault = false; sys.loginItem = .requiresApproval
            let hnow = Int64(Date().timeIntervalSince1970)
            let hostPairings: [PairingID: HostMeta] = [pairingID(4): HostMeta(name: "書斎の MacBook Air", created: hnow - 86_400, lastSeen: hnow - 3 * 86_400, confirmed: true)]
            let hostItems = DiagnosticsReport.items(host: hd, system: sys, pairings: hostPairings, version: "1.1.0 (10100)", now: Date(), language: hl)
            save(HostDiagnosticsView(content: HostDiagnosticsContent(items: hostItems), language: hl, onAction: { _ in }, onReload: {}, copy: { _ in }, scrolls: false),
                 name("54-host-diagnostics"), scheme)
            // 接続元の Mac が 32 台: 確認の行と一覧はスクロール（高さは上限で止める）、ボタンの行は下に固定（点検 2f-1。`ImageRenderer` はスクロールの中身を描かず、枠だけを描く）
            let many = Dictionary(uniqueKeysWithValues: (0..<32).map { n in
                (pairingID(UInt8(40 + n)), HostMeta(name: "Mac \(n + 1)", created: hnow - 86_400, lastSeen: hnow - Int64(n) * 86_400, confirmed: true))
            })
            let manyItems = DiagnosticsReport.items(host: hd, system: sys, pairings: many, version: "1.1.0 (10100)", now: Date(), language: hl)
            save(HostDiagnosticsView(content: HostDiagnosticsContent(items: manyItems), language: hl, onAction: { _ in }, onReload: {}, copy: { _ in }),
                 name("54b-host-diagnostics-32-macs"), scheme)
            // 設定 › 一般 の別の姿（計画 2f-2: Dock に出さない・Host のアイコンを常に出す・ログイン項目でオフ）
            save(general(await notificationSettings(.notDetermined), openAtLogin: .requiresApproval, dock: false, hostIcon: true),
                 name("37d-settings-general-menubar-dock-off"), scheme)
            // 初回のガイド（計画 2f-2 案 3。主の窓の中のページ）
            for c in onboardingCases {
                save(OnboardingContent(page: onboardingPage(c), hostSwitch: hostSwitch(c.login), onChoose: { _ in }, onPrimary: {}, onAction: {}, onBack: {},
                                       onLater: {}, onToggleHost: { _ in }, onOpenLoginItems: {}), name(c.file), scheme)
            }
        }
        // メニューバーのメニュー（計画 2f-2 案 1・2。`NSMenu` は描けないので、項目の文言を書き出す）
        var viewerMenus = ""
        func addMenu(_ title: String, _ items: [ViewerMenuItem]) { viewerMenus += "# \(title)\n" + menuText(items) + "\n\n" }
        let menuNow = Date()
        addMenu(tr("接続先なし", "No targets"), ViewerMenu.items(model: ViewerModel(client: nil, displays: { [lg, builtIn] }), targets: [], canAddTarget: true, host: nil, now: menuNow))
        addMenu(tr("接続先なし・新しい版がある", "No targets, a new version is available"),
                ViewerMenu.items(model: ViewerModel(client: nil, displays: { [lg] }), targets: [], canAddTarget: true, host: nil, updateAvailable: true, now: menuNow))
        let connectedVM = ViewerModel(client: FixedTarget(.success(state(mode: .twoX, scaling: .twoX))), displays: { [lg, builtIn] }, targetLabel: "居間のMac Studio")
        await connectedVM.refresh()
        addMenu(tr("画面共有で接続中・ディスプレイ 2 つ・接続先 3 台・この Mac の接続先（コード発行中）", "Connected, 2 displays, 3 targets, This Mac as a Target (code showing)"),
                ViewerMenu.items(model: connectedVM, targets: TargetRow.rows(book, selectedID: pairingID(1)), canAddTarget: true,
                                 host: .running(HostMenuFacts(summary: hostSummary(code: Int64(menuNow.timeIntervalSince1970) + 421)), outdated: false),
                                 now: menuNow))
        let idleVM = ViewerModel(client: FixedTarget(.success(state(session: false, vd: false))), displays: { [lg] }, targetLabel: "居間のMac Studio")
        await idleVM.refresh()
        addMenu(tr("画面共有は未接続・接続先 1 台・この Mac の接続先は一時停止中（Tailscale が見つからない）・古い版の Host", "Not connected, 1 target, This Mac as a Target paused (Tailscale not found), older Host"),
                ViewerMenu.items(model: idleVM, targets: [], canAddTarget: true,
                                 host: .running(HostMenuFacts(summary: hostSummary(paused: true, listener: #"{"status":"waiting_for_network"}"#)), outdated: true),
                                 now: menuNow))
        let failedVM = ViewerModel(client: FixedTarget(.failure(.unreachable)), displays: { [lg] }, targetLabel: "居間のMac Studio")
        await failedVM.refresh()
        addMenu(tr("接続できない・Host の状態を読み取れない", "Can’t connect, Host state unreadable"),
                ViewerMenu.items(model: failedVM, targets: [], canAddTarget: true, host: .unreadable, now: menuNow))
        addMenu(tr("Host の起動の途中・終了の途中", "Host starting, Host quitting"),
                ViewerMenu.items(model: failedVM, targets: [], canAddTarget: true, host: .starting, now: menuNow).suffix(4)
                    + ViewerMenu.items(model: failedVM, targets: [], canAddTarget: true, host: .stopping, now: menuNow).suffix(4))
        // 計画 2i: 一時停止の間に倍率を選んで断られた（状態の 1 行は「一時停止中」。「接続できません」にしない）
        let refusedVM = ViewerModel(client: FixedTarget(.success(state()), refusal: .paused), displays: { [lg] }, targetLabel: "居間のMac Studio")
        await refusedVM.refresh()
        await refusedVM.apply(.x2)
        addMenu(tr("一時停止の間に倍率を選んで断られた", "A scale was chosen while the Host is paused"),
                ViewerMenu.items(model: refusedVM, targets: [], canAddTarget: true, host: nil, now: menuNow))
        let busyVM = ViewerModel(client: FixedTarget(.success(state()), hang: true), displays: { [lg] }, targetLabel: "居間のMac Studio")
        await busyVM.refresh()
        Task { await busyVM.refresh(force: true) }
        while !busyVM.busy { await Task.yield() }
        addMenu(tr("処理中", "Busy"), ViewerMenu.items(model: busyVM, targets: [], canAddTarget: true, host: nil, now: menuNow))
        try? viewerMenus.write(to: outDir.appendingPathComponent("60-viewer-menu-\(l).txt"), atomically: true, encoding: .utf8)
        print("60-viewer-menu-\(l).txt")
        // 初回のガイドの各段の文言（`ImageRenderer` はボタン・スイッチの文字を描かないので）
        var guideText = ""
        for c in onboardingCases {
            let p = onboardingPage(c)
            guideText += "# \(c.file)\n" + p.title + (p.progress.map { "    （\($0)）" } ?? "") + "\n"
            if let l = p.lead { guideText += l + "\n" }
            for o in p.options { guideText += "  [\(o.left) \(o.arrow) \(o.right)] \(o.title) — \(o.detail)\n" }
            for (i, s) in p.steps.enumerated() { guideText += "  \(i + 1). \(s)\n" }
            if p.showsHostSwitch {
                let sw = hostSwitch(c.login)
                guideText += "  " + (sw.isOn ? "[オン] " : "[オフ] ") + tr("この Mac を接続先にする", "Use This Mac as a Target") + " — " + sw.note + "\n"
            }
            if let s = p.hostStatus { guideText += "  ✓ " + s + "\n" }
            if let a = p.action { guideText += "  [" + a.title + (a.enabled ? "" : "（押せない）") + "]\n" }
            let buttons = [p.back, p.later, p.primary.map { $0.title + ($0.enabled ? "（既定）" : "（押せない）") }].compactMap { $0 }
            guideText += "  " + buttons.map { "[\($0)]" }.joined(separator: " ") + "\n\n"
        }
        try? guideText.write(to: outDir.appendingPathComponent("61-onboarding-\(l).txt"), atomically: true, encoding: .utf8)
        print("61-onboarding-\(l).txt")
        // Host のメニュー（`NSMenu` は描けないので、項目の文言を書き出す）
        let hl: HostLanguage = lang == .ja ? .ja : .en
        var d = HostDiagnostics(); d.listener = .listening(port: 47651)
        let t = Int64(Date().timeIntervalSince1970)
        let pairings: [PairingID: HostMeta] = [pairingID(4): HostMeta(name: "書斎の MacBook Air", created: t - 86_400, lastSeen: t - 3 * 86_400, confirmed: true),
                                               pairingID(6): HostMeta(name: "新しい MacBook", created: t, confirmed: false)]
        // 受け付けの行の 3 つの状態（計画 2h）
        var internet = d; internet.allowGlobal = true
        var tailscale = d; tailscale.tailscaleOnly = true
        let menus = [("空", MenuModel.build(diagnostics: d, pairings: [:], code: nil, now: Date(), language: hl)),
                     ("2 台・コード発行中", MenuModel.build(diagnostics: d, pairings: pairings, code: ("x", Date().addingTimeInterval(421)), now: Date(), language: hl)),
                     ("「インターネットからの接続も受け付ける」がオン", Array(MenuModel.build(diagnostics: internet, pairings: [:], code: nil, now: Date(), language: hl).prefix(2))),
                     ("「Tailscale からの接続だけを受け付ける」がオン", Array(MenuModel.build(diagnostics: tailscale, pairings: [:], code: nil, now: Date(), language: hl).prefix(2)))]
        var text = ""
        for (title, entries) in menus {
            text += "# \(title)\n"
            for e in entries {
                switch e {
                case let .status(s), let .notice(s), let .diagnostics(s), let .openLog(s): text += s + "\n"
                case let .quit(s): text += s + "    ⌘Q\n"
                case let .addViewer(s, on): text += s + (on ? "" : "（押せない）") + "\n"
                case let .showCode(s), let .pause(s, _), let .reviewViewers(s): text += s + "\n"
                case let .viewer(_, title, detail, _, unpair, later): text += "\(title) ›  [\(detail) / \(unpair)\(later.map { " / " + $0 } ?? "")]\n"
                case .separator: text += "────────\n"
                }
            }
            text += "\n"
        }
        try? text.write(to: outDir.appendingPathComponent("50-host-menu-\(l).txt"), atomically: true, encoding: .utf8)
        print("50-host-menu-\(l).txt")
        // `ImageRenderer` はボタン・スイッチの文字を描かないので、計画 2f-1 で足したものの文言を書き出す
        var labels = "# 〜の設定を開く…（計画 2f-1 案 5）\n" + DiagnosticAction.allCases.map { $0.title(hl) }.joined(separator: "\n")
        labels += "\n\n# 接続先の一覧の行（案 6）\n" + tr("名前を変更…", "Rename…") + "\n" + tr("アドレスを編集…", "Edit Addresses…") + "\n" + tr("削除…", "Delete…")
        labels += "\n\n# 通知（案 7）\n" + tr("表示倍率や接続の変化を通知する", "Notify Me About Changes") + "\n"
            + ChangeNotificationKind.offered.map { "☐ " + $0.settingLabel }.joined(separator: "\n")
        labels += "\n\n# Host の編集のメニュー（⌘C の取り合い）\n" + EditMenuModel.items(hl).map { "\($0.title)  ⌘\($0.key.uppercased())" }.joined(separator: "\n")
            + "\n" + CodePresentation(PairingCode(id: pairingID(7), secret: Bytes32(Data(repeating: 7, count: 32))!, port: 47651, addresses: ["studio.local"],
                                                 expiresAt: 1_800_000_000)!, language: hl).copyHelp
        labels += "\n\n# 設定 › 一般（計画 2f-2）\n" + [tr("はじめに…", "Getting Started…"), tr("Dock に表示する", "Show in Dock"),
                                                     tr("ログイン時に ShareScale を開く", "Open ShareScale at Login"),
                                                     tr("ShareScale Host のアイコンを常にメニューバーに表示する", "Always Show ShareScale Host’s Icon in the Menu Bar")].joined(separator: "\n")
        labels += "\n\n# 新しい版（点検 2f-2）\n" + UpdateWatcher.actionTitle
        labels += "\n\n# メニューバーの記号（点検 2f-2）\nShareScale: " + MenuBarLabel.symbol + "\nShareScale Host: rectangle.on.rectangle"
        labels += "\n\n# Host の初回の知らせ\n" + MenuBarNoticePresentation(language: hl).message
        // 計画 2h: 別の場所から開いた時の案内のウインドウ（NSAlert は描けないので文言を書き出す）と、「ヘルプ」のメニューの項目
        let ours = CopyFacts(isSymlink: false, ownerIsMe: true, bundle: BundleFacts(identifier: AppIdentifiers.app, version: 10100, cdhash: "00"))
        let other = CopyFacts(isSymlink: false, ownerIsMe: true, bundle: BundleFacts(identifier: "com.example.Other", version: 1, cdhash: "00"))
        let copyPath = "/Users/taro/Applications/ShareScale.app"
        labels += "\n\n# 別の場所から開いた時の案内（計画 2h）"
        for (title, copy, own) in [("~/Applications に ShareScale がある", ours as CopyFacts?, 10100), ("~/Applications の ShareScale より、この場所の方が新しい", ours, 10200),
                                   ("~/Applications/ShareScale.app が別のアプリ・リンクなど", other, 10100), ("~/Applications に無い", nil, 10100)] {
            let g = AppLocation.elsewhereGuidance(copy: CopySnapshot(facts: copy, realPath: copy == nil ? nil : copyPath), home: "/Users/taro", ownVersion: own)
            labels += "\n## " + title + "\n" + g.title + "\n" + g.detail + "\n"
                + (g.openCopyTitle.map { "[" + $0 + "（既定）] " } ?? "") + "[" + tr("終了", "Quit") + "]"
        }
        labels += "\n\n# 「ヘルプ」のメニュー（計画 2h）\n" + AppLinks.helpTitle + "  → " + AppLinks.repository.absoluteString
        labels += "\n\n# 設定 › この Mac の接続先 ›「接続を受け付けるネットワーク」の注記（点検 2h）\n" + HostPanelModel.defaultNetworkNote
        // 計画 2i: 届かない時に確認すること（1 か所の定義）と、それを出す 3 か所。Host の診断の、まだ一覧に無い時の行。一時停止で断られた時の診断
        labels += "\n\n# 届かない時に確認すること（計画 2i）\n## 主の窓の案内\n" + ViewerNotice.unreachableTitle + "\n" + ViewerNotice.unreachableChecks(hostName: "居間のMac Studio")
        let addResult = AddTargetText.result(.failed(.connection(.unreachable))).text
        labels += "\n## 「接続先を追加」の結果\n" + addResult.title + "\n" + addResult.detail
        let unreachableLine = ViewerDiagnostics.lines(target: book.entries[0], state: nil, failure: .unreachable, chosen: .x1)[1]
        labels += "\n## 診断の「接続」の行\n" + unreachableLine.mark.rawValue + " " + unreachableLine.text + "\n  " + (unreachableLine.advice ?? "")
        var notListed = SystemDiagnostics(); notListed.firewall = .on(.notInRules)
        var listeningHost = HostDiagnostics(); listeningHost.listener = .listening(port: 47651)
        labels += "\n## Host の診断（ファイアウォールがオンで、ShareScale Host がまだ一覧に無い時）\n"
            + DiagnosticsReport.lines(host: listeningHost, system: notListed, pairings: [:], version: "1.1.0", now: Date(), language: hl).filter { $0.contains(hl.t("ファイアウォール", "Firewall")) }.joined(separator: "\n")
        labels += "\n\n# 一時停止の間に倍率を選んで断られた時の診断（計画 2i）\n"
            + ViewerDiagnostics.lines(target: book.entries[0], state: state(), failure: .paused, chosen: .x1).map { $0.mark.rawValue + " " + $0.text }.joined(separator: "\n")
        labels += "\n\n# Host の診断の行（計画 2i。ほかの常駐との競合の行は無い）\n"
            + DiagnosticsReport.lines(host: listeningHost, system: SystemDiagnostics(), pairings: [:], version: "1.1.0", now: Date(), language: hl).joined(separator: "\n")
        try? (labels + "\n").write(to: outDir.appendingPathComponent("55-controls-\(l).txt"), atomically: true, encoding: .utf8)
        print("55-controls-\(l).txt")
        // 設定の 3 つのタブの高さ（計画 2h。`ImageRenderer` は `ScrollView` の中身を描かないので、入れ物に入れた時の高さを数で書き出す）。
        // 最小と最大が同じなので、窓はタブを切り替えた時にその高さになる
        var heights = "# 設定のタブの高さ（最小／理想／最大。pt）\n"
        func row(_ title: String, _ content: some View) {
            heights += title + "\n"
            let free = heightsOf(content)
            heights += "  中身: \(Int(free.ideal))\n"
            for visible in [700.0, 940.0, 1400.0] {
                let limit = CGFloat(SettingsLayout.maxPaneHeight(visibleHeight: visible))
                let h = heightsOf(SettingsPane(maxHeight: limit) { content })
                heights += "  画面の見える高さ \(Int(visible))（上限 \(Int(limit))）: \(Int(h.min))／\(Int(h.ideal))／\(Int(h.max))" + (free.ideal > limit ? "（中をスクロール）" : "") + "\n"
            }
        }
        let hnow = Int64(Date().timeIntervalSince1970)
        func host(_ summary: HostControlState.Summary) -> some View {
            HostSettingsContent(panel: HostPanelModel.make(.running(summary), now: hnow, appBuild: 10100), hostSwitch: hostSwitch(.enabled),
                                actionMessage: nil, actionFailed: false, actionDetail: nil, onAction: { _ in },
                                onToggleHost: { _ in }, onOpenLoginItems: {}, onOpenSettings: { _ in })
        }
        let targetNote = tr("接続先は 32 台まで登録できます。", "You can add up to 32 targets.")
        row("接続先（0 件）", TargetsSettingsContent(rows: [], storeNotice: nil, canAdd: true, addNote: targetNote, removal: nil, busyIDs: [],
                                                 onAdd: {}, onEdit: { _ in }, onRemove: { _ in }, onRename: { _ in }))
        row("接続先（3 件）", TargetsSettingsContent(rows: TargetRow.rows(book, selectedID: pairingID(1)), storeNotice: nil, canAdd: true, addNote: targetNote, removal: nil,
                                                 busyIDs: [], onAdd: {}, onEdit: { _ in }, onRemove: { _ in }, onRename: { _ in }))
        row("この Mac の接続先（接続元の Mac 3 台）", host(hostSummary()))
        row("この Mac の接続先（接続元の Mac 32 台）", host(hostSummary(manyViewers: true)))
        row("一般", general(await notificationSettings(.notDetermined)))
        row("一般（通知が許可されていない）", general(await notificationSettings(.denied, turnOn: true)))
        row("一般（いちばん高い形: 通知が許可されていない・ログイン項目の承認待ち）", general(await notificationSettings(.denied, turnOn: true), openAtLogin: .requiresApproval))
        try? heights.write(to: outDir.appendingPathComponent("62-settings-heights-\(l).txt"), atomically: true, encoding: .utf8)
        print("62-settings-heights-\(l).txt")
    }
}

_ = NSApplication.shared
await render()
print("書き出し先: \(outDir.path)")
