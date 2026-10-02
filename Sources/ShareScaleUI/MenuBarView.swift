import AppKit
import ShareScaleCore
import ShareScaleHostCore
import ShareScaleProtocol
import SwiftUI

/// 設定の窓のタブ（メニューバーの「この Mac の接続先の設定…」で 2 つ目を開く。計画 2f-2）
public enum SettingsTab: Hashable, Sendable { case targets, host, general }

/// 窓を開く口（メニューバー・`AppDelegate`・ガイドから。計画 2f-2 案 1）。
/// SwiftUI の `openWindow`・`openSettings` は画面の中からしか取れないため、メニューバーのアイコン（`MenuBarLabel`。アプリが動いている間ずっとある）が
/// 表示された時に受け取って持つ。Dock に出していない時も前に出すため、開く前に `NSApp.activate()` する
@MainActor
public final class AppRouter: ObservableObject {
    @Published public var settingsTab: SettingsTab = .targets
    /// 主の窓に「接続先を追加」を開かせる（主の窓が受け取ったら下ろす。窓が閉じていた時は、開いた時に受け取る）
    @Published public private(set) var addTargetPending = false
    /// メニューを開いた回数（開くたびに項目を作り直させる）
    @Published public private(set) var menuRevision = 0
    public func noteMenuOpened() { menuRevision &+= 1 }
    private var openWindowAction: OpenWindowAction?
    private var openSettingsAction: OpenSettingsAction?
    public init() {}

    func install(openWindow: OpenWindowAction, openSettings: OpenSettingsAction) {
        openWindowAction = openWindow; openSettingsAction = openSettings
    }
    public func openMain() {
        NSApp.activate()
        openWindowAction?(id: WindowID.main)
    }
    public func openSettings(_ tab: SettingsTab? = nil) {
        if let tab { settingsTab = tab }
        NSApp.activate()
        openSettingsAction?()
    }
    public func openDiagnostics() {
        NSApp.activate()
        openWindowAction?(id: WindowID.diagnostics)
    }
    /// 主の窓を開き、「接続先を追加」の窓を出す
    public func requestAddTarget() {
        addTargetPending = true
        openMain()
    }
    /// 主の窓が受け取る（頼まれていれば真を返して下ろす）
    func takeAddTargetRequest() -> Bool {
        guard addTargetPending else { return false }
        addTargetPending = false
        return true
    }
}

/// メニューバーのアイコン（`MenuBarExtra` の label）。表示された時に窓を開く口を `AppRouter` に渡す
public struct MenuBarLabel: View {
    let router: AppRouter
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    public init(router: AppRouter) { self.router = router }
    public static let symbol = "rectangle.and.arrow.up.right.and.arrow.down.left"
    public var body: some View {
        // Host（`rectangle.on.rectangle`）と見分けられる記号（画面と倍率の矢印。両方のアイコンが並んだ時に迷わないように。点検 2f-2）
        Image(systemName: MenuBarLabel.symbol)
            .accessibilityLabel(Text(verbatim: "ShareScale"))
            .onAppear { router.install(openWindow: openWindow, openSettings: openSettings) }
    }
}

/// メニューバーのメニューの中身（`MenuBarExtra` の `.menu` の形。項目は `ViewerMenu.items`。計画 2f-2 案 1・2）。
/// 倍率・更新は画面に結び付かない Task から呼ぶ（`.task {}` は使わない。2d-1「2d-2 への注記」）
public struct ViewerMenuBar: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var targets: ViewerTargets
    @ObservedObject var host: HostPanelStore
    /// メニューを開くたびに `menuRevision` が変わり、項目（残り時間など）を今の時刻で作り直す（点検 2f-2）
    @ObservedObject var router: AppRouter
    /// 新しい版の知らせ（点検 2f-2）
    @ObservedObject var updates: UpdateWatcher
    let onUpdate: () -> Void
    let onQuit: () -> Void

    public init(model: ViewerModel, targets: ViewerTargets, host: HostPanelStore, router: AppRouter, updates: UpdateWatcher,
                onUpdate: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.model = model; self.targets = targets; self.host = host; self.router = router; self.updates = updates
        self.onUpdate = onUpdate; self.onQuit = onQuit
    }

    public var body: some View {
        let _ = router.menuRevision
        ViewerMenuContent(items: ViewerMenu.items(model: model, targets: targets.rows, canAddTarget: targets.canAdd, host: host.menuSection,
                                                  updateAvailable: updates.pending != nil, now: Date()),
                          onUpdate: onUpdate,
                          onAddTarget: { router.requestAddTarget() },
                          onChoose: { mode, id in
                              guard let d = model.displays.first(where: { $0.id == id }) else { return }
                              Task { await model.choose(mode, for: d) }
                          },
                          onRefresh: { Task { await model.refresh(force: true) } },
                          onSelectTarget: { targets.select($0) },
                          onOpenMain: { router.openMain() },
                          onSettings: { router.openSettings() },
                          onHost: { host.perform($0, report: false) },
                          onHostSettings: { router.openSettings(.host) },
                          onQuit: onQuit)
    }
}

