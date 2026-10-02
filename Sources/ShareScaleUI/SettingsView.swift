import ShareScaleCore
import ShareScaleHostCore
import ShareScaleProtocol
import SwiftUI

/// 設定の窓（`Settings`）: タブ「接続先」「この Mac の接続先」「一般」。
/// どのタブも `SettingsPane` に入れ、窓の高さを「タブの中身の高さ」と「画面に収まる上限」の小さい方にする（計画 2h）
public struct SettingsWindow: View {
    @ObservedObject var targets: ViewerTargets
    @ObservedObject var host: HostPanelStore
    @ObservedObject var loginItems: LoginItemController
    @ObservedObject var uninstall: UninstallFlow
    @ObservedObject var notifications: ViewerNotifications
    /// 開いているタブ（メニューバーの「この Mac の接続先の設定…」で選ぶ。計画 2f-2）と、「はじめに…」で主の窓を開く口
    @ObservedObject var router: AppRouter
    @ObservedObject var appearance: AppearanceSettings
    @ObservedObject var openAtLogin: OpenAtLoginController
    let guide: OnboardingGuide
    let version: String
    let makeAddTarget: () -> AddTargetOpening

    public init(targets: ViewerTargets, host: HostPanelStore, loginItems: LoginItemController, uninstall: UninstallFlow, notifications: ViewerNotifications,
                router: AppRouter, appearance: AppearanceSettings, openAtLogin: OpenAtLoginController, guide: OnboardingGuide,
                version: String, makeAddTarget: @escaping () -> AddTargetOpening) {
        self.targets = targets; self.host = host; self.loginItems = loginItems; self.uninstall = uninstall; self.notifications = notifications
        self.router = router; self.appearance = appearance; self.openAtLogin = openAtLogin; self.guide = guide
        self.version = version; self.makeAddTarget = makeAddTarget
    }

    public var body: some View {
        TabView(selection: $router.settingsTab) {
            TargetsSettings(targets: targets, makeAddTarget: makeAddTarget)
                .tabItem { Label(tr("接続先", "Targets"), systemImage: "display") }
                .tag(SettingsTab.targets)
            HostSettings(store: host, loginItems: loginItems)
                .tabItem { Label(tr("この Mac の接続先", "This Mac as a Target"), systemImage: "rectangle.on.rectangle") }
                .tag(SettingsTab.host)
            GeneralUninstallSettings(version: version, uninstall: uninstall, loginItems: loginItems, notifications: notifications,
                                     appearance: appearance, openAtLogin: openAtLogin,
                                     onGuide: { guide.open(); router.openMain() })
                .tabItem { Label(tr("一般", "General"), systemImage: "gearshape") }
                .tag(SettingsTab.general)
        }
        .frame(width: 560)
        // 窓を開く口をここでも渡す（メニューバーのアイコンが表示された時だけに頼らない。点検 2f-2）
        .onAppear { router.install(openWindow: openWindow, openSettings: openSettings) }
    }
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
}

// MARK: - 接続先

/// タブ「接続先」: 一覧（名前・状態・前回の接続）・「アドレスを編集…」・「削除…」（確かめの上、`unpair` を送ってから消す）・「接続先を追加…」
struct TargetsSettings: View {
    @ObservedObject var targets: ViewerTargets
    let makeAddTarget: () -> AddTargetOpening
    @State private var adding: AddTargetModel?
    @State private var alreadyOpen = false
    @State private var editing: TargetEditItem?
    @State private var renaming: TargetRow?
    @State private var removing: TargetRow?
    @State private var removal: TargetRemoval?
    @State private var busyIDs: Set<PairingID> = []

