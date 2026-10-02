import Foundation

/// 見る側の案内（仕様「見る側」の案内の区別）。優先度の高い順に 1 つだけ返す純粋な関数。
/// 1. 問い合わせの失敗: ローカルネットワークが許可されていない ＞ 未確定のペアリング（ほかの失敗の種類を問わず）＞ 届かない（別の VPN の疑いを添える）＞
///    TLS が成立しない（一致しないか別の機器。届かない候補が混ざればその旨。消さない）＞ ペアリングが解除された・一致しない（`not_paired`。消さない）＞
///    接続先の版が古い ＞ 一時停止中（`set` の拒否）＞ 処理中（`busy`）＞ 応答が無い ＞ 想定外。取り消しは案内しない（nil）
/// 2. 状態: 一時停止中 ＞ 2x を選べない ＞ 切り替えに応じない ＞ ほかの失敗（奪い合いを含む）＞
///    仮想ディスプレイが見つからない ＞ 特定できない（2 つある／見慣れない）＞ 画面共有が未接続 ＞ ほかの見る側（画面では「接続元の Mac」）が倍率を変えた。
///    画面共有が未接続の時は「画面共有を始めると、自動で <倍率> に切り替わります」と結果を書く（接続先が保っている倍率 `mode`。計画 2f-1 案 4）
/// 生のエラー文（`last_error`・想定外の中身）は本文に出さない（`ViewerModel.copyableDetail` でコピーできる）
public enum ViewerNotice: Sendable {
    public struct Text: Equatable, Sendable {
        public let title: String
        public let detail: String
        public init(_ title: String, _ detail: String) { self.title = title; self.detail = detail }
    }

    /// - `targetName`: 接続先の表示名（届かない時の本文に使う）
    /// - `unconfirmed`: 帳簿の `confirmed` が偽（名乗りの後の確定が済んでいない）
    /// - `vpnSuspected`: 届かない時に、別の VPN が既定の経路を握っていそうか
    /// - `chosen`: この Mac の各ディスプレイで選んでいる倍率（画面共有が未接続の時の文に使う）
    public static func make(state: RemoteState?, failure: ViewerFailure?, targetName: String, unconfirmed: Bool, vpnSuspected: Bool,
                            chosen: [DisplayMode] = []) -> Text? {
        if let f = failure { return forFailure(f, targetName: targetName, unconfirmed: unconfirmed, vpnSuspected: vpnSuspected) }
        guard let s = state else { return nil }
        return forState(s, chosen: chosen)
    }

    static func forFailure(_ f: ViewerFailure, targetName: String, unconfirmed: Bool, vpnSuspected: Bool) -> Text? {
        if f == .cancelled { return nil }
        if f == .localNetworkDenied {
            return Text(tr("ローカルネットワークへのアクセスが許可されていません", "Local network access isn’t allowed"),
                        tr("システム設定 › プライバシーとセキュリティ › ローカルネットワークで ShareScale をオンにしてください。",
                           "Turn on ShareScale in System Settings › Privacy & Security › Local Network."))
        }
        if unconfirmed {
            return Text(tr("ペアリングは確認待ちです", "Pairing is pending confirmation"),
                        tr("接続先の ShareScale Host のメニューにこの Mac が表示されているか確認し、表示されていなければペアリングし直してください。承認から 10 分以内に確認できなかったペアリングは、接続先で自動的に登録が解除されます。",
                           "Check that this Mac appears in the ShareScale Host menu on the Host. If it doesn’t, pair again. A pairing that isn’t confirmed within 10 minutes of approval is removed on the Host automatically."))
        }
        switch f {
        case .localNetworkDenied, .cancelled:
            return nil   // 上で扱った
        case .unreachable:
            // 見出し（「接続先に接続できません」）と同じ文で始めない。名前は確認することの中に入れる（仕上げ 2026-09-30）。
            // 確認することは 1 か所の定義（`unreachableChecks`。ファイアウォールの手がかりを含む。計画 2i）
            var detail = unreachableChecks(hostName: targetName)
            if vpnSuspected {
                detail += tr("ほかの VPN（Surfshark など）や exit node が通信経路を使っているようです。その VPN を切断するか、Tailscale の通信（100.64.0.0/10）を VPN の対象外にしてください。",
                             " Another VPN (such as Surfshark) or an exit node seems to be routing your traffic. Disconnect it, or exclude Tailscale traffic (100.64.0.0/10) from that VPN.")
            }
            return Text(unreachableTitle, detail)
        case let .handshakeFailed(others):
            var detail = tr("接続先で登録が解除されたか、同じアドレスで別の機器が応答している可能性があります。ペアリングし直してください（この接続先は自動では削除されません）。",
                            "The pairing may have been removed on the Host, or another device may be answering at that address. Pair again (this target isn’t deleted automatically).")
            if others { detail += tr(" 接続できないアドレスもありました。", " Couldn’t connect to some of the Host’s addresses.") }
            return Text(tr("ペアリングが一致しないか、別の機器が応答しています", "The pairing doesn’t match, or another device is answering"), detail)
        case .notPaired:
            return Text(tr("ペアリングの登録が解除されたか、一致しません", "The pairing was removed or doesn’t match"),
                        tr("ペアリングし直してください（接続先に確認のウインドウが表示されている場合は「追加しない」をクリックしてください）。この接続先は自動では削除されません。不要なら設定から削除できます。",
                           "Pair again (if a confirmation window is showing on the Host, click Don’t Add). This target isn’t deleted automatically; you can delete it in Settings if you no longer need it."))
        case .unsupportedVersion:
            return Text(tr("接続先の ShareScale のバージョンが合いません", "The Host’s ShareScale is a different version"),
                        tr("両方の Mac で同じバージョンの ShareScale を使ってください。", "Use the same version of ShareScale on both Macs."))
        case .paused:
            return pausedText
        case .busy:
            return Text(tr("接続先が前の変更を処理しています", "The Host is still applying the previous change"),
                        tr("少し待ってから、もう一度カードをクリックしてください。", "Wait a moment, then click the card again."))
        case .timedOut:
            return Text(tr("接続先から応答がありません", "No reply from the Host"),
                        tr("少し待ってから「更新」をクリックしてください。続く場合は、接続先の ShareScale Host のメニューにある「診断」を確認してください。",
                           "Wait a moment, then click Refresh. If this keeps happening, check Diagnostics in the ShareScale Host menu on the Host."))
        case .other:
            return Text(tr("接続先と通信できませんでした", "Couldn’t communicate with the Host"),
                        tr("少し待ってから「更新」をクリックしてください。続く場合は「詳細をコピー」で内容を控えてください。",
                           "Wait a moment, then click Refresh. If this keeps happening, use Copy Details to save the message."))
        }
    }

