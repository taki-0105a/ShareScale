import Foundation
import ShareScaleNet
import ShareScaleProtocol

/// メニューバーの項目（純粋な値。AppKit の `NSMenu` はこれを並べるだけ）
public enum MenuEntry: Equatable, Sendable {
    case status(String)                                  // 押せない 1 行（状態）
    case notice(String)                                  // 押せない案内（更新の途中・奪い合い・読めないファイル など）
    case addViewer(title: String, enabled: Bool)         // 「接続元の Mac を追加…」（上限・受け付けていない時は押せず、題名に理由）
    case showCode(title: String)                         // 「接続コードを表示」（発行中だけ）
    case viewer(id: PairingID, title: String, detail: String, stale: Bool, unpair: String, later: String?)
    case pause(title: String, resume: Bool)              // 「一時停止」／「再開」（`resume` が真なら押すと再開。判断はここ 1 か所。点検 2f-2）
    /// ShareScale のメニューの「この Mac の接続先」だけ: 80 日の知らせのまとめ（押すと 設定 › この Mac の接続先 を開く。点検 2f-2）
    case reviewViewers(String)
    case diagnostics(String)
    case openLog(String)
    case quit(String)
    case separator
}

/// メニューの項目の元になる値（計画 2f-2 案 2）。Host 自身は `HostRuntime` の様子から（`init(diagnostics:pairings:code:)`）、
/// ShareScale.app は `state.json` の `Summary` から（`init(summary:)`）作り、どちらも同じ `MenuModel.build` に渡す（両方の入口が同じ項目を返す）。
/// Host の様子から作る時も、文字は `state.json` に書く時と同じ形（名前は `NameRules.maxBytes`、直近のエラーなどは `TextRules.clip`）に揃え、
/// コードの期限は UNIX 秒に切り捨てる（`state.json` の `code.expires` と同じ）
public struct HostMenuFacts: Equatable, Sendable {
    public struct Viewer: Equatable, Sendable {
        public var id: PairingID, name: String, lastSeen: Int64?, confirmed: Bool, stale: Bool
        public init(id: PairingID, name: String, lastSeen: Int64?, confirmed: Bool, stale: Bool) {
            self.id = id; self.name = name; self.lastSeen = lastSeen; self.confirmed = confirmed; self.stale = stale
        }
    }
    /// 受け付けの状態（`ListenerStatus` の写し。`state.json` の `listener` と同じ粒度）
    public enum Listener: Equatable, Sendable {
        case stopped, starting, waitingForNetwork
        case listening(port: Int64)
        case portInUse(port: Int64, retryIn: Int64)
        case failed(detail: String, retryIn: Int64)
    }
    public var paused = false
    public var listener: Listener = .stopped
    public var tailscaleOnly = false
    /// 「インターネットからの接続も受け付ける」（受け付けの行の出し分けに使う。`state.json` の `allow_global`。計画 2h）
    public var allowGlobal = false
    /// Tailscale の IPv4（IPv4 と IPv6 の両方がある時だけ。受け付けの行に出す）
    public var tailscaleIPv4: String?
    /// Tailscale の IPv6 が無い（tailnet で IPv6 がオフ）
    public var tailscaleIPv4Only = false
    public var updating = false
    public var contention = false
    public var lastError: String?
    public var storeProblems = 0
    public var engineProblem: String?
    public var logProblem: String?
    public var rejectedGlobalLast24h = 0
    public var pairingCount = 0
    /// 接続元の Mac（id の順。並べ替えは `MenuModel.build` が名前の順に行う）
    public var viewers: [Viewer] = []
    /// 発行中のコードの期限（UNIX 秒）
    public var codeExpires: Int64?
    public init() {}