/// メニューの中身を並べる（値と操作だけ）
public struct ViewerMenuContent: View {
    let items: [ViewerMenuItem]
    let onUpdate: () -> Void
    let onAddTarget: () -> Void
    let onChoose: (DisplayMode, UInt32) -> Void
    let onRefresh: () -> Void
    let onSelectTarget: (PairingID) -> Void
    let onOpenMain: () -> Void
    let onSettings: () -> Void
    let onHost: (HostPanelModel.Action) -> Void
    let onHostSettings: () -> Void
    let onQuit: () -> Void

    public init(items: [ViewerMenuItem], onUpdate: @escaping () -> Void, onAddTarget: @escaping () -> Void, onChoose: @escaping (DisplayMode, UInt32) -> Void,
                onRefresh: @escaping () -> Void, onSelectTarget: @escaping (PairingID) -> Void, onOpenMain: @escaping () -> Void,
                onSettings: @escaping () -> Void, onHost: @escaping (HostPanelModel.Action) -> Void, onHostSettings: @escaping () -> Void,
                onQuit: @escaping () -> Void) {
        self.items = items; self.onUpdate = onUpdate; self.onAddTarget = onAddTarget; self.onChoose = onChoose; self.onRefresh = onRefresh
        self.onSelectTarget = onSelectTarget; self.onOpenMain = onOpenMain; self.onSettings = onSettings; self.onHost = onHost
        self.onHostSettings = onHostSettings; self.onQuit = onQuit
    }

    public var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            row(item)
        }
    }

    @ViewBuilder private func row(_ item: ViewerMenuItem) -> some View {
        switch item {
        case let .target(name, symbol):
            Label { Text(verbatim: name) } icon: { Image(systemName: symbol) }
        case let .status(symbol, text):
            Label { Text(verbatim: text) } icon: { Image(systemName: symbol) }
        case let .note(text):
            Text(verbatim: text)
        case let .addTarget(title, enabled):
            Button(action: onAddTarget) { Text(verbatim: title) }.disabled(!enabled)
        case let .display(id, title, choices):
            Section(title) {
                ForEach(choices, id: \.mode) { c in
                    // チェックの付いた項目を選び直しても、そのディスプレイの倍率を適用する（カードのクリックと同じ）
                    Toggle(isOn: Binding(get: { c.checked }, set: { _ in onChoose(c.mode, id) })) { Text(verbatim: c.title) }
                        .disabled(!c.enabled)
                }
            }
        case let .refresh(title, enabled):
            Button(action: onRefresh) { Text(verbatim: title) }.disabled(!enabled)
        case let .switchTarget(title, choices):
            Menu(title) {
                ForEach(choices, id: \.id) { c in
                    Toggle(isOn: Binding(get: { c.checked }, set: { _ in onSelectTarget(c.id) })) { Text(verbatim: c.title) }
                }
            }
        case let .openMain(title):
            Button(action: onOpenMain) { Text(verbatim: title) }
        case let .settings(title):
            Button(action: onSettings) { Text(verbatim: title) }.keyboardShortcut(",", modifiers: .command)
        case let .host(title, entries, settings):
            Section(title) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, e in hostRow(e) }
                Button(action: onHostSettings) { Text(verbatim: settings) }
            }
        case let .quit(title):
            Button(action: onQuit) { Text(verbatim: title) }.keyboardShortcut("q", modifiers: .command)
        case let .update(note, action):
            Text(verbatim: note)
            Button(action: onUpdate) { Text(verbatim: action) }
        case .separator:
            Divider()
        }
    }

    /// 「この Mac の接続先」の節の 1 行（Host のメニューと同じ項目。押すと host-control の指示を置く）
    @ViewBuilder private func hostRow(_ e: MenuEntry) -> some View {
        switch e {
        case let .status(s), let .notice(s):
            Text(verbatim: s)
        case let .addViewer(title, enabled):
            Button { onHost(.issueCode) } label: { Text(verbatim: title) }.disabled(!enabled)
        case let .showCode(title):
            Button { onHost(.showCode) } label: { Text(verbatim: title) }
        case let .pause(title, resume):
            Button { onHost(resume ? .resume : .pause) } label: { Text(verbatim: title) }
        case let .diagnostics(title):
            Button { onHost(.showDiagnostics) } label: { Text(verbatim: title) }
        case let .reviewViewers(title):
            Button(action: onHostSettings) { Text(verbatim: title) }
        case .viewer, .openLog, .quit, .separator:
            EmptyView()   // `MenuModel.companion` は出さない
        }
    }
}