    var body: some View {
        SettingsPane {
            TargetsSettingsContent(rows: targets.rows, storeNotice: targets.storeNotice, canAdd: targets.canAdd, addNote: targets.addNote,
                                   removal: removal, busyIDs: busyIDs,
                                   onAdd: { openAddTarget(makeAddTarget(), adding: &adding, alreadyOpen: &alreadyOpen) },
                                   onEdit: { id in
                                       if let e = targets.loaded.entry(id) { editing = TargetEditItem(id: id, name: e.displayName, editor: ManualCandidatesEditor(e.meta)) }
                                   },
                                   onRemove: { row in removing = row },
                                   onRename: { row in renaming = row })
        }
            .onAppear { targets.reload() }
            .sheet(item: $renaming) { row in
                RenameTargetSheet(row: row) { alias in try targets.rename(row.id, alias: alias) }
            }
            .sheet(item: $adding) { AddTargetSheet(model: $0) }
            .alreadyOpenAlert($alreadyOpen)
            .sheet(item: $editing) { item in
                CandidatesSheet(name: item.name, editor: item.editor) { candidates in
                    try targets.saveCandidates(item.id, candidates)
                }
            }
            .confirmationDialog(removing?.removeConfirmation.title ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                presenting: removing) { row in
                Button(role: .destructive) {
                    busyIDs.insert(row.id)
                    Task {
                        let r = await targets.remove(row.id)
                        removal = r
                        busyIDs.remove(row.id)
                    }
                } label: { Text(verbatim: tr("削除", "Delete")) }
            } message: { row in
                Text(verbatim: row.removeConfirmation.detail)
            }
    }
}

struct TargetEditItem: Identifiable {
    let id: PairingID
    let name: String
    let editor: ManualCandidatesEditor
}

/// タブ「接続先」の中身（値と操作だけ。書き出しの試験でも使う）
public struct TargetsSettingsContent: View {
    let rows: [TargetRow]
    let storeNotice: ViewerNotice.Text?
    let canAdd: Bool
    let addNote: String
    let removal: TargetRemoval?
    let busyIDs: Set<PairingID>
    let onAdd: () -> Void
    let onEdit: (PairingID) -> Void
    let onRemove: (TargetRow) -> Void
    /// 「名前を変更…」（計画 2f-1 案 6）
    let onRename: (TargetRow) -> Void

