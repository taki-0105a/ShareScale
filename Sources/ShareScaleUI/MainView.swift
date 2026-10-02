import ShareScaleCore
import ShareScaleProtocol
import SwiftUI

/// 窓の識別子（`Window(id:)` と `openWindow(id:)` で使う）
public enum WindowID {
    public static let main = "main"
    public static let diagnostics = "diagnostics"
    public static let uninstall = "uninstall"
}

/// 主の窓（接続先の切り替え・接続先の追加の窓・診断の窓を開く口を持つ）。中身は `MainContent`
public struct MainWindow: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var targets: ViewerTargets
    /// この Mac の ShareScale Host（動いていれば、接続先が無い時の案内に 1 行添える）
    @ObservedObject var host: HostPanelStore
    /// 起動時に複製元（Homebrew 側）が消えていたら「完全に削除しますか？」を問いかける（計画 2e-1）
    @ObservedObject var uninstall: UninstallFlow
    /// 初回のガイド（出している間は主の窓の中身の代わりに出す。計画 2f-2 案 3）
    @ObservedObject var guide: OnboardingGuide
    @ObservedObject var loginItems: LoginItemController
    /// メニューバーの「接続先を追加…」（計画 2f-2 案 1）
    @ObservedObject var router: AppRouter
    /// 新しい版の知らせ（点検 2f-2）と、押された時の切り替え（終了して Homebrew 側を開く）
    @ObservedObject var updates: UpdateWatcher
    let onUpdate: () -> Void
    let version: String
    let makeAddTarget: () -> AddTargetOpening   // 追加の窓は同時に 1 つだけ（開いていれば前面に出す）
    @State private var adding: AddTargetModel?
    @State private var alreadyOpen = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    public init(model: ViewerModel, targets: ViewerTargets, host: HostPanelStore, uninstall: UninstallFlow, guide: OnboardingGuide,
                loginItems: LoginItemController, router: AppRouter, updates: UpdateWatcher, onUpdate: @escaping () -> Void,
                version: String, makeAddTarget: @escaping () -> AddTargetOpening) {
        self.model = model; self.targets = targets; self.host = host; self.uninstall = uninstall; self.guide = guide; self.loginItems = loginItems
        self.router = router; self.updates = updates; self.onUpdate = onUpdate; self.version = version; self.makeAddTarget = makeAddTarget
    }

    public var body: some View {
        Group {
            if let flow = guide.flow {
                OnboardingPanel(guide: guide, host: host, loginItems: loginItems, flow: flow, canAddTarget: targets.canAdd,
                                onAddTarget: { openAddTarget(makeAddTarget(), adding: &adding, alreadyOpen: &alreadyOpen) })
            } else {
                MainContent(model: model, targets: targets.rows, storeNotice: targets.storeNotice, canAddTarget: targets.canAdd, addNote: targets.addNote,
                            hostRunningHere: host.panel.hostIsRunning, version: version,
                            onSelectTarget: { targets.select($0) },
                            onAddTarget: { openAddTarget(makeAddTarget(), adding: &adding, alreadyOpen: &alreadyOpen) },
                            onDiagnostics: { openWindow(id: WindowID.diagnostics) },
                            update: updates.notice, updateFailed: updates.failed, canUpdate: updates.pending != nil, onUpdate: onUpdate)
            }
        }
            // メニューバーの「接続先を追加…」（窓が閉じていた時は、開いた時に受け取る）。ガイドを出していれば閉じて追加の窓へ。
            // 窓を開く口もここで渡す（メニューバーのアイコンが表示された時だけに頼らない。点検 2f-2）
            .onAppear {
                router.install(openWindow: openWindow, openSettings: openSettings)
                takeAddTargetRequest()
            }
            // 窓の閉じるボタンでガイドを閉じた時も「あとで」と同じく見た印を付ける（点検 2f-2）
            .onDisappear { if guide.flow != nil { guide.close() } }
            .onChange(of: router.addTargetPending) { takeAddTargetRequest() }
            .sheet(item: $adding) { AddTargetSheet(model: $0) }
            .alreadyOpenAlert($alreadyOpen)
            .alert(tr("ShareScale は Homebrew から削除されています。この Mac からも完全に削除しますか？", "ShareScale was removed from Homebrew. Remove it completely from this Mac too?"),
                   isPresented: $uninstall.askAfterHomebrewRemoval) {
                Button { uninstall.begin(); openWindow(id: WindowID.uninstall) } label: { Text(verbatim: tr("完全に削除…", "Remove Completely…")) }
                Button(role: .cancel) {} label: { Text(verbatim: tr("あとで", "Later")) }
            } message: {
                Text(verbatim: tr("~/Applications の ShareScale と、ログイン項目・ペアリングの鍵・設定が残っています。Homebrew でアップデート中の場合は、アップデートが終わってから開き直してください。",
                                  "ShareScale in ~/Applications, its login item, pairing keys and settings are still on this Mac. If Homebrew is updating ShareScale, reopen it after the update finishes."))
            }
    }

    private func takeAddTargetRequest() {
        guard router.takeAddTargetRequest() else { return }
        if guide.flow != nil { guide.close() }
        openAddTarget(makeAddTarget(), adding: &adding, alreadyOpen: &alreadyOpen)
    }
}

