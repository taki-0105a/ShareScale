import Combine
import Foundation
import ShareScaleHostCore

/// 「ログイン時に ShareScale を開く」の実物（`SMAppService.mainApp`。口は Host の常駐と同じ `LoginItemService`）
public struct SystemAppLoginItemService: LoginItemService {
    /// ShareScale.app（実物は `Bundle.main.bundleURL`）
    public let appBundle: URL
    public init(appBundle: URL = Bundle.main.bundleURL) { self.appBundle = appBundle }
    public func status() -> LoginItemStatus { SystemChecks.appLoginItem() }
    public func register() throws { try SystemChecks.registerAppLoginItem() }
    public func unregister() throws { try SystemChecks.unregisterAppLoginItem() }
    public func openSystemSettingsLoginItems() { SystemChecks.openLoginItemsSettings() }
    /// 更新させるもの: ログイン時に開くのはアプリそのもの（計画 2j）
    public var launchServicesURLs: [URL] { [appBundle] }
    public func refreshLaunchServices() async { _ = await LaunchServicesRefresh.run(launchServicesURLs) }
}

/// 設定 › 一般 の「ログイン時に ShareScale を開く」に出すもの（純粋な値）
public struct OpenAtLoginModel: Equatable, Sendable {
    public var isOn: Bool
    public var canToggle: Bool
    public var note: String
    /// 「ログイン項目を開く…」を出す（`requiresApproval`）
    public var needsApproval: Bool
    public var result: String?
    public var resultDetail: String?
    public init(isOn: Bool, canToggle: Bool, note: String, needsApproval: Bool, result: String? = nil, resultDetail: String? = nil) {
        self.isOn = isOn; self.canToggle = canToggle; self.note = note; self.needsApproval = needsApproval; self.result = result; self.resultDetail = resultDetail
    }
}

/// 「ログイン時に ShareScale を開く」（計画 2f-2 案 1。`SMAppService.mainApp`）。**既定はオフ**で、利用者がオンにした時に登録する。
/// 登録・解除は `~/Applications` の複製（`.copy`）だけが行う（開発の組み立てを登録すると、組み立て直すと開けなくなるため。Host の常駐の流儀に合わせる。計画 2e-1）。
/// ShareScale.app 自身は必ずあるので、`.notFound`（macOS 27 は登録前に返すことがある。計画 2f-1）は「まだ登録していない」とみなす。
/// 登録は同期で終わる（Host の常駐と違い、起動を待つものが無い）
@MainActor
public final class OpenAtLoginController: ObservableObject {
    @Published public private(set) var status: LoginItemStatus
    @Published public private(set) var failure: (text: String, detail: String)?
    /// 取り除き中・取り除いた後は押せない（`UninstallFlow` が立てる）
    @Published public private(set) var lockedForRemoval = false
    public let role: AppRole
    private let service: LoginItemService
    /// 登録した時の CDHash を覚える場所（`app-state.json` の `registered_app_cdhash`。点検 2f-2）と、自分の CDHash
    private let stateFile: AppStateFile?
    private let ownCDHash: String?
    private let sleep: (Double) async -> Void
    /// 更新の後に登録し直す時の間（3 秒。計画 2f-2 のまま。Host のログイン項目は 1 秒にした（計画 2j）が、こちらは待つものが無く、
    /// 利用者を待たせないので変えない。試作 5 の「1 秒では足りず 3 秒なら通る」は誤りだった＝仕様「ログイン項目の登録」）
    public static let reregisterDelay = 3.0
    /// 登録し直している間（3 秒待つ間を含む）。この間は完全な削除を始めない（`UninstallFlow.available`。再点検 2f-2）
    @Published public private(set) var busy = false

