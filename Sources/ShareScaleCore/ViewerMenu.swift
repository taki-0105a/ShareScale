import Foundation
import ShareScaleHostCore
import ShareScaleProtocol

/// ShareScale.app のメニューバーの項目（計画 2f-2 案 1・2。純粋な値）。SwiftUI の `MenuBarExtra`（`.menu` の形）はこれを並べるだけで、
/// 書き出し（`ShareScaleSnapshots`）は文字の一覧にする（`ImageRenderer` はメニューを描けないため）
public enum ViewerMenuItem: Equatable, Sendable {
    /// 使っている接続先の名前（押せない。機種の記号）
    case target(name: String, symbol: String)
    /// 接続の状態の 1 行（押せない。記号と文字。色だけで示さない）
    case status(symbol: String, text: String)
    /// 押せない 1 行（「接続先がまだありません」）
    case note(String)
    case addTarget(title: String, enabled: Bool)
    /// ディスプレイ 1 つ分（見出しはディスプレイの名前、項目は「1x 等倍」「2x Retina」。今の選択に ✓）
    case display(id: UInt32, title: String, choices: [ScaleChoice])
    case refresh(title: String, enabled: Bool)
    /// 接続先の切り替え（2 件以上の時だけ。サブメニュー。使っているものに ✓）
    case switchTarget(title: String, choices: [TargetChoice])
    case openMain(String)
    case settings(String)
    /// 「この Mac の接続先」の節（この Mac で Host が動いている時だけ）。項目は Host のメニューと同じ（`MenuModel.companion`）で、
    /// 最後に「この Mac の接続先の設定…」
    case host(title: String, entries: [MenuEntry], settings: String)
    case quit(String)
    /// 新しい版がある（点検 2f-2。押すと終了して Homebrew 側を開き、切り替える）
    case update(note: String, action: String)
    case separator

    public struct ScaleChoice: Equatable, Sendable {
        public let mode: DisplayMode
        public let title: String
        public let checked: Bool
        public let enabled: Bool
    }
    public struct TargetChoice: Equatable, Sendable {
        public let id: PairingID
        public let title: String
        public let checked: Bool
    }
}

/// メニューバーの項目の組み立て（`ViewerModel`・接続先の一覧・Host の様子から）
public enum ViewerMenu {
    /// 「この Mac の接続先」の節に出すもの（`HostPanelStore.menuSection`。Host が動いていなければ nil）
    public enum HostSection: Equatable, Sendable {
        /// 動いている。`outdated` はアプリより古い版の Host（移り変わりの途中。新しい指示 `show_code`・`show_diagnostics` を知らない。点検 2f-2）
        case running(HostMenuFacts, outdated: Bool)
        /// Host のプロセスは動いているが `state.json` を読めない（`.unknown`。点検 2f-2）。10 秒続くと受け持ちを外して Host にアイコンを戻させる（再点検）
        case unreadable
        /// 起動の途中（プロセスはあるが、まだ `state.json` を書いていない。再点検 2f-2）
        case starting
        /// 終了の途中（プロセスはあるが、`state.json` が `running:false`。再点検 2f-2）
        case stopping
    }