    /// 接続先が一時停止中の案内（切り替えを「一時停止中」で断られた時と、取り直した状態が一時停止中の時で、同じ見出し・同じ本文。点検 2i。
    /// 前は本文が 2 通りあり、「更新」を押すと本文だけが変わった）
    static var pausedText: Text {
        Text(tr("接続先が一時停止中です", "The Host is paused"),
             tr("表示倍率は変更されません。接続先の ShareScale Host のメニューで「再開」を選択してください。", "The display scale won’t change. Choose Resume in the ShareScale Host menu on the Host."))
    }

    // MARK: - 届かない時に確認すること（1 か所の定義。計画 2i）

    /// 届かない時の見出し（主の窓の案内と、「接続先を追加」の結果が同じ見出し）
    public static var unreachableTitle: String { tr("接続先に接続できません", "Can’t connect to the Host") }

    /// 接続先の Mac のファイアウォールの手がかり（1 文）。届かない原因を示す所（主の窓の案内・「接続先を追加」の結果・診断の「接続」の行）が、
    /// 文字どおり同じ文を出す。実機確認 B（2026-10-02）: 接続先で macOS のファイアウォールの確認（「"ShareScale Host" へのネットワーク受信接続を
    /// 許可しますか？」）が出ている間、接続元は「接続できません」で止まり、案内にファイアウォールの手がかりが無かった。
    /// ファイアウォールの今の状態（オフ・許可・ブロック・まだ一覧に無い）は、接続先の Host の診断が行で示すので、そこへ案内する。
    /// 「診断」の場所（どのメニューか）は言い切らない: 接続先で ShareScale を開いている間は、ShareScale Host のアイコンは出ず、
    /// ShareScale のメニューの「この Mac の接続先」に「診断…」がある。どちらでも当たるよう「ShareScale Host の「診断」」と書く（点検 2i）
    public static var firewallHint: String {
        tr("接続先の Mac のファイアウォールで、ShareScale Host への接続が許可されているかどうかも確認してください（接続先の Mac の ShareScale Host の「診断」で確認できます）。",
           "Also make sure the Host’s firewall allows incoming connections to ShareScale Host (see ShareScale Host’s Diagnostics on the Host).")
    }

    /// 届かない時に確認すること（2 文: ネットワークと Host が動いているか／ファイアウォール）。
    /// `hostName` は接続先の表示名（名前をまだ知らない「接続先を追加」では nil＝「接続先」と書く）
    public static func unreachableChecks(hostName: String?) -> String {
        let first = hostName.map {
            tr("2 台の Mac が同じネットワーク（または Tailscale）に接続されているか、「\($0)」で ShareScale Host が動作しているかを確認してください。",
               "Make sure both Macs are on the same network (or Tailscale) and that ShareScale Host is running on “\($0)”.")
        } ?? tr("2 台の Mac が同じネットワーク（または Tailscale）に接続されているか、接続先で ShareScale Host が動作しているかを確認してください。",
                "Make sure both Macs are on the same network (or Tailscale) and that ShareScale Host is running on the Host.")
        return first + tr("", " ") + firewallHint
    }