    public init(rows: [TargetRow], storeNotice: ViewerNotice.Text?, canAdd: Bool, addNote: String, removal: TargetRemoval?, busyIDs: Set<PairingID>,
                onAdd: @escaping () -> Void, onEdit: @escaping (PairingID) -> Void, onRemove: @escaping (TargetRow) -> Void,
                onRename: @escaping (TargetRow) -> Void) {
        self.rows = rows; self.storeNotice = storeNotice; self.canAdd = canAdd; self.addNote = addNote; self.removal = removal; self.busyIDs = busyIDs
        self.onAdd = onAdd; self.onEdit = onEdit; self.onRemove = onRemove; self.onRename = onRename
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let n = storeNotice { NoticeView(title: n.title, detail: n.detail, isError: true) }
            if let r = removal { NoticeView(title: r.message.title, detail: r.message.detail, isError: r.isError, copyableDetail: r.copyable) }
            if rows.isEmpty {
                Text(verbatim: tr("接続先はまだありません。", "No targets yet."))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16).cardStyle()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                        if i > 0 { Divider().padding(.leading, 16) }
                        rowView(row)
                    }
                }
                .cardStyle()
            }
            HStack {
                Text(verbatim: addNote).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(action: onAdd) { Text(verbatim: tr("接続先を追加…", "Add Target…")) }.disabled(!canAdd)
            }
        }
        .padding(20)
    }

    private func rowView(_ row: TargetRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(verbatim: row.name).font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    if row.selected { Badge(text: tr("使用中", "In use"), color: .accentColor) }
                }
                if let h = row.hostNameLine {
                    Text(verbatim: h).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                HStack(spacing: 10) {
                    StatusLabel(symbol: row.symbol, text: row.status, color: row.confirmed ? .green : .orange)
                    Text(verbatim: row.lastOK).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text(verbatim: row.candidates).font(.system(size: 12)).foregroundStyle(.tertiary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityLabel)
            Spacer()
            if busyIDs.contains(row.id) {
                ProgressView().controlSize(.small)
            } else {
                // 3 つを横に並べると名前の欄が狭くなるため、2 行に分ける（名前・アドレス／削除）
                VStack(alignment: .trailing, spacing: 4) {
                    Button { onRename(row) } label: { Text(verbatim: tr("名前を変更…", "Rename…")) }
                    Button { onEdit(row.id) } label: { Text(verbatim: tr("アドレスを編集…", "Edit Addresses…")) }
                    Button { onRemove(row) } label: { Text(verbatim: tr("削除…", "Delete…")) }
                }
                .buttonStyle(.link).font(.system(size: 12))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

/// 接続先の名前を変更する窓（計画 2f-1 案 6）。この Mac の ShareScale だけの名前で、接続先の Mac の名前は変えない。空にすると接続先の名前に戻る
public struct RenameTargetSheet: View {
    let row: TargetRow
    let onSave: (String?) throws -> Void
    @State private var text: String
    @State private var problem: String?
    @State private var problemDetail: String?
    @Environment(\.dismiss) private var dismiss

    public init(row: TargetRow, onSave: @escaping (String?) throws -> Void) {
        self.row = row; self.onSave = onSave; _text = State(initialValue: row.alias ?? "")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: tr("「\(row.name)」の名前を変更", "Rename “\(row.name)”")).font(.system(size: 15, weight: .medium)).lineLimit(2)
            Text(verbatim: tr("この Mac の ShareScale で表示する名前です（接続先の Mac の名前は変わりません）。空にすると、接続先の名前「\(row.hostName)」に戻ります。",
                              "This name is shown only in ShareScale on this Mac (the Host’s own name doesn’t change). Leave it empty to use the Host’s name, “\(row.hostName)”."))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(text: $text, prompt: Text(verbatim: row.hostName)) { Text(verbatim: tr("名前", "Name")) }
                .font(.system(size: 13)).textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if let p = problem {
                VStack(alignment: .leading, spacing: 2) {
                    StatusLabel(symbol: "exclamationmark.triangle", text: p, color: .orange).fixedSize(horizontal: false, vertical: true)
                    if let d = problemDetail {
                        CopyButton(title: tr("詳細をコピー", "Copy Details"), text: d).buttonStyle(.link).font(.system(size: 12))
                    }
                }
            }
            HStack {
                Spacer()
                Button { dismiss() } label: { Text(verbatim: tr("キャンセル", "Cancel")) }.keyboardShortcut(.cancelAction)
                Button(action: save) { Text(verbatim: tr("保存", "Save")) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func save() {
        switch TargetAlias.validate(text, hostName: row.hostName) {
        case .failure: problem = TargetAlias.invalidMessage; problemDetail = nil
        case let .success(alias):
            do { try onSave(alias); dismiss() } catch {
                let p = ViewerTargets.saveProblem(error)
                problem = p.text; problemDetail = p.detail
            }
        }
    }
}

/// 接続先のアドレスを手動で設定する窓（`ManualCandidatesEditor`）。保存するのは候補・通信口・手で直した印の 3 つだけ（帳簿の今の値に当てる）
public struct CandidatesSheet: View {
    let name: String
    @State var editor: ManualCandidatesEditor
    let onSave: (ManualCandidatesEditor.Candidates) throws -> Void
    @State private var problem: String?
    @State private var problemDetail: String?
    @Environment(\.dismiss) private var dismiss

    public init(name: String, editor: ManualCandidatesEditor, onSave: @escaping (ManualCandidatesEditor.Candidates) throws -> Void) {
        self.name = name; _editor = State(initialValue: editor); self.onSave = onSave
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: tr("「\(name)」のアドレスを編集", "Edit Addresses for “\(name)”")).font(.system(size: 15, weight: .medium)).lineLimit(2)
            Text(verbatim: tr("ホスト名か IP アドレスを 1 行に 1 つずつ入力してください（最大 \(Limits.maxCandidateAddresses) 個）。手動で設定したアドレスは、自動では書き換わりません。",
                              "Enter one host name or IP address per line (up to \(Limits.maxCandidateAddresses)). Addresses you set manually aren’t changed automatically."))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(text: $editor.addressesText, prompt: Text(verbatim: "studio.local"), axis: .vertical) { Text(verbatim: tr("接続先のアドレス", "Addresses")) }
                .lineLimit(3...8).font(.system(size: 13, design: .monospaced)).textFieldStyle(.roundedBorder)
            HStack {
                Text(verbatim: tr("ポート", "Port")).font(.system(size: 12)).foregroundStyle(.secondary)
                TextField(text: $editor.portText, prompt: Text(verbatim: "47651")) { Text(verbatim: tr("ポート", "Port")) }
                    .font(.system(size: 13, design: .monospaced)).textFieldStyle(.roundedBorder).frame(width: 90)
            }
            if let p = problem {
                VStack(alignment: .leading, spacing: 2) {
                    StatusLabel(symbol: "exclamationmark.triangle", text: p, color: .orange).fixedSize(horizontal: false, vertical: true)
                    if let d = problemDetail {
                        CopyButton(title: tr("詳細をコピー", "Copy Details"), text: d)
                            .buttonStyle(.link).font(.system(size: 12))
                    }
                }
            }
            HStack {
                if editor.original.manual {
                    Button { save(editor.automatic) } label: { Text(verbatim: tr("自動に戻す", "Revert to Automatic")) }
                        .help(tr("手動で設定したアドレスをやめ、次に接続した時から、接続先が知らせるアドレスを使います。", "Stops using the manual addresses. The Host’s own addresses are used from the next connection."))
                }
                Spacer()
                Button { dismiss() } label: { Text(verbatim: tr("キャンセル", "Cancel")) }.keyboardShortcut(.cancelAction)
                Button {
                    switch editor.validate() {
                    case let .success(c): save(c)
                    case let .failure(p): problem = ManualCandidatesEditor.message(p); problemDetail = nil
                    }
                } label: { Text(verbatim: tr("保存", "Save")) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func save(_ c: ManualCandidatesEditor.Candidates) {
        do { try onSave(c); dismiss() } catch {
            let p = ViewerTargets.saveProblem(error)
            problem = p.text; problemDetail = p.detail
        }
    }
}

// MARK: - この Mac の接続先

/// タブ「この Mac の接続先」: 開いている間だけ `state.json` を 2 秒ごとに読み直す（`HostPanelStore.startPolling`。閉じたら止める）。
/// 「この Mac を接続先にする」は `LoginItemController`（ログイン項目の登録・解除。計画 2e-1）。開いた時にログイン項目の状態を読み直す
struct HostSettings: View {
    @ObservedObject var store: HostPanelStore
    @ObservedObject var loginItems: LoginItemController

    var body: some View {
        // 高さは中身に合わせ、画面に収まる上限で止める（前は `ScrollView` に上限だけを付けていて、最小の高さが 0 のため、
        // 窓が前のタブの高さのまま残った。計画 2h）
        SettingsPane {
            HostSettingsContent(panel: store.panel, hostSwitch: loginItems.model,
                                actionMessage: store.actionMessage, actionFailed: store.actionFailed, actionDetail: store.actionDetail,
                                onAction: { store.perform($0) },
                                onToggleHost: { on in
                                    // 画面に結び付かない Task（窓を閉じても登録の待ちを途中で捨てない）
                                    Task { await loginItems.setEnabled(on); store.reload() }
                                },
                                onOpenLoginItems: { loginItems.openLoginItems() },
                                onOpenSettings: { openSystemSettings($0) })
        }
        .onAppear { loginItems.refresh(); store.startPolling() }
        .onDisappear { store.stopPolling() }
    }
}

/// タブ「この Mac の接続先」の中身（DESIGN.md「この Mac の接続先」）
public struct HostSettingsContent: View {
    let panel: HostPanelModel
    let hostSwitch: HostSwitchModel
    let actionMessage: String?
    let actionFailed: Bool
    let actionDetail: String?
    let onAction: (HostPanelModel.Action) -> Void
    let onToggleHost: (Bool) -> Void
    let onOpenLoginItems: () -> Void
    /// 注意の「〜の設定を開く…」（計画 2f-1 案 5）
    let onOpenSettings: (DiagnosticAction) -> Void
    @State private var unpairing: HostPanelModel.Viewer?
    @State private var confirmingQuit = false
    @State private var confirmingGlobal = false
    @State private var confirmingHostOff = false

    public init(panel: HostPanelModel, hostSwitch: HostSwitchModel, actionMessage: String?, actionFailed: Bool, actionDetail: String?,
                onAction: @escaping (HostPanelModel.Action) -> Void, onToggleHost: @escaping (Bool) -> Void, onOpenLoginItems: @escaping () -> Void,
                onOpenSettings: @escaping (DiagnosticAction) -> Void) {
        self.panel = panel; self.hostSwitch = hostSwitch; self.actionMessage = actionMessage; self.actionFailed = actionFailed; self.actionDetail = actionDetail
        self.onAction = onAction; self.onToggleHost = onToggleHost; self.onOpenLoginItems = onOpenLoginItems; self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            addViewer
            hostSwitchView
            status
            viewers
            network
            HStack {
                Spacer()
                Button { confirmingQuit = true } label: { Text(verbatim: tr("ShareScale Host を終了…", "Quit ShareScale Host…")) }.disabled(!panel.canOperate)
            }
        }
        .padding(20)
        .confirmationDialog(tr("ShareScale Host を終了しますか？", "Quit ShareScale Host?"), isPresented: $confirmingQuit) {
            Button(role: .destructive) { onAction(.quit) } label: { Text(verbatim: tr("終了", "Quit")) }
        } message: {
            Text(verbatim: tr("終了すると、ShareScale Host をもう一度開くまで、ほかの Mac からこの Mac の表示倍率を変更できなくなります。", "Other Macs can’t change this Mac’s display scale until ShareScale Host runs again."))
        }
        .confirmationDialog(tr("「\(unpairing?.name ?? "")」の登録を解除しますか？", "Remove “\(unpairing?.name ?? "")”?"),
                            isPresented: Binding(get: { unpairing != nil }, set: { if !$0 { unpairing = nil } }), presenting: unpairing) { v in
            Button(role: .destructive) { onAction(.unpair(v.id)) } label: { Text(verbatim: tr("登録を解除", "Remove")) }
        } message: { _ in
            Text(verbatim: tr("登録を解除した Mac は、ペアリングし直すまでこの Mac に接続できません。", "That Mac can’t connect to this Mac until it’s paired again."))
        }
        .confirmationDialog(tr("この Mac を接続先にするのをやめますか？", "Stop using this Mac as a target?"), isPresented: $confirmingHostOff) {
            Button(role: .destructive) { onToggleHost(false) } label: { Text(verbatim: tr("オフにする", "Turn Off")) }
        } message: {
            Text(verbatim: tr("ShareScale Host を停止し、ログインしても起動しなくなります。接続元の Mac とのペアリングは残ります（オンに戻せばそのまま使えます）。",
                              "ShareScale Host stops and no longer starts at login. Pairings with the Macs to connect from are kept (turn it back on to use them)."))
        }
        .confirmationDialog(tr("インターネットからの接続も受け付けますか？", "Also accept connections from the internet?"), isPresented: $confirmingGlobal) {
            Button(role: .destructive) { onAction(.allowGlobal(true)) } label: { Text(verbatim: tr("受け付ける", "Accept")) }
        } message: {
            Text(verbatim: tr("同じネットワークの外（インターネット）からも、この Mac の ShareScale Host に接続できるようになります（ペアリングしていない Mac は接続できません）。通常はオフのままにしてください。",
                              "Macs outside your network (on the internet) will also be able to connect to ShareScale Host on this Mac (Macs that aren’t paired still can’t connect). Normally, keep this off."))
        }
    }

    private func copyButton(_ d: String) -> some View {
        CopyButton(title: tr("詳細をコピー", "Copy Details"), text: d)
            .buttonStyle(.link).font(.system(size: 12))
    }

    /// タブの上部の「接続元の Mac を追加…」（実機確認 2026-09-30: 見出しの右では見つけにくかった）。発行中のコードの期限もここに出す
    private var addViewer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Text(verbatim: tr("ほかの Mac からこの Mac の表示倍率を変えるには、その Mac を接続元として追加します。",
                                  "To let another Mac change this Mac’s display scale, add it as a Mac to connect from."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { onAction(.issueCode) } label: { Label(panel.issueCodeTitle, systemImage: "plus.circle") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!panel.canIssueCode)
            }
            if let c = panel.code { StatusLabel(symbol: "clock", text: c, color: .secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    /// 「この Mac を接続先にする」（ログイン項目。オフにする時だけ確かめる）
    private var hostSwitchView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { hostSwitch.isOn }, set: { on in if on { onToggleHost(true) } else { confirmingHostOff = true } })) {
                    Text(verbatim: tr("この Mac を接続先にする", "Use This Mac as a Target")).font(.system(size: 13, weight: .medium))
                }
                .toggleStyle(.switch)
                .disabled(!hostSwitch.canToggle)
                if hostSwitch.busy { ProgressView().controlSize(.small) }
            }
            Text(verbatim: hostSwitch.note).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if hostSwitch.needsApproval {
                Button(action: onOpenLoginItems) { Text(verbatim: tr("ログイン項目を開く…", "Open Login Items…")) }
                    .buttonStyle(.link).font(.system(size: 12))
            }
            if let r = hostSwitch.result {
                StatusLabel(symbol: hostSwitch.resultIsError ? "exclamationmark.triangle" : "checkmark.circle", text: r,
                            color: hostSwitch.resultIsError ? .orange : .green)
                    .fixedSize(horizontal: false, vertical: true)
                if let d = hostSwitch.resultDetail { copyButton(d) }
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: panel.symbol).font(.system(size: 20)).foregroundStyle(statusColor).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: panel.statusText).font(.system(size: 14, weight: .medium))
                    if let l = panel.listener { Text(verbatim: l).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    if let v = panel.version { Text(verbatim: v).font(.system(size: 11)).foregroundStyle(.tertiary) }
                }
                .accessibilityElement(children: .combine)
                Spacer()
                Button { onAction(panel.pauseAction) } label: { Text(verbatim: panel.pauseTitle) }.disabled(!panel.canOperate)
            }
            if let g = panel.guidance { Text(verbatim: g).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let d = panel.guidanceDetail { copyButton(d) }
            // 操作の結果の一言は、押したボタンの近く（このカードの中）に出す（画面の最下部では見落とした。計画 2f-1）
            if let m = actionMessage {
                VStack(alignment: .leading, spacing: 2) {
                    StatusLabel(symbol: actionFailed ? "exclamationmark.triangle" : "checkmark.circle", text: m, color: actionFailed ? .orange : .green)
                        .fixedSize(horizontal: false, vertical: true)
                    if let d = actionDetail { copyButton(d) }
                }
            }
            ForEach(panel.noticeItems, id: \.self) { n in
                VStack(alignment: .leading, spacing: 2) {
                    StatusLabel(symbol: "exclamationmark.triangle", text: n.text, color: .orange).fixedSize(horizontal: false, vertical: true)
                    if let a = n.action {
                        Button { onOpenSettings(a) } label: { Text(verbatim: a.title(AppLanguage.current.host)) }
                            .buttonStyle(.link).font(.system(size: 12)).padding(.leading, 17)
                    }
                }
            }
        }
        .padding(16)
        .cardStyle()
    }

    private var statusColor: Color {
        switch panel.status {
        case .running: return .green
        case .paused, .unknown: return .secondary
        case .stopped: return .orange
        }
    }

    private var viewers: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: tr("接続元の Mac", "Macs Allowed to Connect")).font(.system(size: 13, weight: .medium))
            if panel.viewers.isEmpty {
                Text(verbatim: tr("接続元の Mac はまだありません。", "No Macs added yet.")).font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12).cardStyle()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(panel.viewers.enumerated()), id: \.element.id) { i, v in
                        if i > 0 { Divider().padding(.leading, 12) }
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: v.title).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                                Text(verbatim: v.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .ignore).accessibilityLabel(v.accessibilityLabel)
                            Spacer()
                            HStack(spacing: 12) {
                                if v.stale { Button { onAction(.snooze(v.id)) } label: { Text(verbatim: tr("あとで", "Later")) } }
                                Button { unpairing = v } label: { Text(verbatim: tr("登録を解除…", "Remove…")) }
                            }
                            .buttonStyle(.link).font(.system(size: 12)).disabled(!panel.canOperate)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                    }
                }
                .cardStyle()
            }
        }
    }

    private var network: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: tr("接続を受け付けるネットワーク", "Networks to Accept Connections From")).font(.system(size: 13, weight: .medium))
            Text(verbatim: HostPanelModel.defaultNetworkNote)
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: Binding(get: { panel.tailscaleOnly }, set: { onAction(.tailscaleOnly($0)) })) {
                Text(verbatim: tr("Tailscale からの接続だけを受け付ける", "Accept connections from Tailscale only")).font(.system(size: 13))
            }
            .disabled(!panel.canOperate)
            // オンにする時だけ確かめる（オフにする時は確かめない）
            Toggle(isOn: Binding(get: { panel.allowGlobal }, set: { on in if on { confirmingGlobal = true } else { onAction(.allowGlobal(false)) } })) {
                Text(verbatim: tr("インターネットからの接続も受け付ける", "Also accept connections from the internet")).font(.system(size: 13))
            }
            .disabled(!panel.canOperate)
            Text(verbatim: tr("通常はオフのままにしてください。オンにすると、同じネットワークの外（インターネット）からの接続も受け付けます（ペアリングしていない Mac は接続できません）。",
                              "Normally, keep this off. When it’s on, connections from outside your network (the internet) are also accepted (Macs that aren’t paired still can’t connect)."))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 一般

