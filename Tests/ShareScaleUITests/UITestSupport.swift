import AppKit
import SwiftUI
import XCTest
import ShareScaleCore
import ShareScaleHostCore
import ShareScaleProtocol
@testable import ShareScaleUI

// 画面の部品の試験の土台（計画 2h）。**ウインドウは出さない**: 大きさは `NSHostingController` に聞くだけ、アクセシビリティの木は、
// 画面の外の・表示しないウインドウに載せて読むだけ。通信・保管・クリップボード・利用者のホームの実際の場所には触れない（値はすべて偽物）

// ---- 大きさ ----

@MainActor
enum Measure {
    /// 幅 `width` に置いた時の、最小・理想・最大の高さ（設定の窓は、タブの中身のこの 3 つから窓の高さを決める）
    static func heights(_ view: some View, width: CGFloat = 560) -> (min: CGFloat, ideal: CGFloat, max: CGFloat) {
        let framed = view.frame(width: width)
        let c = NSHostingController(rootView: framed)
        return (c.sizeThatFits(in: NSSize(width: width, height: 0)).height,
                NSHostingView(rootView: framed).fittingSize.height,
                c.sizeThatFits(in: NSSize(width: width, height: 100_000)).height)
    }
}

// ---- 偽のデータ ----

func pid(_ n: UInt8) -> PairingID { PairingID(bytes: [UInt8](repeating: n, count: 16))! }

/// Host が書く形の `state.json` を読んだもの（接続元の Mac を `viewers` 台）
func hostSummary(viewers: Int, tailscaleOnly: Bool = false, allowGlobal: Bool = false, code: Int64? = nil) -> HostControlState.Summary {
    let pairings = (0..<viewers).map { n in
        #"{"id":"\#(pid(UInt8(40 + n)).hex)","name":"Mac \#(n + 1)","last_seen":\#(1_800_000_000 - n * 86_400),"confirmed":true,"stale":false}"#
    }
    let codePart = code.map { #","code":{"expires":\#($0)}"# } ?? ""
    let json = #"{"format":1,"pid":1,"version":"1.1.0","build":10100,"running":true,"paused":false,"listener":{"status":"listening","port":47651},"pairings":[\#(pairings.joined(separator: ","))]\#(codePart),"diagnostics":{"tailscale_only":\#(tailscaleOnly),"allow_global":\#(allowGlobal),"tailscale":"none","updating":false,"contention":false,"last_error":null,"store_problems":0,"engine_problem":null,"log_problem":null,"rejected_global_24h":0,"pairing_count":\#(viewers),"firewall":"allowed","filevault":true,"login_item":"enabled"},"updated":1800000000}"#
    return HostControlState.decode(Data(json.utf8))!
}

/// 状態を固定したログイン項目の口（登録・解除はしない）
struct FixedLoginItem: LoginItemService {
    let value: LoginItemStatus
    func status() -> LoginItemStatus { value }
    func register() throws {}
    func unregister() throws {}
    func openSystemSettingsLoginItems() {}
    func refreshLaunchServices() async {}
}

/// 許可の状態を固定した通知の口（許可を求めない・送らない）
struct FixedPoster: NotificationPosting {
    let value: NotificationAuthorization
    func authorization() async -> NotificationAuthorization { value }
    func requestAuthorization() async -> Bool { value == .authorized }
    func post(_ n: PlannedNotification) async {}
}

/// 「この Mac を接続先にする」の表示（書き込まない一時の置き場所。ファイルは作らない）
@MainActor func hostSwitch(_ status: LoginItemStatus = .enabled) -> HostSwitchModel {
    LoginItemController(role: .copy, service: FixedLoginItem(value: status),
                        stateFile: AppStateFile(url: FileManager.default.temporaryDirectory.appendingPathComponent("ssui-\(UUID().uuidString)/app-state.json")),
                        ownCDHash: nil, hostPID: { nil }, hostEmbedded: { true }).model
}

/// 設定 › この Mac の接続先 の中身（接続元の Mac を `viewers` 台）
@MainActor func hostContent(viewers: Int, allowGlobal: Bool = false, onAction: @escaping (HostPanelModel.Action) -> Void = { _ in }) -> HostSettingsContent {
    HostSettingsContent(panel: HostPanelModel.make(.running(hostSummary(viewers: viewers, allowGlobal: allowGlobal)), now: 1_800_000_000, appBuild: 10100),
                        hostSwitch: hostSwitch(), actionMessage: nil, actionFailed: false, actionDetail: nil,
                        onAction: onAction, onToggleHost: { _ in }, onOpenLoginItems: {}, onOpenSettings: { _ in })
}

/// 接続先を `count` 件持つ帳簿
func targetRows(_ count: Int) -> [TargetRow] {
    var l = TargetBook.Loaded()
    l.entries = (0..<count).map { n in
        TargetEntry(id: pid(UInt8(1 + n)), secret: Bytes32(Data(repeating: UInt8(1 + n), count: 32))!,
                    meta: ViewerMeta(name: "Target \(n + 1)", port: 47651, addresses: ["target\(n + 1).local", "100.101.1.\(n + 2)"], manual: false,
                                     lastOKAddress: "target\(n + 1).local", confirmed: true, alias: nil)!)
    }
    return TargetRow.rows(l, selectedID: count > 0 ? pid(1) : nil)
}

/// 設定 › 接続先 の中身
@MainActor func targetsContent(_ count: Int, onRemove: @escaping (TargetRow) -> Void = { _ in }) -> TargetsSettingsContent {
    TargetsSettingsContent(rows: targetRows(count), storeNotice: nil, canAdd: true, addNote: tr("接続先は 32 台まで登録できます。", "You can add up to 32 targets."),
                           removal: nil, busyIDs: [], onAdd: {}, onEdit: { _ in }, onRemove: onRemove, onRename: { _ in })
}

/// 設定 › 一般 の中身（記憶の中の環境設定。登録・通知の許可の求めはしない）
@MainActor func generalContent(_ authorization: NotificationAuthorization = .notDetermined, notificationsOn: Bool = false,
                               openAtLogin: LoginItemStatus = .notRegistered) async -> GeneralSettings {
    let n = ViewerNotifications(preferences: NotificationPreferences(store: InMemoryStringStore()), poster: FixedPoster(value: authorization), appActive: { false })
    await n.refreshAuthorization()
    if notificationsOn { await n.setEnabled(true) }
    let a = AppearanceSettings(preferences: AppearancePreferences(store: InMemoryStringStore()), applyDock: { _ in }, claim: { _ in })
    return GeneralSettings(version: "1.1.0 (abc1234)", uninstallAvailable: true, uninstallNote: UninstallFlow.availableNote, notifications: n.model,
                           appearance: a.model, openAtLogin: OpenAtLoginController(role: .copy, service: FixedLoginItem(value: openAtLogin)).model,
                           onToggleNotifications: { _ in }, onNotificationKind: { _, _ in }, onOpenNotificationSettings: {},
                           onShowsInDock: { _ in }, onHostIconAlwaysVisible: { _ in }, onOpenAtLogin: { _ in }, onOpenLoginItems: {}, onGuide: {}, onUninstall: {})
}