    /// Host 自身の様子から
    public init(diagnostics d: HostDiagnostics, pairings: [PairingID: HostMeta], code: (text: String, expires: Date)?) {
        paused = d.paused
        switch d.listener {
        case .stopped: listener = .stopped
        case .starting: listener = .starting
        case .waitingForNetwork: listener = .waitingForNetwork
        case let .listening(p): listener = .listening(port: Int64(p))
        case let .portInUse(p, r): listener = .portInUse(port: Int64(p), retryIn: Int64(r))
        case let .failed(e, r): listener = .failed(detail: TextRules.clip(e), retryIn: Int64(r))
        }
        tailscaleOnly = d.tailscaleOnly; allowGlobal = d.allowGlobal
        switch d.tailscale {
        case let .found(_, v4, _): tailscaleIPv4 = v4.text
        case .ipv4Only: tailscaleIPv4Only = true
        case .none: break
        }
        updating = d.updating; contention = d.contention
        lastError = d.lastError.map { TextRules.clip($0) }
        storeProblems = d.storeProblems.count
        engineProblem = d.engineProblem.map { TextRules.clip($0) }
        logProblem = d.logProblem.map { TextRules.clip($0) }
        rejectedGlobalLast24h = d.rejectedGlobalLast24h
        pairingCount = d.pairingCount
        viewers = HostControlState.pairings(pairings, stale: Set(d.staleNotices)).map {
            Viewer(id: $0.id, name: $0.name, lastSeen: $0.lastSeen, confirmed: $0.confirmed, stale: $0.stale)
        }
        codeExpires = code.map { Int64($0.expires.timeIntervalSince1970) }
    }

    /// ShareScale.app が読んだ `state.json` から（知らない受け付けの状態は「受け付けていません」）
    public init(summary s: HostControlState.Summary) {
        paused = s.paused
        switch s.listenerStatus {
        case "listening": listener = .listening(port: s.port ?? 0)
        case "starting": listener = .starting
        case "waiting_for_network": listener = .waitingForNetwork
        case "port_in_use": listener = .portInUse(port: s.port ?? 0, retryIn: s.retryIn ?? 0)
        case "failed": listener = .failed(detail: s.listenerDetail ?? "", retryIn: s.retryIn ?? 0)
        default: listener = .stopped
        }
        tailscaleOnly = s.tailscaleOnly; allowGlobal = s.allowGlobal
        tailscaleIPv4 = s.tailscale == "found" ? s.tailscaleIPv4 : nil
        tailscaleIPv4Only = s.tailscale == "ipv4_only"
        updating = s.updating; contention = s.contention
        lastError = s.lastError
        storeProblems = Int(clamping: s.storeProblems)
        engineProblem = s.engineProblem; logProblem = s.logProblem
        rejectedGlobalLast24h = Int(clamping: s.rejectedGlobal24h)
        pairingCount = Int(clamping: s.pairingCount)
        viewers = s.pairings.map { Viewer(id: $0.id, name: $0.name, lastSeen: $0.lastSeen, confirmed: $0.confirmed, stale: $0.stale) }
        codeExpires = s.codeExpires
    }
}

/// メニューの項目の組み立て（`HostMenuFacts` から。Host 自身は `HostRuntime.diagnostics`・`pairings`・`currentCode` から作る）。
/// `now` は壁時計（コードの残り時間と最終接続の表示にだけ使う）
public enum MenuModel {
    public static func build(diagnostics d: HostDiagnostics, pairings: [PairingID: HostMeta], code: (text: String, expires: Date)?,
                             now: Date, language L: HostLanguage) -> [MenuEntry] {
        build(HostMenuFacts(diagnostics: d, pairings: pairings, code: code), now: now, language: L)
    }