/// タブ「一般」の組み立て（「ShareScale を取り除く…」は取り除きの窓を開く）
struct GeneralUninstallSettings: View {
    let version: String
    @ObservedObject var uninstall: UninstallFlow
    /// ログイン項目の処理中は押せない表示にするため、こちらも見る（再点検 軽微 8）
    @ObservedObject var loginItems: LoginItemController
    @ObservedObject var notifications: ViewerNotifications
    @ObservedObject var appearance: AppearanceSettings
    @ObservedObject var openAtLogin: OpenAtLoginController
    let onGuide: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SettingsPane {
            GeneralSettings(version: version, uninstallAvailable: uninstall.available, uninstallNote: uninstall.note,
                            notifications: notifications.model, appearance: appearance.model, openAtLogin: openAtLogin.model,
                            onToggleNotifications: { on in Task { await notifications.setEnabled(on) } },
                            onNotificationKind: { kind, on in notifications.setKind(kind, on) },
                            onOpenNotificationSettings: { openSystemSettings(.openNotificationSettings) },
                            onShowsInDock: { appearance.setShowsInDock($0) },
                            onHostIconAlwaysVisible: { appearance.setHostIconAlwaysVisible($0) },
                            onOpenAtLogin: { openAtLogin.setEnabled($0) },
                            onOpenLoginItems: { openAtLogin.openLoginItems() },
                            onGuide: onGuide,
                            onUninstall: { uninstall.begin(); openWindow(id: WindowID.uninstall) })
        }
            // 開いた時に許可の状態とログイン項目を読み直す（求めはしない。システム設定で変えた後に開き直した時のため）
            .onAppear {
                openAtLogin.refresh()
                Task { await notifications.refreshAuthorization() }
            }
    }
}