    public init(role: AppRole, service: LoginItemService, stateFile: AppStateFile? = nil, ownCDHash: String? = nil,
                sleep: @escaping (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
        self.role = role; self.service = service; self.stateFile = stateFile; self.ownCDHash = ownCDHash; self.sleep = sleep
        status = Self.effective(service.status())
    }

    /// 複製の起動時: 登録済み（`enabled`）で、自分の CDHash が登録した時と違えば（更新した）、LaunchServices を更新 → 解除 → 3 秒 → 登録 で登録し直す
    /// （Host のログイン項目と同じ流儀。登録の壊れ方は試作 5。点検 2f-2）。記録が無い（2f-2 より前に登録した）時も登録し直して記録する。
    /// 次のログインで本当に開かれるかは、その場では分からない（Host と違い、応答を待てない。計画 2j「実機で確かめること」）
    public func startup() async {
        guard role == .copy, !busy, !lockedForRemoval, let own = ownCDHash, let file = stateFile else { return }
        refresh()
        guard status == .enabled, file.load().state.registeredAppCDHash != own else { return }
        busy = true
        defer { busy = false; refresh() }
        // Host のログイン項目と同じく、登録し直しの前に LaunchServices の登録を新しい中身で更新させる（効くかは未確認。計画 2j）
        await service.refreshLaunchServices()
        try? service.unregister()
        await sleep(Self.reregisterDelay)
        // 待つ間に取り除きが始まっていたら登録し直さない（取り除きが消すものを作り直さない。再点検 2f-2）
        guard !lockedForRemoval else { return }
        do {
            try service.register()
            try? file.update { $0.registeredAppCDHash = own }
            failure = nil
        } catch {
            failure = (tr("ログイン時に開く設定を、新しいバージョンで登録し直せませんでした。スイッチをオフにしてからオンにしてください。",
                          "Couldn’t register opening at login again for the new version. Turn the switch off and then on."), "\(error)")
        }
    }

    static func effective(_ s: LoginItemStatus) -> LoginItemStatus { s == .notFound ? .notRegistered : s }

    public func refresh() {
        let s = Self.effective(service.status())
        if s != status { status = s }
    }
    public func lockForRemoval() { lockedForRemoval = true }
    public func unlockAfterRemoval() { lockedForRemoval = false }

    public var model: OpenAtLoginModel {
        let isOn = status == .enabled || status == .requiresApproval
        let note: String
        switch status {
        case _ where role != .copy:
            note = tr("ログイン時に開く設定は、~/Applications/ShareScale.app からだけ変更できます。", "Opening at login can only be set from ~/Applications/ShareScale.app.")
        case .requiresApproval:
            note = tr("ログイン項目で ShareScale がオフになっています。システム設定 › 一般 › ログイン項目で ShareScale をオンにしてください。",
                      "ShareScale is turned off in Login Items. Turn it on in System Settings › General › Login Items.")
        case .enabled:
            note = tr("ログインすると ShareScale が開き、メニューバーに表示されます。", "ShareScale opens when you log in and appears in the menu bar.")
        case .notRegistered, .notFound:
            note = tr("オンにすると、ログインした時に ShareScale が開き、メニューバーに表示されます。", "When on, ShareScale opens when you log in and appears in the menu bar.")
        case .unknown:
            note = tr("ログイン項目の状態を読み取れません。システム設定 › 一般 › ログイン項目を確認してください。",
                      "Can’t read the login item state. Check System Settings › General › Login Items.")
        }
        return OpenAtLoginModel(isOn: isOn, canToggle: role == .copy && !lockedForRemoval, note: note,
                                needsApproval: status == .requiresApproval && role == .copy, result: failure?.text, resultDetail: failure?.detail)
    }

    public func openLoginItems() { service.openSystemSettingsLoginItems() }

    /// スイッチを押した（オンで登録、オフで解除。失敗したら理由を出し、状態を読み直す）
    public func setEnabled(_ on: Bool) {
        guard role == .copy, !lockedForRemoval, !busy else { return }
        defer { refresh() }
        do {
            if on {
                refresh()
                guard status == .notRegistered || status == .unknown else { failure = nil; return }
                try service.register()
                if let own = ownCDHash { try? stateFile?.update { $0.registeredAppCDHash = own } }
            } else {
                try service.unregister()
                try? stateFile?.update { $0.registeredAppCDHash = nil }
            }
            failure = nil
        } catch {
            failure = (on ? tr("ログイン項目に登録できませんでした。もう一度試すか、システム設定 › 一般 › ログイン項目を確認してください。",
                               "Couldn’t add ShareScale to Login Items. Try again, or check System Settings › General › Login Items.")
                          : tr("ログイン項目から外せませんでした。もう一度試すか、システム設定 › 一般 › ログイン項目を確認してください。",
                               "Couldn’t remove ShareScale from Login Items. Try again, or check System Settings › General › Login Items."), "\(error)")
        }
    }
}