    public static func build(_ f: HostMenuFacts, now: Date, language L: HostLanguage) -> [MenuEntry] {
        var out: [MenuEntry] = []
        out.append(.status(f.paused ? L.t("ShareScale Host は一時停止中です", "ShareScale Host is paused") : L.t("ShareScale Host は動作中です", "ShareScale Host is running")))
        out.append(.status(listenerLine(f, L)))
        for n in notices(f, L) { out.append(.notice(n)) }
        out.append(.separator)
        let (canAdd, why) = addViewerState(f, L)
        out.append(.addViewer(title: why.map { L.t("接続元の Mac を追加（\($0)）", "Add a Mac to Connect From (\($0))") } ?? L.t("接続元の Mac を追加…", "Add a Mac to Connect From…"),
                              enabled: canAdd))
        let nowSeconds = Int64(now.timeIntervalSince1970)
        if let x = f.codeExpires {
            let left = HostLanguage.clock(Int(clamping: x - nowSeconds))
            out.append(.showCode(title: L.t("接続コードを表示…（残り \(left)）", "Show Pairing Code… (\(left) left)")))   // ウインドウが開くので「…」
        }
        out.append(.separator)
        let viewers = f.viewers.sorted { a, b in
            let (x, y) = (L.displayName(a.name), L.displayName(b.name))
            return x == y ? a.id.hex < b.id.hex : x < y
        }
        if viewers.isEmpty {
            out.append(.status(L.t("接続元の Mac はまだありません", "No Macs added yet")))
        }
        for v in viewers {
            let name = L.displayName(v.name)
            let title = v.stale ? L.t("「\(name)」は 80 日間使われていません。登録を解除しますか？", "“\(name)” hasn’t been used in 80 days. Remove it?") : name
            out.append(.viewer(id: v.id, title: title, detail: detail(confirmed: v.confirmed, lastSeen: v.lastSeen, now: nowSeconds, L), stale: v.stale,
                               unpair: L.t("登録を解除…", "Remove…"), later: v.stale ? L.t("あとで", "Later") : nil))
        }
        out.append(.separator)
        out.append(.pause(title: f.paused ? L.t("再開", "Resume") : L.t("一時停止", "Pause"), resume: f.paused))
        out.append(.diagnostics(L.t("診断…", "Diagnostics…")))
        out.append(.openLog(L.t("ログを開く", "Open Logs")))
        out.append(.separator)
        out.append(.quit(L.t("ShareScale Host を終了", "Quit ShareScale Host")))
        return out
    }

    /// ShareScale.app のメニューの「この Mac の接続先」の節に出す項目（計画 2f-2 案 2）。Host のメニューと同じ項目・同じ文言から、
    /// 状態の 1 行（動作中／一時停止中）・受け付けの行（いつも。Tailscale だけの時は Tailscale の IPv4 も）・案内・
    /// 80 日の知らせのまとめ（1 件でもあれば「80 日間使われていない接続元の Mac があります…」。押すと設定へ。点検 2f-2）・
    /// 「接続元の Mac を追加…」・「接続コードを表示…」・「一時停止／再開」・「診断…」を選ぶ。
    /// 接続元の Mac の一覧・ログ・終了は出さない（一覧・登録の解除・「あとで」・終了は 設定 › この Mac の接続先 にある）
    public static func companion(_ f: HostMenuFacts, now: Date, language L: HostLanguage) -> [MenuEntry] {
        let all = build(f, now: now, language: L)
        var out: [MenuEntry] = []
        var statusLines = 0
        var reviewed = false
        for e in all {
            switch e {
            case .status:
                // 最初の 2 行（動作中／一時停止中・受け付け）だけ。「接続元の Mac はまだありません」は出さない
                if statusLines < 2 { out.append(e) }
                statusLines += 1
            case .notice, .addViewer, .showCode, .pause, .diagnostics: out.append(e)
            case let .viewer(_, _, _, stale, _, _):
                if stale, !reviewed {
                    reviewed = true
                    // 案内の後・操作の前に置く（押すと設定のタブ。一覧はそこにある）
                    let at = out.lastIndex { if case .notice = $0 { return true }; if case .status = $0 { return true }; return false }.map { $0 + 1 } ?? out.count
                    out.insert(.reviewViewers(L.t("80 日間使われていない接続元の Mac があります…", "Some Macs haven’t connected in 80 days…")), at: at)
                }
            case .reviewViewers, .openLog, .quit, .separator: break
            }
        }
        return out
    }