/// タブ「一般」: 言語は OS に従う旨・版・置き場所・「はじめに…」とメニューバーと Dock とログイン時に開く（計画 2f-2）・通知（計画 2f-1 案 7）・
/// 「ShareScale を取り除く…」（複製だけ。計画 2e-1）
public struct GeneralSettings: View {
    let version: String
    let uninstallAvailable: Bool
    let uninstallNote: String
    let notifications: NotificationSettingsModel
    let appearance: AppearanceModel
    let openAtLogin: OpenAtLoginModel
    let onToggleNotifications: (Bool) -> Void
    let onNotificationKind: (ChangeNotificationKind, Bool) -> Void
    let onOpenNotificationSettings: () -> Void
    let onShowsInDock: (Bool) -> Void
    let onHostIconAlwaysVisible: (Bool) -> Void
    let onOpenAtLogin: (Bool) -> Void
    let onOpenLoginItems: () -> Void
    let onGuide: () -> Void
    let onUninstall: () -> Void
    public init(version: String, uninstallAvailable: Bool, uninstallNote: String, notifications: NotificationSettingsModel,
                appearance: AppearanceModel, openAtLogin: OpenAtLoginModel,
                onToggleNotifications: @escaping (Bool) -> Void, onNotificationKind: @escaping (ChangeNotificationKind, Bool) -> Void,
                onOpenNotificationSettings: @escaping () -> Void, onShowsInDock: @escaping (Bool) -> Void, onHostIconAlwaysVisible: @escaping (Bool) -> Void,
                onOpenAtLogin: @escaping (Bool) -> Void, onOpenLoginItems: @escaping () -> Void, onGuide: @escaping () -> Void,
                onUninstall: @escaping () -> Void) {
        self.version = version; self.uninstallAvailable = uninstallAvailable; self.uninstallNote = uninstallNote
        self.notifications = notifications; self.appearance = appearance; self.openAtLogin = openAtLogin
        self.onToggleNotifications = onToggleNotifications; self.onNotificationKind = onNotificationKind
        self.onOpenNotificationSettings = onOpenNotificationSettings; self.onShowsInDock = onShowsInDock; self.onHostIconAlwaysVisible = onHostIconAlwaysVisible
        self.onOpenAtLogin = onOpenAtLogin; self.onOpenLoginItems = onOpenLoginItems; self.onGuide = onGuide; self.onUninstall = onUninstall
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(tr("バージョン", "Version"), "ShareScale \(version)")
            row(tr("言語", "Language"), tr("macOS の言語設定に従います（優先する言語の並びで、日本語と英語のうち上にある方で表示します。どちらも無い場合は英語です）。変更するには、システム設定 › 一般 › 言語と地域を開いてください。",
                                            "Follows the macOS language setting (Japanese or English, whichever comes first in your preferred languages; English if neither is listed). To change it, open System Settings › General › Language & Region."))
            row(tr("ファイルの場所", "Files"), tr("ペアリングの鍵: ~/Library/Application Support/ShareScale/pairings/viewer/\n環境設定: ~/Library/Preferences/io.github.taki-0105a.ShareScale.plist",
                                          "Pairing keys: ~/Library/Application Support/ShareScale/pairings/viewer/\nPreferences: ~/Library/Preferences/io.github.taki-0105a.ShareScale.plist"))
            Divider()
            HStack(alignment: .top) {
                // 見出しを付ける（ほかの行と同じ形。点検 2f-2）
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: tr("はじめに", "Getting Started")).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(verbatim: tr("ShareScale でしたいことを選んで、必要な準備を順に確認できます。", "Choose what you want to do with ShareScale and go through the setup step by step."))
                        .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                Spacer()
                Button(action: onGuide) { Text(verbatim: tr("はじめに…", "Getting Started…")) }
            }
            Divider()
            menuBarSection
            Divider()
            notificationSection
            Divider()
            HStack(alignment: .top) {
                Text(verbatim: uninstallNote).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(action: onUninstall) { Text(verbatim: tr("ShareScale を完全に削除…", "Remove ShareScale Completely…")) }.disabled(!uninstallAvailable)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    /// メニューバーと Dock・ログイン時に開く（計画 2f-2 案 1・2）
    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            toggle(tr("Dock に表示する", "Show in Dock"), isOn: appearance.showsInDock, note: appearance.dockNote, enabled: true, action: onShowsInDock)
            VStack(alignment: .leading, spacing: 4) {
                toggle(tr("ログイン時に ShareScale を開く", "Open ShareScale at Login"), isOn: openAtLogin.isOn, note: openAtLogin.note,
                       enabled: openAtLogin.canToggle, action: onOpenAtLogin)
                if openAtLogin.needsApproval {
                    Button(action: onOpenLoginItems) { Text(verbatim: tr("ログイン項目を開く…", "Open Login Items…")) }
                        .buttonStyle(.link).font(.system(size: 12))
                }
                if let r = openAtLogin.result {
                    StatusLabel(symbol: "exclamationmark.triangle", text: r, color: .orange).fixedSize(horizontal: false, vertical: true)
                    if let d = openAtLogin.resultDetail {
                        CopyButton(title: tr("詳細をコピー", "Copy Details"), text: d).buttonStyle(.link).font(.system(size: 12))
                    }
                }
            }
            toggle(tr("ShareScale Host のアイコンを常にメニューバーに表示する", "Always Show ShareScale Host’s Icon in the Menu Bar"),
                   isOn: appearance.hostIconAlwaysVisible, note: appearance.hostIconNote, enabled: true, action: onHostIconAlwaysVisible)
        }
    }

    private func toggle(_ title: String, isOn: Bool, note: String, enabled: Bool, action: @escaping (Bool) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { isOn }, set: { action($0) })) { Text(verbatim: title).font(.system(size: 13, weight: .medium)) }
                .toggleStyle(.switch)
                .disabled(!enabled)
            Text(verbatim: note).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 通知（既定はオフ。オンにした時に初めて macOS が許可を求める）
    private var notificationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { notifications.isOn }, set: { onToggleNotifications($0) })) {
                    Text(verbatim: tr("表示倍率や接続の変化を通知する", "Notify Me About Changes")).font(.system(size: 13, weight: .medium))
                }
                .toggleStyle(.switch)
                .disabled(!notifications.canToggle)
                if notifications.busy { ProgressView().controlSize(.small) }
            }
            Text(verbatim: notifications.note).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(ChangeNotificationKind.offered, id: \.self) { k in
                    Toggle(isOn: Binding(get: { notifications.kinds[k] ?? false }, set: { onNotificationKind(k, $0) })) {
                        Text(verbatim: k.settingLabel).font(.system(size: 13))
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .disabled(!notifications.isOn)
            .padding(.leading, 4)
            if let p = notifications.problem {
                StatusLabel(symbol: "exclamationmark.triangle", text: p, color: .orange).fixedSize(horizontal: false, vertical: true)
                Button(action: onOpenNotificationSettings) { Text(verbatim: DiagnosticAction.openNotificationSettings.title(AppLanguage.current.host)) }
                    .buttonStyle(.link).font(.system(size: 12))
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: label).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(verbatim: value).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