    static func forState(_ s: RemoteState, chosen: [DisplayMode] = []) -> Text? {
        if s.paused { return pausedText }
        if let err = s.lastError, err.hasPrefix("no 2x mode") {
            // ダイナミック解像度で、見る側の画面共有アプリが 2x の設定を用意していない（窓を画面いっぱいに広げた後など）
            return Text(tr("今のウインドウの大きさでは 2x Retina を選べません", "2x Retina isn’t available at this window size"),
                        tr("画面共有のウインドウの大きさを少し変えてください。選べるようになると、自動で 2x に切り替わります。",
                           "Resize the Screen Sharing window slightly. ShareScale switches to 2x automatically once it’s available."))
        }
        if let err = s.lastError, err.contains("timed out") {
            return Text(tr("macOS が表示倍率の切り替えを完了しませんでした", "macOS didn’t finish switching the display scale"),
                        tr("少し待つと、自動でもう一度試します。すぐに試すには、もう一度カードをクリックしてください。",
                           "ShareScale will try again shortly. To try now, click the card again."))
        }
        if s.lastError != nil {
            return Text(tr("接続先で表示倍率を切り替えられませんでした", "Couldn’t switch the display scale on the Host"),
                        tr("もう一度カードをクリックしてください。続く場合は「詳細をコピー」で内容を控えてください。",
                           "Click the card again. If this keeps happening, use Copy Details to save the message."))
        }
        // 識別情報でも予備の方法でも見つからない時は、つなぎ直しを案内する
        if s.sessionActive, s.virtualDisplay == nil, !s.virtualAmbiguous {
            return Text(tr("仮想ディスプレイが見つかりません", "The virtual display wasn’t found"),
                        tr("画面共有をいったん切断し、10 秒ほど待ってから接続し直してください。", "Disconnect Screen Sharing, wait about 10 seconds, then reconnect."))
        }
        if s.virtualAmbiguous {
            if s.virtualDisplay?.source == "signature" {
                return Text(tr("仮想ディスプレイが 2 つあります", "There are two virtual displays"),
                            tr("どちらを変更すればよいか判断できないため、自動調整を止めています。画面共有の接続設定で「ディスプレイタイプ」を「1個の仮想ディスプレイ」にしてください。",
                               "Auto-adjust is paused because it can’t tell which one to change. In Screen Sharing’s connection settings, set Display Type to 1 virtual display."))
            }
            return Text(tr("仮想ディスプレイを特定できません", "Can’t identify the virtual display"),
                        tr("接続先の Mac に見慣れないディスプレイが複数あるため、別のディスプレイを変更しないよう自動調整を止めています。画面共有をいったん切断し、10 秒ほど待ってから接続し直してください。",
                           "The Host has more than one unfamiliar display, so auto-adjust is paused to avoid changing the wrong one. Disconnect Screen Sharing, wait about 10 seconds, then reconnect."))
        }
        if !s.sessionActive { return notConnected(s, chosen: chosen) }
        if s.setByOther == true {
            return Text(tr("ほかの接続元の Mac が表示倍率を変更しました", "Another Mac changed the display scale"),
                        tr("最後に変更した設定が有効です。カードをクリックすると、この Mac の設定に戻せます。", "The most recent change is in effect. Click a card to switch back to this Mac’s setting."))
        }
        return nil
    }

    /// 画面共有が未接続の時: 次に画面共有を始めた時に何が起きるかを書く（「一度選べば自動」を伝える。計画 2f-1 案 4）。
    /// 倍率は接続先が保っているもの（最後に選ばれたもの。`set_by` がほかの Mac ならその旨）。
    /// この Mac のディスプレイの選択が違えば、カードをクリックすると切り替わることを添える（複数のディスプレイで違う倍率を選んでいれば、使う方のカード）
    static func notConnected(_ s: RemoteState, chosen: [DisplayMode]) -> Text {
        guard let m = s.mode, m != .off else {
            return Text(tr("画面共有を始めても、表示倍率は自動では変わりません", "The display scale won’t change automatically when Screen Sharing starts"),
                        tr("カードをクリックすると、次に画面共有を始めた時から自動で切り替わるようになります。",
                           "Click a card to switch automatically from the next time Screen Sharing starts."))
        }
        let name = DataSaving.optionLabel(m)
        var detail = s.setByOther == true
            ? tr("ほかの接続元の Mac が最後に選んだ表示倍率です。", "Another Mac chose this display scale most recently.")
            : tr("表示倍率は保存されているため、接続のたびに選び直す必要はありません。", "The display scale is saved, so you don’t need to choose it again each time you connect.")
        let modes = Set(chosen)
        if modes.count > 1 {
            detail += tr("別のディスプレイで画面共有を使う時は、そのディスプレイのカードをクリックしてください。",
                         " When you use Screen Sharing on another display, click that display’s card.")
        } else if let c = modes.first, c != m {
            detail += tr("この Mac の設定（\(DataSaving.optionLabel(c))）にするには、カードをクリックしてください。",
                         " To use this Mac’s setting (\(DataSaving.optionLabel(c))), click the card.")
        }
        return Text(tr("画面共有を始めると、自動で \(jaName(name, "に"))切り替わります", "\(name) is used when Screen Sharing starts"), detail)
    }
}