    /// 受け付けの状態の 1 行（受け付けている時は `acceptingLine` の 3 つの状態・Tailscale が見つからない・開けない＋理由）。Host の診断の一覧も使う
    static func listenerLine(_ d: HostDiagnostics, _ L: HostLanguage) -> String {
        listenerLine(HostMenuFacts(diagnostics: d, pairings: [:], code: nil), L)
    }

    static func listenerLine(_ f: HostMenuFacts, _ L: HostLanguage) -> String {
        switch f.listener {
        case let .listening(p):
            return acceptingLine(tailscaleOnly: f.tailscaleOnly, allowGlobal: f.allowGlobal, tailscaleIPv4: f.tailscaleIPv4, port: String(p), L)
        case .waitingForNetwork:
            return L.t("Tailscale が見つからないため、接続を受け付けていません", "Not accepting connections because Tailscale wasn’t found")
        case let .portInUse(p, r):
            return L.t("ポート \(p) がほかのアプリ（別のユーザの ShareScale など）で使われているため、接続を受け付けられません。\(r) 秒後にもう一度試します",
                       "Can’t accept connections because port \(p) is in use by another app (such as another user’s ShareScale). Trying again in \(HostLanguage.count(Int(clamping: r), "second", "seconds"))")
        case let .failed(e, r):
            return L.t("接続を受け付けられません（\(e)）。\(r) 秒後にもう一度試します", "Can’t accept connections (\(e)). Trying again in \(HostLanguage.count(Int(clamping: r), "second", "seconds"))")
        case .starting:
            return L.t("接続の受け付けを準備しています…", "Getting ready to accept connections…")
        case .stopped:
            return L.t("接続を受け付けていません", "Not accepting connections")
        }
    }

    /// 受け付けている時の 1 行（計画 2h。実機確認 A: 既定でも「すべてのネットワークから」と出て、実際より広く読めた）。
    /// 受け付ける送り元（`SourceClassifier`・`AdmissionPolicy`）に合わせて、設定の 3 つの状態で出し分ける:
    /// - 「Tailscale からの接続だけ」がオン（「インターネットからも」がオンでも、Tailscale 以外は TLS の前に断る）: Tailscale だけ
    /// - 「インターネットからの接続も受け付ける」がオン: インターネットを含むすべてのネットワーク
    /// - 既定: ローカルネットワーク（この Mac・プライベートとリンクローカルのアドレス・同じサブネット。プライベートアドレスは、同じサブネットでなくても
    ///   （ルータ越し・VPN）受け付けるので「同じネットワーク」とは書かない。点検 2h）と Tailscale の範囲だけ（そのほかのグローバルなアドレスは TLS の前に断る）
    /// ShareScale.app の「この Mac の接続先」（`HostPanelModel.listenerText`）も同じ関数を使う（`port` は読めなければ「?」）
    public static func acceptingLine(tailscaleOnly: Bool, allowGlobal: Bool, tailscaleIPv4: String?, port: String, _ L: HostLanguage) -> String {
        if tailscaleOnly {
            if let v4 = tailscaleIPv4 { return L.t("Tailscale からの接続だけを受け付けています（\(v4)、ポート \(port)）", "Accepting connections from Tailscale only (\(v4), port \(port))") }
            return L.t("Tailscale からの接続だけを受け付けています（ポート \(port)）", "Accepting connections from Tailscale only (port \(port))")
        }
        if allowGlobal {
            return L.t("インターネットを含むすべてのネットワークからの接続を受け付けています（ポート \(port)）",
                       "Accepting connections from all networks, including the internet (port \(port))")
        }
        return L.t("ローカルネットワークと Tailscale からの接続を受け付けています（ポート \(port)）", "Accepting connections from local networks and Tailscale (port \(port))")
    }

