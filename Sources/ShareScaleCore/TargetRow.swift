import Foundation
import ShareScaleProtocol

/// 接続先の一覧の 1 行（設定の「接続先」と主の窓の切り替えのメニュー。純粋な値）。
/// 状態は色だけで示さない（記号 `symbol` と文字 `status` を並べる）
public struct TargetRow: Equatable, Identifiable, Sendable {
    public let id: PairingID
    public let name: String
    /// 使っている接続先（`selectedTarget`。帳簿に無ければ 1 件目）
    public let selected: Bool
    public let confirmed: Bool
    /// 状態の記号（SF Symbols の outline 系）と文字
    public let symbol: String
    public let status: String
    /// 前回つながった候補（無ければ「まだつながっていません」）
    public let lastOK: String
    /// 候補と通信口（手で直していればその旨）
    public let candidates: String
    public let manual: Bool
    /// 名前を付けている時だけ、接続先（Host）の名前の行（「接続先での名前: …」。計画 2f-1 案 6）
    public let hostNameLine: String?
    /// 名前の変更の窓に出す接続先の名前と、今付けている名前
    public let hostName: String
    public let alias: String?
    /// VoiceOver 用（名前・使っているか・状態・前回の候補）
    public let accessibilityLabel: String

    public init(_ e: TargetEntry, selected: Bool) {
        id = e.id
        name = e.displayName
        self.selected = selected
        confirmed = e.meta.confirmed
        symbol = e.meta.confirmed ? "checkmark.circle" : "exclamationmark.triangle"
        status = e.meta.confirmed ? tr("登録済み", "Registered") : tr("確認待ち", "Pending confirmation")
        lastOK = e.meta.lastOKAddress.map { tr("前回の接続: \($0)", "Last connected: \($0)") } ?? tr("まだ接続していません", "Not connected yet")
        manual = e.meta.manual
        hostName = e.hostName
        alias = e.meta.alias
        hostNameLine = e.meta.alias == nil ? nil : tr("接続先での名前: \(e.hostName)", "Name on the Host: \(e.hostName)")
        let list = e.meta.addresses.joined(separator: ", ")
        // 手動の印は見出しの側に付ける（末尾の「・手動で設定したアドレス」は「アドレス」が重なり、折り返して 1 語だけが次の行に行った。仕上げ 2026-09-30）
        candidates = (e.meta.manual ? tr("接続先のアドレス（手動で設定）: ", "Addresses (set manually): ") : tr("接続先のアドレス: ", "Addresses: "))
            + tr("\(list)（ポート \(e.meta.port)）", "\(list) (port \(e.meta.port))")
        accessibilityLabel = [name, hostNameLine, selected ? tr("使用中", "in use") : nil, status, lastOK].compactMap { $0 }.joined(separator: tr("、", ", "))
    }

    /// 表示名の順の一覧。`selected` は使っている接続先の id（`TargetBook.selected(in:)` と同じ決め方: 選んだものが帳簿に無ければ 1 件目）
    public static func rows(_ loaded: TargetBook.Loaded, selectedID: PairingID?) -> [TargetRow] {
        let used = selectedID.flatMap { loaded.entry($0)?.id } ?? loaded.entries.first?.id
        return loaded.sortedByName.map { TargetRow($0, selected: $0.id == used) }
    }

    /// 削除の確かめの文言
    public var removeConfirmation: ViewerNotice.Text {
        ViewerNotice.Text(tr("「\(name)」を削除しますか？", "Delete “\(name)”?"),
                          tr("接続先でこの Mac の登録を解除してから、この Mac に保存した鍵を削除します。もう一度使うには、ペアリングし直してください。",
                             "ShareScale removes this Mac on the Host, then deletes the key stored on this Mac. To use it again, pair again."))
    }
}

/// 接続先の削除の結果（`ViewerTargets.remove`）。本文は「何が起きたか＋何をすればよいか」だけで、生の理由は `copyable`（「詳細をコピー」）へ
public enum TargetRemoval: Equatable, Sendable {
    case removed(name: String)            // 接続先にも解除を伝えた
    case removedLocally(name: String)     // 届かなかった（この Mac だけで消した）
    case alreadyRemoved                   // 帳簿にもう無かった（ほかの窓で消した・ファイルが消えた）
    case failed(name: String, reason: String)

    public var message: ViewerNotice.Text {
        switch self {
        case let .removed(name):
            return ViewerNotice.Text(tr("「\(name)」を削除しました", "Deleted “\(name)”"), tr("接続先でも、この Mac の登録が解除されました。", "This Mac was also removed on the Host."))
        case let .removedLocally(name):
            return ViewerNotice.Text(tr("「\(name)」をこの Mac から削除しました", "Deleted “\(name)” from this Mac"),
                                     tr("接続先に接続できなかったため、接続先の ShareScale Host のメニューでも、この Mac の登録を解除してください。",
                                        "Couldn’t connect to the Host, so also remove this Mac in the ShareScale Host menu on the Host."))
        case .alreadyRemoved:
            return ViewerNotice.Text(tr("この接続先はすでに削除されています", "This target was already deleted"),
                                     tr("一覧を更新しました。", "The list was updated."))
        case let .failed(name, _):
            return ViewerNotice.Text(tr("「\(name)」を削除できませんでした", "Couldn’t delete “\(name)”"),
                                     tr("~/Library/Application Support/ShareScale/pairings/viewer/ のアクセス権を確認してから、もう一度削除してください。",
                                        "Check the permissions of ~/Library/Application Support/ShareScale/pairings/viewer/, then try deleting it again."))
        }
    }
    public var isError: Bool {
        switch self { case .removed, .alreadyRemoved: return false; case .removedLocally, .failed: return true }
    }
    /// 「詳細をコピー」に渡す生の理由（本文には出さない）
    public var copyable: String? { if case let .failed(_, reason) = self { return reason }; return nil }
}