    /// - `host`: この Mac の Host の様子（`HostPanelStore.menuSection`）
    /// - `now`: 壁時計（コードの残り時間。メニューを開くたびに今の時刻で作る）
    @MainActor
    /// - `updateAvailable`: 新しい版がある（`UpdateWatcher.pending`）。いちばん上に知らせと「ShareScale を終了して開き直す…」を出す
    public static func items(model: ViewerModel, targets: [TargetRow], canAddTarget: Bool, host: HostSection?, updateAvailable: Bool = false,
                             now: Date) -> [ViewerMenuItem] {
        var out: [ViewerMenuItem] = []
        if updateAvailable {
            out.append(.update(note: tr("新しいバージョンがあります", "A new version is available"), action: UpdateWatcher.actionTitle))
            out.append(.separator)
        }
        if model.hasTarget {
            out.append(.target(name: model.title, symbol: RemoteMacKind(model: model.targetModel).symbol))
            out.append(status(model))
            out.append(.separator)
            for d in model.displays {
                let chosen = model.chosenMode(for: d)
                out.append(.display(id: d.id, title: d.name, choices: [DisplayMode.x1, .x2].map {
                    // 取り直しの間も押せる（`choose` は処理中なら終わった後に送る。開いた直後の取り直しで灰色にしない。点検 2f-2）
                    ViewerMenuItem.ScaleChoice(mode: $0, title: DataSaving.optionLabel($0), checked: $0 == chosen, enabled: true)
                }))
            }
            out.append(.refresh(title: tr("更新", "Refresh"), enabled: !model.busy))
            if targets.count > 1 {
                out.append(.switchTarget(title: tr("接続先を切り替える", "Switch Target"),
                                         choices: targets.map { ViewerMenuItem.TargetChoice(id: $0.id, title: $0.name, checked: $0.selected) }))
            }
        } else {
            out.append(.note(tr("接続先がまだありません", "No targets yet")))
            out.append(.addTarget(title: tr("接続先を追加…", "Add Target…"), enabled: canAddTarget))
        }
        out.append(.separator)
        out.append(.openMain(tr("ShareScale を開く", "Open ShareScale")))
        out.append(.settings(tr("設定…", "Settings…")))
        if let h = host {
            out.append(.separator)
            out.append(.host(title: tr("この Mac の接続先", "This Mac as a Target"), entries: hostEntries(h, now: now),
                             settings: tr("この Mac の接続先の設定…", "Settings for This Mac as a Target…")))
        }
        out.append(.separator)
        out.append(.quit(tr("ShareScale を終了", "Quit ShareScale")))
        return out
    }

    /// 「この Mac の接続先」の節の項目。読めない時は 1 行だけ（設定へ）。古い版の Host には、知らない指示の項目（「接続コードを表示…」「診断…」）を出さず、切り替え方の 1 行を添える
    static func hostEntries(_ h: HostSection, now: Date) -> [MenuEntry] {
        switch h {
        case .unreadable:
            return [.status(tr("ShareScale Host の状態を読み取れません", "Can’t read ShareScale Host’s state"))]
        case .starting:
            return [.status(tr("ShareScale Host を起動しています…", "ShareScale Host is starting…"))]
        case .stopping:
            return [.status(tr("ShareScale Host を終了しています…", "ShareScale Host is quitting…"))]
        case let .running(f, outdated):
            let entries = MenuModel.companion(f, now: now, language: AppLanguage.current.host)
            guard outdated else { return entries }
            return entries.filter { e in
                switch e {
                case .showCode, .diagnostics: return false
                case .status, .notice, .addViewer, .viewer, .pause, .reviewViewers, .openLog, .quit, .separator: return true
                }
            } + [.notice(tr("ShareScale Host が古いバージョンで動いています（ShareScale を終了して開き直すと切り替わります）",
                            "ShareScale Host is running an older version (quit and reopen ShareScale to switch)"))]
        }
    }

    /// 接続の状態の 1 行（主の窓の見出しのバッジと同じ言葉。一時停止中はそれを先に言う）。
    /// 一時停止の間に倍率を選んで断られた時も「接続できません」にしない（接続はできている。`ViewerModel.connection`・`hostPaused`。計画 2i）
    @MainActor
    static func status(_ model: ViewerModel) -> ViewerMenuItem {
        switch model.connection {
        case .checking: return .status(symbol: "ellipsis.circle", text: tr("確認しています…", "Checking…"))
        case .failed: return .status(symbol: "exclamationmark.triangle", text: tr("接続できません", "Can’t connect"))
        case .connected, .disconnected:
            if model.hostPaused { return .status(symbol: "pause.circle", text: tr("一時停止中（表示倍率を変更しません）", "Paused (the display scale isn’t changed)")) }
            return model.connection == .connected
                ? .status(symbol: "checkmark.circle", text: tr("画面共有で接続中", "Connected with Screen Sharing"))
                : .status(symbol: "info.circle", text: tr("画面共有は未接続", "Screen Sharing not connected"))
        }
    }
}
