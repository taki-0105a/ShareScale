import Foundation
import ShareScaleHostCore
import ShareScaleProtocol

/// 見る側（画面では「接続元の Mac」）の診断（仕様「自己診断」の見る側）。順に:
/// ローカルネットワークの許可 → 届くか → ペアリングが有効か（未確定を含む）→ Host が動いているか → 画面共有中か →
/// 仮想ディスプレイを見分けたか → 倍率が設定どおりか → 直近の失敗。✓／✗／?（分からない）と対処。純粋な関数
public enum ViewerDiagnostics: Sendable {
    public enum Mark: String, Equatable, Sendable { case ok = "✓", bad = "✗", unknown = "?" }
    public struct Line: Equatable, Sendable {
        public let mark: Mark
        public let text: String
        public let advice: String?
        /// ✗ と ? の行の右に出す「〜の設定を開く…」（計画 2f-1 案 5。✓ の行には付けない）
        public let action: DiagnosticAction?
        public init(_ mark: Mark, _ text: String, advice: String? = nil, action: DiagnosticAction? = nil) {
            self.mark = mark; self.text = text; self.advice = advice; self.action = mark == .ok ? nil : action
        }
    }

    /// - `target`: 選んだ接続先（nil なら未登録）
    /// - `state`・`failure`: 直近の問い合わせの結果（`ViewerModel`）
    /// - `chosen`: 今の画面で選んでいる倍率（nil なら比べない）
    /// - `readProblems`: 帳簿で使えなかったファイルの数（`TargetBook.Loaded.problems`）
    public static func lines(target: TargetEntry?, state: RemoteState?, failure: ViewerFailure?, chosen: DisplayMode?, readProblems: Int = 0) -> [Line] {
        var out: [Line] = []
        // Host が照合済みの応答で断った時（一時停止中・処理中。`isRefusal`）は、接続もペアリングも通っていて、Host も動いている。
        // 接続できない失敗としては扱わず、5〜8 は直前の状態（あれば）で判定する（計画 2i。前は「接続先に接続できていないため…」「不明」と出ていた）
        let refused = failure?.isRefusal == true
        let lost = refused ? nil : failure
        let reached = refused || (lost == nil && state != nil)
        // 1. ローカルネットワークの許可（macOS 15 以降。届いていれば許可されている）
        switch failure {
        case .localNetworkDenied?:
            out.append(Line(.bad, tr("ローカルネットワーク: 許可されていません", "Local network: not allowed"),
                            advice: tr("システム設定 › プライバシーとセキュリティ › ローカルネットワークで ShareScale をオンにしてください。", "Turn on ShareScale in System Settings › Privacy & Security › Local Network."),
                            action: .openLocalNetworkSettings))
        case .unreachable?, .timedOut?, .cancelled?:
            out.append(Line(.unknown, tr("ローカルネットワーク: 不明（接続先に接続できていないため）", "Local network: unknown (couldn’t connect to the Host)")))
        case .handshakeFailed?, .notPaired?, .unsupportedVersion?, .paused?, .busy?, .other?:
            out.append(Line(.ok, tr("ローカルネットワーク: 許可されています（またはこの macOS では不要です）", "Local network: allowed (or not required on this macOS)")))
        case nil:
            if target == nil || state == nil {
                out.append(Line(.unknown, tr("ローカルネットワーク: 不明（まだ確認していません）", "Local network: unknown (not checked yet)")))
            } else {
                out.append(Line(.ok, tr("ローカルネットワーク: 許可されています（またはこの macOS では不要です）", "Local network: allowed (or not required on this macOS)")))
            }
        }
        // 2. 届くか
        switch failure {
        case .unreachable?:
            out.append(Line(.bad, tr("接続: 接続できません", "Connection: can’t connect to the Host"),
                            advice: tr("同じネットワーク（または Tailscale）に接続されているか、接続先のアドレスとポートが正しいかを確認してください。", "Make sure both Macs are on the same network (or Tailscale), and that the Host’s addresses and port are correct.")
                                + tr("", " ") + ViewerNotice.firewallHint))   // 案内と同じ文（1 か所の定義。計画 2i）
        case .timedOut?:
            out.append(Line(.bad, tr("接続: 応答がありません", "Connection: no reply"), advice: tr("少し待ってから「更新」をクリックしてください。", "Wait a moment, then click Refresh.")))
        case .localNetworkDenied?:
            out.append(Line(.bad, tr("接続: 試せません（ローカルネットワークへのアクセスが許可されていないため）", "Connection: not tried (local network access isn’t allowed)")))
        case .cancelled?:
            out.append(Line(.unknown, tr("接続: 不明（確認を中止したため）", "Connection: unknown (the check was cancelled)")))
        case let .handshakeFailed(others)?:
            out.append(Line(others ? .bad : .ok, others ? tr("接続: 接続できないアドレスがあります", "Connection: can’t connect to some addresses") : tr("接続: 接続できます", "Connection: OK")))
        case .notPaired?, .unsupportedVersion?, .paused?, .busy?, .other?:
            out.append(Line(.ok, tr("接続: 接続できます", "Connection: OK")))
        case nil:
            if target == nil {
                out.append(Line(.bad, tr("接続: 接続先がありません", "Connection: no target"), advice: tr("「接続先を追加」でペアリングしてください。", "Pair using Add Target.")))
            } else {
                out.append(Line(reached ? .ok : .unknown, reached ? tr("接続: 接続できます", "Connection: OK") : tr("接続: まだ確認していません", "Connection: not checked yet")))
            }
        }
        // 3. ペアリングが有効か（未確定を含む）
        if let t = target {
            if failure == .notPaired {
                out.append(Line(.bad, tr("ペアリング: 登録が解除されたか、一致しません", "Pairing: removed or doesn’t match"),
                                advice: tr("ペアリングし直してください（この接続先は自動では削除されません）。", "Pair again (this target isn’t deleted automatically).")))
            } else if case .handshakeFailed? = failure {
                out.append(Line(.bad, tr("ペアリング: 一致しないか、別の機器が応答しています", "Pairing: doesn’t match, or another device is answering"),
                                advice: tr("接続先の ShareScale Host のメニューにこの Mac があるか確認し、なければペアリングし直してください（この接続先は自動では削除されません）。", "Check the ShareScale Host menu on the Host. If this Mac isn’t there, pair again (this target isn’t deleted automatically).")))
            } else if !t.meta.confirmed {
                out.append(Line(.bad, tr("ペアリング: 確認待ちです", "Pairing: pending confirmation"),
                                advice: tr("接続先の ShareScale Host のメニューにこの Mac があるか確認し、なければペアリングし直してください。", "Check the ShareScale Host menu on the Host. If this Mac isn’t there, pair again.")))
            } else {
                // 記号と文を一致させる（届いていなければ ? で「確かめていません」）
                out.append(reached ? Line(.ok, tr("ペアリング: 有効です", "Pairing: valid"))
                                   : Line(.unknown, tr("ペアリング: 登録済み（接続先に接続できていないため、確認していません）", "Pairing: registered (not checked because it couldn’t connect to the Host)")))
            }
        } else {
            out.append(Line(.bad, tr("ペアリング: ありません", "Pairing: none"), advice: tr("「接続先を追加」でペアリングしてください。", "Pair using Add Target.")))
        }
        if readProblems > 0 {
            out.append(Line(.bad, tr("接続先のファイル: 読み込めないものが \(readProblems) 件あります", "Target files: \(readProblems) can’t be read"),
                            advice: tr("ペアリングし直すか、~/Library/Application Support/ShareScale/pairings/viewer/ のアクセス権を直してください（フォルダ 700・ファイル 600）。", "Pair again, or fix the permissions of ~/Library/Application Support/ShareScale/pairings/viewer/ (folder 700, files 600).")))
        }
        // 4. Host が動いているか
        if reached {
            out.append(Line(.ok, tr("接続先の ShareScale Host: 動作中", "ShareScale Host on the Host: running")))
        } else if failure == .unsupportedVersion {
            out.append(Line(.bad, tr("接続先の ShareScale Host: バージョンが違います", "ShareScale Host on the Host: different version"), advice: tr("両方の Mac で同じバージョンの ShareScale を使ってください。", "Use the same version of ShareScale on both Macs.")))
        } else {
            out.append(Line(.unknown, tr("接続先の ShareScale Host: 不明", "ShareScale Host on the Host: unknown"),
                            advice: tr("接続先の ShareScale Host のメニューにある「診断」を確認してください。", "Check Diagnostics in the ShareScale Host menu on the Host.")))
        }
        // 一時停止中（直前の状態、または切り替えを「一時停止中」で断られた）
        if failure == .paused || (lost == nil && state?.paused == true) {
            out.append(Line(.bad, tr("接続先の ShareScale Host: 一時停止中", "ShareScale Host on the Host: paused"), advice: tr("接続先の ShareScale Host のメニューで「再開」を選択してください。", "Choose Resume in the ShareScale Host menu on the Host.")))
        }
        // 5〜8 は状態が取れた時だけ判定する
        guard let s = state, lost == nil else {
            out.append(Line(.unknown, tr("画面共有: 不明", "Screen Sharing: unknown")))
            out.append(Line(.unknown, tr("仮想ディスプレイ: 不明", "Virtual display: unknown")))
            out.append(Line(.unknown, tr("表示倍率: 不明", "Display scale: unknown")))
            out.append(Line(.unknown, tr("直近のエラー: 不明", "Last error: unknown")))
            return out
        }
        out.append(s.sessionActive ? Line(.ok, tr("画面共有: 接続中", "Screen Sharing: connected"))
                   : Line(.bad, tr("画面共有: 未接続", "Screen Sharing: not connected"), advice: tr("高パフォーマンスの画面共有で接続してください（選んだ設定は次に接続した時に適用されます）。", "Connect using High Performance Screen Sharing (your choice applies the next time you connect).")))
        if s.virtualAmbiguous {
            out.append(Line(.bad, tr("仮想ディスプレイ: 特定できません", "Virtual display: can’t identify"),
                            advice: tr("画面共有の接続設定で「ディスプレイタイプ」を「1個の仮想ディスプレイ」にしてから、接続し直してください。", "In Screen Sharing’s connection settings, set Display Type to 1 virtual display, then reconnect.")))
        } else if let vd = s.virtualDisplay {
            out.append(Line(.ok, tr("仮想ディスプレイ: \(vd.logical)（\(vd.source == "signature" ? "識別情報" : "予備の方法")で特定）", "Virtual display: \(vd.logical) (identified by \(vd.source == "signature" ? "its signature" : "a fallback method"))")))
        } else if s.sessionActive {
            out.append(Line(.bad, tr("仮想ディスプレイ: 見つかりません", "Virtual display: not found"),
                            advice: tr("画面共有をいったん切断し、10 秒ほど待ってから接続し直してください。", "Disconnect Screen Sharing, wait about 10 seconds, then reconnect.")))
        } else {
            out.append(Line(.unknown, tr("仮想ディスプレイ: 不明（画面共有が接続されていないため）", "Virtual display: unknown (Screen Sharing isn’t connected)")))
        }
        if let c = chosen, let vd = s.virtualDisplay, !s.virtualAmbiguous {
            if vd.scaling == c {
                out.append(Line(.ok, tr("表示倍率: 設定どおり（\(c.rawValue)）", "Display scale: as chosen (\(c.rawValue))")))
            } else {
                out.append(Line(.bad, tr("表示倍率: 設定は \(c.rawValue)、実際は \(vd.scaling.rawValue)", "Display scale: chosen \(c.rawValue), actual \(vd.scaling.rawValue)"),
                                advice: s.setByOther == true ? tr("ほかの接続元の Mac が変更しました。カードをクリックすると戻せます。", "Another Mac changed it. Click a card to switch back.")
                                                             : tr("もう一度カードをクリックしてください。", "Click the card again.")))
            }
        } else {
            out.append(Line(.unknown, tr("表示倍率: 比べられません", "Display scale: can’t compare")))
        }
        if let e = s.lastError {
            let text = TextRules.clip(e)
            out.append(Line(.bad, tr("直近のエラー: \(text)", "Last error: \(text)")))
        } else {
            out.append(Line(.ok, tr("直近のエラー: なし", "Last error: none")))
        }
        return out
    }

    /// 「結果をコピー」の文字列。秘密・proof・コードは含めない（id は先頭 8 文字）
    public static func report(_ lines: [Line], target: TargetEntry?, version: String) -> String {
        var out = ["ShareScale \(version) " + tr("接続元の Mac の診断", "diagnostics for the Mac you connect from")]
        if let t = target {
            out.append(tr("接続先: \(t.displayName) (\(t.id.hex.prefix(8))) アドレス \(t.meta.addresses.joined(separator: ", ")) ポート \(t.meta.port)\(t.meta.manual ? " 手動" : "")",
                          "Target: \(t.displayName) (\(t.id.hex.prefix(8))) addresses \(t.meta.addresses.joined(separator: ", ")) port \(t.meta.port)\(t.meta.manual ? " manual" : "")"))
        } else {
            out.append(tr("接続先: なし", "Target: none"))
        }
        for l in lines {
            out.append("\(l.mark.rawValue) \(l.text)" + (l.advice.map { " — " + $0 } ?? ""))
        }
        return out.joined(separator: "\n")
    }
}