/// 主の窓の中身（カードの画面。DESIGN.md「主の窓」）。
/// ヘッダ（接続先の名前・機種の記号・状態・接続のバッジ。接続先が複数なら名前を押すと切り替えのメニュー）、案内、カード（busy 中は無効の見た目）、
/// フッタ（版・表示倍率を自動で保つか・設定・更新）。接続先が未登録なら、カードの代わりに「接続先を追加」を案内する大きなボタン。
/// `refresh`・`apply` は画面に結び付かない Task から呼ぶ（`.task {}` は使わない。2d-1「2d-2 への注記」）
public struct MainContent: View {
    @ObservedObject var model: ViewerModel
    let targets: [TargetRow]
    let storeNotice: ViewerNotice.Text?
    let canAddTarget: Bool
    /// 追加を押せない時の理由（帳簿が使えない・上限）。未登録の案内の説明の代わりに出す
    let addNote: String
    /// この Mac で ShareScale Host が動いている（接続先が無い時の案内に「設定 › この Mac の接続先」の 1 行を添える。実機確認 2026-09-30）
    let hostRunningHere: Bool
    let version: String
    let onSelectTarget: (PairingID) -> Void
    let onAddTarget: () -> Void
    let onDiagnostics: () -> Void
    /// 新しい版がある時の知らせ（`UpdateWatcher.notice`。点検 2f-2）と、「ShareScale を終了して開き直す…」
    let update: ViewerNotice.Text?
    /// 切り替えられなかった（注意の見た目）・まだ切り替えられる新しい版がある（ボタンを出す。再点検 2f-2）
    let updateFailed: Bool
    let canUpdate: Bool
    let onUpdate: () -> Void
    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 12)]

    public init(model: ViewerModel, targets: [TargetRow], storeNotice: ViewerNotice.Text?, canAddTarget: Bool, addNote: String, hostRunningHere: Bool = false,
                version: String, onSelectTarget: @escaping (PairingID) -> Void, onAddTarget: @escaping () -> Void, onDiagnostics: @escaping () -> Void,
                update: ViewerNotice.Text? = nil, updateFailed: Bool = false, canUpdate: Bool = true, onUpdate: @escaping () -> Void = {}) {
        self.model = model; self.targets = targets; self.storeNotice = storeNotice; self.canAddTarget = canAddTarget; self.addNote = addNote
        self.hostRunningHere = hostRunningHere; self.version = version
        self.onSelectTarget = onSelectTarget; self.onAddTarget = onAddTarget; self.onDiagnostics = onDiagnostics
        self.update = update; self.updateFailed = updateFailed; self.canUpdate = canUpdate; self.onUpdate = onUpdate
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let u = update {
                NoticeView(title: u.title, detail: u.detail, isError: updateFailed, extraAction: canUpdate ? (UpdateWatcher.actionTitle, onUpdate) : nil)
            }
            if model.hasTarget {
                if let n = model.notice {
                    NoticeView(title: n.title, detail: n.detail, isError: model.noticeIsWarning,
                               showsSettingsLink: model.suggestsSettings, copyableDetail: model.copyableDetail,
                               onDiagnostics: model.noticeIsWarning ? onDiagnostics : nil, action: model.noticeAction)
                } else if let n = storeNotice {
                    NoticeView(title: n.title, detail: n.detail, isError: true, onDiagnostics: onDiagnostics)
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.displays) { d in
                        DisplayCard(display: d,
                                    chosen: model.chosenMode(for: d),
                                    settingText: model.settingText(for: d),
                                    settingNote: model.settingNote(for: d),
                                    active: model.isActive(d),
                                    badge: model.badge(for: d),
                                    accessibilityLabel: model.accessibilityLabel(for: d),
                                    busy: model.busy,
                                    onApply: { Task { await model.applyChosen(for: d) } },
                                    onChoose: { m in Task { await model.choose(m, for: d) } })
                    }
                }
            } else {
                if let n = storeNotice { NoticeView(title: n.title, detail: n.detail, isError: true, onDiagnostics: onDiagnostics) }
                emptyState
            }
            footer
        }
        .padding(20)
        .frame(width: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: ヘッダ

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.hasTarget ? RemoteMacKind(model: model.targetModel).symbol : "rectangle.on.rectangle")
                .font(.system(size: 20)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                title
                // 接続先が無い時は、本文の「接続先がまだありません」と重ねないため 2 行目を出さない（実機確認 2026-09-30）。
                // 問い合わせに失敗した時も出さない（案内の見出しが言う。計画 2f-1）
                if model.hasTarget, let detail = model.headerDetail {
                    Text(verbatim: detail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            // 名前と状態を 1 つの読みにする。名前がメニューの時はメニューを押せるよう分けたまま
            .modifier(CombinedForAccessibility(enabled: targets.count <= 1))
            Spacer(minLength: 8)
            if model.hasTarget { badge }
        }
    }

    /// 見出しの名前。接続先が複数なら、押すと切り替えのメニュー（`TargetBook.selectedID`）
    @ViewBuilder private var title: some View {
        let name = model.hasTarget ? model.title : "ShareScale"
        if targets.count > 1 {
            Menu {
                ForEach(targets) { row in
                    Button { onSelectTarget(row.id) } label: {
                        if row.selected { Label(row.name, systemImage: "checkmark") } else { Text(verbatim: row.name) }
                    }
                    .accessibilityLabel(row.accessibilityLabel)
                }
                Divider()
                Button(action: onAddTarget) { Text(verbatim: tr("接続先を追加…", "Add Target…")) }.disabled(!canAddTarget)
            } label: {
                Text(verbatim: name).font(.system(size: 15, weight: .medium)).lineLimit(1).truncationMode(.tail)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 300, alignment: .leading)   // 長い名前はバッジを押し出さずに末尾を省く
            .accessibilityLabel(tr("接続先: \(name)。クリックすると切り替えられます", "Target: \(name). Click to switch"))
        } else {
            Text(verbatim: name).font(.system(size: 15, weight: .medium)).lineLimit(1).truncationMode(.tail)
        }
    }

    @ViewBuilder private var badge: some View {
        switch model.connection {
        case .checking: ProgressView().controlSize(.small).accessibilityLabel(tr("確認しています", "Checking"))
        case .failed: Badge(text: tr("接続できません", "Can’t connect"), color: .orange)
        case .connected: Badge(text: tr("接続中", "Connected"), color: .green)
        case .disconnected: Badge(text: tr("未接続", "Not connected"), color: .secondary)
        }
    }

    // MARK: 未登録

    /// 接続先が未登録: カードの代わりに「接続先を追加」を案内する（DESIGN.md「接続先がない時」）
    private var emptyState: some View {
        let n = model.notice
        return VStack(spacing: 10) {
            Image(systemName: "plus.circle").font(.system(size: 28)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(verbatim: n?.title ?? tr("接続先がまだありません", "No targets yet")).font(.system(size: 15, weight: .medium))
            // 押せない時は、押し方の説明の代わりに押せない理由（帳簿が使えない・上限）
            if let d = canAddTarget ? n?.detail : addNote {
                Text(verbatim: d).font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            // この Mac を接続先にもしている時だけ、Host の操作の場所を 1 行添える（メニューバーの記号が切り欠きに隠れることがあるため）
            if hostRunningHere {
                Text(verbatim: HostPanelModel.mainWindowHint).font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            Button(action: onAddTarget) { Text(verbatim: tr("接続先を追加…", "Add Target…")).padding(.horizontal, 8) }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAddTarget)
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    // MARK: フッタ

    private var footer: some View {
        HStack {
            // 1 行に並べると折り返すため、版と「表示倍率を自動で保つ」を 2 行に分ける（仕上げ 2026-09-30）
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "ShareScale \(version)")
                if model.hasTarget { Text(verbatim: model.footerText) }
            }
            .font(.system(size: 12)).foregroundStyle(.tertiary)
            Spacer()
            SettingsLink { Label(tr("設定", "Settings"), systemImage: "gearshape").font(.system(size: 13)) }
            Button { Task { await model.refresh(force: true) } } label: {
                Label(tr("更新", "Refresh"), systemImage: "arrow.clockwise").font(.system(size: 13))
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.busy || !model.hasTarget)
        }
        .padding(.top, 4)
        .overlay(alignment: .top) { Divider().offset(y: -8) }
    }
}

/// 見出しを 1 つの読みにまとめる（`enabled` の時だけ）
struct CombinedForAccessibility: ViewModifier {
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.accessibilityElement(children: .combine) } else { content }
    }
}

/// 「接続先を追加」の答えを画面に当てる（新しく開く・前面に出した・「すでに開いています」）
@MainActor func openAddTarget(_ o: AddTargetOpening, adding: inout AddTargetModel?, alreadyOpen: inout Bool) {
    switch o {
    case let .open(m): adding = m
    case .alreadyOpen: alreadyOpen = true
    case .shownExisting, .unavailable: break
    }
}

extension View {
    /// 追加の窓を前面に出せなかった時の短い知らせ
    func alreadyOpenAlert(_ shown: SwiftUI.Binding<Bool>) -> some View {   // ShareScaleProtocol にも Binding がある
        alert(Text(verbatim: tr("「接続先を追加」のウインドウはすでに開いています", "The Add Target window is already open")), isPresented: shown) {
            Button { shown.wrappedValue = false } label: { Text(verbatim: "OK") }
        } message: {
            Text(verbatim: tr("開いているウインドウで続けてください。", "Continue in the window that’s already open."))
        }
    }
}