    /// 押せない案内（順番も決める）
    static func notices(_ f: HostMenuFacts, _ L: HostLanguage) -> [String] {
        var out: [String] = []
        if f.updating { out.append(L.t("アップデートの途中です。ShareScale を開くと完了します", "An update is in progress. Open ShareScale to finish it")) }
        if f.contention { out.append(L.t("表示倍率が何度も元に戻されています（ほかのアプリが変更している可能性があります）", "The display scale keeps being changed back (another app may be changing it)")) }
        // 奪い合い・更新の途中の時は、直近の失敗が同じ内容なので重ねて出さない
        if !f.contention, !f.updating, let e = f.lastError { out.append(L.t("直近のエラー: ", "Last error: ") + TextRules.stripControls(e)) }
        if f.tailscaleOnly, f.tailscaleIPv4Only {
            out.append(L.t("Tailscale の IPv6 がオフのため、Tailscale を見つけられません。Tailscale の管理画面で IPv6 をオンにしてください",
                           "Tailscale can’t be found because IPv6 is off in your tailnet. Turn on IPv6 in the Tailscale admin console"))
        }
        if f.storeProblems > 0 {
            out.append(L.t("読み込めないペアリングのファイルが \(f.storeProblems) 件あります（詳しくは診断で確認できます）",
                           "\(HostLanguage.count(f.storeProblems, "pairing file", "pairing files")) can’t be read (see Diagnostics for details)"))
        }
        if let e = f.engineProblem { out.append(L.t("設定を保存できません: ", "Can’t save settings: ") + e) }
        if let e = f.logProblem { out.append(L.t("ログを書き込めません: ", "Can’t write the log: ") + e) }
        if f.rejectedGlobalLast24h > 0 {
            out.append(L.t("直近 24 時間に、インターネットからの接続を \(f.rejectedGlobalLast24h) 件拒否しました",
                           "Refused \(HostLanguage.count(f.rejectedGlobalLast24h, "connection", "connections")) from the internet in the last 24 hours"))
        }
        return out
    }

    /// 「接続元の Mac を追加」を押せるか（押せない時はその理由）
    static func addViewerState(_ f: HostMenuFacts, _ L: HostLanguage) -> (Bool, String?) {
        if f.pairingCount >= Limits.maxPairings { return (false, L.t("上限の \(Limits.maxPairings) 台に達しています", "limit of \(Limits.maxPairings) reached")) }
        if case .listening = f.listener { return (true, nil) }
        return (false, L.t("接続を受け付けていません", "not accepting connections"))
    }

    /// 接続元の Mac の 2 行目（Host の診断の一覧も使う）
    static func detail(_ m: HostMeta, now: Date, _ L: HostLanguage) -> String {
        detail(confirmed: m.confirmed, lastSeen: m.lastSeen, now: Int64(now.timeIntervalSince1970), L)
    }

    /// 接続元の Mac の 2 行目（確認待ち・まだ接続していない・最後の接続 N 日前）
    static func detail(confirmed: Bool, lastSeen: Int64?, now: Int64, _ L: HostLanguage) -> String {
        guard confirmed else { return L.t("確認待ち（その Mac で登録が完了していません）", "Pending confirmation (not yet finished on that Mac)") }
        guard let last = lastSeen else { return L.t("まだ接続していません", "Not connected yet") }
        let age = now - last
        if age < 0 { return L.t("最後の接続: 不明（時計が合っていません）", "Last connected: unknown (clock mismatch)") }
        let days = Int(age / 86_400)
        if days == 0 { return L.t("最後の接続: 今日", "Last connected: today") }
        return L.t("最後の接続: \(days) 日前", "Last connected: \(HostLanguage.count(days, "day", "days")) ago")
    }
}
