import Foundation
import ServiceManagement
import ShareScaleEngine
import ShareScaleNet
import ShareScaleProtocol

/// アプリケーションファイアウォールの状態（`socketfilterfw` を sudo なしで読む。仕様「アプリケーションファイアウォール」）
public enum FirewallStatus: Equatable, Sendable {
    /// Host の実行体（またはバンドル）の規則
    public enum AppRule: Equatable, Sendable {
        case allowed        // 「外部からの接続を許可」
        case blocked        // 「外部からの接続をブロック」
        case notInRules     // 規則に無い（初回の待ち受けで確認の画面が出る）
        case unknown        // 規則の一覧を読めない
    }
    case off
    case on(AppRule)
    case blockAll                // 「すべての受信をブロック」
    case unknown(String)         // 読めなかった理由
}

/// `socketfilterfw` の出力の解析（純粋な関数。実物は `SystemChecks.firewall` が呼ぶ）。
/// 文言は実測（2026-09-26・Darwin 27・sudo なし・確認の画面なし）:
/// - `--getglobalstate` → `Firewall is enabled. (State = 1)`（0 オフ・2 すべての受信をブロック）
/// - `--getblockall` → `Firewall has block all state set to disabled.`
/// - `--listapps` → `Total number of apps = N`、`N : <path> `（コロンの前後に空白 1 つ・パスの末尾に空白 1 つ）、次の行に 13 個の空白と
///   `(Allow incoming connections)`／`(Block incoming connections)`（括弧の中に空白なし。空白の数と括弧の中の空白は読み方に影響しない）
/// - `--getappblocked <path>` → 規則に無い簡易署名の実行体でも `Incoming connection to <path> is permitted.`（終了 0）、
///   `/bin/ls` は使い方を出して終了 255。**規則に無いものも permitted と出るので、許可の判定には使わず、`blocked` の検出にだけ使う**
/// - `fdesetup status` → `FileVault is On.`
public enum FirewallOutput {
    public static let tool = URL(fileURLWithPath: "/usr/libexec/ApplicationFirewall/socketfilterfw")

    /// `--getglobalstate`: 「Firewall is enabled. (State = 1)」／「Firewall is disabled. (State = 0)」／State = 2 はすべての受信をブロック
    public static func globalState(_ out: String) -> Int? {
        guard let r = out.range(of: "State = ") else { return nil }
        let digits = out[r.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }
    /// `--getblockall`: 「Firewall has block all state set to disabled.」（オフ）／「… set to enabled.」「block all non-essential」（オン）
    public static func blockAll(_ out: String) -> Bool? {
        let s = out.lowercased()
        if s.contains("disabled") { return false }
        if s.contains("block all non-essential") || s.contains("enabled") { return true }
        return nil
    }
    /// `--getappblocked <実行体>`: 「… is blocked …」なら true。「permitted」は規則に無いものにも出るので false（許可）とは読まない（nil）
    public static func appBlocked(_ out: String) -> Bool? {
        out.lowercased().contains("blocked") ? true : nil
    }
    /// `--listapps`: 規則の一覧（パスと、許可か）。「N : <path> 」の次の空でない行に「Allow」か「Block」（前後の空白は除く）
    public static func listApps(_ out: String) -> [(path: String, allowed: Bool)] {
        var result: [(String, Bool)] = []
        var pending: String?
        for raw in out.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let colon = line.firstIndex(of: ":"), line[..<colon].trimmingCharacters(in: .whitespaces).allSatisfy(\.isNumber),
               !line[..<colon].trimmingCharacters(in: .whitespaces).isEmpty {
                pending = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                continue
            }
            if let path = pending {
                let l = line.lowercased()
                if l.contains("allow") { result.append((path, true)); pending = nil }
                else if l.contains("block") { result.append((path, false)); pending = nil }
            }
        }
        return result
    }
    /// Host の規則: 実行体のパスか、バンドルのパス（またはその中）が一覧にあればその状態。無ければ「規則なし」
    public static func appRule(list: [(path: String, allowed: Bool)], executable: String, bundle: String?) -> FirewallStatus.AppRule {
        for (path, allowed) in list {
            let hit = path == executable || (bundle.map { path == $0 || path.hasPrefix($0 + "/") } ?? false)
            if hit { return allowed ? .allowed : .blocked }
        }
        return .notInRules
    }
    /// 4 つの出力（終了コードと標準出力）からまとめる。`--getglobalstate` が読めなければ `unknown`。
    /// 規則は `--listapps` から読み、読めなければ `--getappblocked` の `blocked` だけを見る
    public static func status(global: (status: Int32?, output: String), blockAll: (status: Int32?, output: String),
                              list: (status: Int32?, output: String), app: (status: Int32?, output: String),
                              executable: String, bundle: String?) -> FirewallStatus {
        guard global.status == 0, let state = globalState(global.output) else {
            return .unknown("socketfilterfw --getglobalstate: exit \(global.status.map(String.init) ?? "none")")
        }
        if state == 0 { return .off }
        if state == 2 || (blockAll.status == 0 && Self.blockAll(blockAll.output) == true) { return .blockAll }
        if list.status == 0 { return .on(appRule(list: listApps(list.output), executable: executable, bundle: bundle)) }
        if app.status == 0, appBlocked(app.output) == true { return .on(.blocked) }
        return .on(.unknown)
    }
}

/// `fdesetup status` の出力（「FileVault is On.」／「FileVault is Off.」）。読めなければ nil
public enum FileVaultOutput {
    public static let tool = URL(fileURLWithPath: "/usr/bin/fdesetup")
    public static func isOn(status: Int32?, output: String) -> Bool? {
        guard status == 0 else { return nil }
        let s = output.lowercased()
        if s.contains("filevault is on") { return true }
        if s.contains("filevault is off") { return false }
        return nil
    }
}

/// ログイン項目の状態（`SMAppService.loginItem(identifier:).status` の写し。AppKit も ServiceManagement も要らない形で持つ）
public enum LoginItemStatus: Equatable, Sendable {
    case enabled, requiresApproval, notRegistered, notFound, unknown
    public init(_ s: SMAppService.Status) {
        switch s {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notRegistered: self = .notRegistered
        case .notFound: self = .notFound
        @unknown default: self = .unknown
        }
    }
}

/// OS から読む診断（ファイアウォール・FileVault・ログイン項目）。実物を呼ぶのは実行体だけで、試験は解析だけを確かめる
public struct SystemDiagnostics: Equatable, Sendable {
    public var firewall: FirewallStatus = .unknown("not checked")
    public var fileVault: Bool?
    public var loginItem: LoginItemStatus = .unknown
    public init() {}
}

public enum SystemChecks {
    public static let hostLoginItemIdentifier = BundleIdentifiers.host
    public typealias Runner = @Sendable (URL, [String], TimeInterval) -> (status: Int32?, output: String)
    public static let childRunner: Runner = { url, args, timeout in
        let r = ChildProcess.run(url, args, timeout: timeout)
        return (r.status, r.output)
    }

    /// 4 つの `socketfilterfw` を順に呼ぶ（各 5 秒。sudo なし。実測で確認の画面は出なかった。R10 で再確認）
    public static func firewall(executable: String, bundle: String?, run: Runner = childRunner) -> FirewallStatus {
        FirewallOutput.status(global: run(FirewallOutput.tool, ["--getglobalstate"], 5),
                              blockAll: run(FirewallOutput.tool, ["--getblockall"], 5),
                              list: run(FirewallOutput.tool, ["--listapps"], 5),
                              app: run(FirewallOutput.tool, ["--getappblocked", executable], 5),
                              executable: executable, bundle: bundle)
    }
    public static func fileVault(run: Runner = childRunner) -> Bool? {
        let r = run(FileVaultOutput.tool, ["status"], 5)
        return FileVaultOutput.isOn(status: r.status, output: r.output)
    }
    /// ログイン項目の状態（登録は 2e の ShareScale.app が行う。ここは読むだけ）。
    /// Host 自身から `SMAppService.loginItem(identifier:)` を呼ぶと、親アプリの `LoginItems/` にある自分を見つけられず `.notFound` になる恐れがある
    /// （実機 R6 で確かめる。ならなければ ShareScale.app 側で読んで表示し、Host の診断から外す）
    public static func loginItem() -> LoginItemStatus {
        LoginItemStatus(SMAppService.loginItem(identifier: hostLoginItemIdentifier).status)
    }
    /// 登録・解除（ShareScale.app の複製だけが呼ぶ。計画 2e-1 の `ShareScaleCore.SystemLoginItemService`）
    public static func registerLoginItem() throws { try SMAppService.loginItem(identifier: hostLoginItemIdentifier).register() }
    public static func unregisterLoginItem() throws { try SMAppService.loginItem(identifier: hostLoginItemIdentifier).unregister() }
    /// システム設定 › 一般 › ログイン項目 を開く（`requiresApproval` の案内のボタン）
    public static func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
    /// 「ログイン時に ShareScale を開く」（ShareScale.app 自身。`SMAppService.mainApp`。複製だけが登録する。計画 2f-2 案 1）
    public static func appLoginItem() -> LoginItemStatus { LoginItemStatus(SMAppService.mainApp.status) }
    public static func registerAppLoginItem() throws { try SMAppService.mainApp.register() }
    public static func unregisterAppLoginItem() throws { try SMAppService.mainApp.unregister() }
    /// 読むのに時間のかかるものをまとめて（裏のキューから呼ぶ）
    public static func read(executable: String, bundle: String?, run: Runner = childRunner) -> SystemDiagnostics {
        var s = SystemDiagnostics()
        s.firewall = firewall(executable: executable, bundle: bundle, run: run)
        s.fileVault = fileVault(run: run)
        s.loginItem = loginItem()
        return s
    }
}

/// 診断の窓の行（「結果をコピー」もこの行）。秘密・proof は含まない。見る側（画面では「接続元の Mac」）の名前は含めてよい
public enum DiagnosticsReport {
    /// 1 行。`mark` が nil の行（版・接続元の Mac の一覧）は記号を付けない。`mark` が `.unknown` の行は「?」（読み取れない・不明）。
    /// `action` は ✗ と ? の行の右に出す「〜の設定を開く…」（計画 2f-1 案 5）。`section` は窓のどこに出すか（並びに依らずに分ける。点検 2f-1）
    public struct Item: Equatable, Sendable {
        public enum Mark: String, Equatable, Sendable { case ok = "✓", bad = "✗", unknown = "?" }
        /// 版（窓の上）・確認の行（カード）・接続元の Mac の一覧（見出しと各行）
        public enum Section: Equatable, Sendable { case header, check, viewers }
        public let mark: Mark?
        public let text: String
        public let action: DiagnosticAction?
        public let section: Section
        public init(_ mark: Mark?, _ text: String, action: DiagnosticAction? = nil, section: Section = .check) {
            self.mark = mark; self.text = text; self.action = action; self.section = section
        }
        /// 「結果をコピー」の 1 行（記号と文。今までの `lines` と同じ形）
        public var line: String { mark.map { $0.rawValue + " " + text } ?? text }
    }

    /// 「結果をコピー」の行（`items` の `line`）
    public static func lines(host d: HostDiagnostics, system s: SystemDiagnostics, pairings: [PairingID: HostMeta],
                             version: String, now: Date, language L: HostLanguage) -> [String] {
        items(host: d, system: s, pairings: pairings, version: version, now: now, language: L).map(\.line)
    }

    public static func items(host d: HostDiagnostics, system s: SystemDiagnostics, pairings: [PairingID: HostMeta],
                             version: String, now: Date, language L: HostLanguage) -> [Item] {
        var out: [Item] = []
        func item(_ ok: Bool?, _ text: String, _ action: DiagnosticAction? = nil) {
            out.append(Item(ok == nil ? .unknown : ok! ? .ok : .bad, text, action: ok == true ? nil : action))
        }
        out.append(Item(nil, "ShareScale Host \(version)", section: .header))
        item(!d.paused, d.paused ? L.t("一時停止中", "Paused") : L.t("動作中", "Running"))
        var listening = false
        if case .listening = d.listener { listening = true }
        item(listening, MenuModel.listenerLine(d, L))
        if Limits.ephemeralPortRange.contains(d.port) {
            // 黙って既定に戻さず、注意だけ出す（通信口は環境設定の `port` を直接書いた時にだけ変わる。計画 2g）
            item(false, L.t("ポート \(d.port) は 49152〜65535 の範囲です。この範囲のポートは macOS がほかの通信に割り当てるため、ポートを取られて接続を受け付けられなくなることがあります。ポートを 49152 より小さい値（既定は 47651）に戻してください",
                            "Port \(d.port) is in the range 49152–65535. macOS hands out ports in this range to other connections, so the port can be taken and ShareScale Host may stop accepting connections. Set the port back to a value below 49152 (the default is 47651)"))
        }
        switch s.firewall {
        case .off: item(true, L.t("ファイアウォール: オフ", "Firewall: off"))
        case .blockAll:
            item(false, L.t("ファイアウォールで「外部からの接続をすべてブロック」がオンになっています。システム設定 › ネットワーク › ファイアウォール › オプションでオフにしてください",
                            "The firewall is set to block all incoming connections. Turn this off in System Settings › Network › Firewall › Options"), .openFirewallSettings)
        case let .on(rule):
            switch rule {
            case .blocked:
                item(false, L.t("ファイアウォールが ShareScale Host への接続をブロックしています。システム設定 › ネットワーク › ファイアウォール › オプションで、ShareScale Host を「外部からの接続を許可」にしてください",
                                "The firewall is blocking connections to ShareScale Host. In System Settings › Network › Firewall › Options, set ShareScale Host to Allow incoming connections"), .openFirewallSettings)
            case .allowed: item(true, L.t("ファイアウォール: オン（ShareScale Host への接続は許可されています）", "Firewall: on (connections to ShareScale Host are allowed)"))
            // まだ一覧に無い: 確認が出る時機は、実機（macOS 27.0.1。ファイアウォールはオン・ステルス）で 2026-10-02 に確かめた。Host が待ち受けを
            // 始めた時点では出ず、別の Mac から最初の接続が来た時に出た。ほかの版では確かめていないので、「ことがあります」と書く（点検 2i）
            case .notInRules: item(nil, L.t("ファイアウォール: オン（ShareScale Host はまだ一覧にありません。初めて接続を受けた時に、macOS が許可を求めることがあります。その時は「許可」をクリックしてください）", "Firewall: on (ShareScale Host isn’t listed yet. macOS may ask the first time ShareScale Host receives a connection; if macOS asks, click Allow)"))
            case .unknown: item(nil, L.t("ファイアウォール: オン（ShareScale Host の設定を読み取れません）", "Firewall: on (can’t read the setting for ShareScale Host)"), .openFirewallSettings)
            }
        case let .unknown(why): item(nil, L.t("ファイアウォールの状態を読み取れません: ", "Can’t read the firewall state: ") + why, .openFirewallSettings)
        }
        switch s.loginItem {
        case .enabled: item(true, L.t("ログイン項目: オン", "Login item: on"))
        case .requiresApproval:
            item(false, L.t("ログイン項目で ShareScale がオフになっています。システム設定 › 一般 › ログイン項目でオンにしてください",
                            "ShareScale is turned off in Login Items. Turn it on in System Settings › General › Login Items"), .openLoginItemsSettings)
        case .notRegistered: item(false, L.t("ログイン項目: 未登録（ShareScale の「この Mac を接続先にする」で登録します）", "Login item: not registered (turn on Use This Mac as a Target in ShareScale)"))
        case .notFound: item(nil, L.t("ログイン項目: ShareScale で確認してください（ShareScale Host からは読み取れません）", "Login item: check in ShareScale (ShareScale Host can’t read it)"))
        case .unknown: item(nil, L.t("ログイン項目: 不明", "Login item: unknown"), .openLoginItemsSettings)
        }
        switch s.fileVault {
        case true?: item(true, L.t("FileVault: オン", "FileVault: on"))
        case false?: item(false, L.t("FileVault がオフです。ペアリングの鍵はディスクに保存されるため、オンにすることをお勧めします", "FileVault is off. Pairing keys are stored on disk, so turning it on is recommended"), .openFileVaultSettings)
        case nil: item(nil, L.t("FileVault: 不明", "FileVault: unknown"), .openFileVaultSettings)
        }
        if d.updating { item(false, L.t("アップデートの途中です。ShareScale を開くと完了します", "An update is in progress. Open ShareScale to finish it")) }
        if d.contention { item(false, L.t("表示倍率が何度も元に戻されています", "The display scale keeps being changed back")) }
        if !d.updating, !d.contention {   // 更新の途中・奪い合いの時の直近のエラーは、上の行と同じ内容なので重ねない（メニュー・設定のカードと同じ。再点検 2i）
            item(d.lastError == nil, d.lastError.map { L.t("直近のエラー: ", "Last error: ") + TextRules.stripControls($0) } ?? L.t("直近のエラー: なし", "Last error: none"))
        }
        item(d.storeProblems.isEmpty, d.storeProblems.isEmpty ? L.t("ペアリングのファイル: 問題なし", "Pairing files: OK")
             : L.t("読み込めないペアリングのファイル（ペアリングし直すか、アクセス権を直してください）: ", "Unreadable pairing files (pair again or fix permissions): ")
               + d.storeProblems.map { "\(shortName($0.name)) (\($0.reason.rawValue))" }.joined(separator: ", "))
        if let e = d.engineProblem { item(false, L.t("設定（engine.json）: ", "Settings (engine.json): ") + e) }
        if let e = d.logProblem { item(false, L.t("ログ: ", "Log: ") + e) }
        if d.rejectedGlobalLast24h > 0 {
            item(nil, L.t("直近 24 時間に、インターネットからの接続を \(d.rejectedGlobalLast24h) 件拒否しました（受け付けるには「インターネットからの接続も受け付ける」をオンにします）",
                          "Refused \(HostLanguage.count(d.rejectedGlobalLast24h, "connection", "connections")) from the internet in the last 24 hours (to accept them, turn on Also accept connections from the internet)"))
        }
        out.append(Item(nil, L.t("接続元の Mac: \(pairings.count) 台", "Macs allowed to connect: \(pairings.count)"), section: .viewers))
        for (id, m) in pairings.sorted(by: { $0.key.hex < $1.key.hex }) {
            out.append(Item(nil, "  " + L.displayName(m.name) + " (\(id.hex.prefix(8))) — " + MenuModel.detail(m, now: now, L), section: .viewers))
        }
        return out
    }

    /// 読めないファイルの名前の id（32 文字の hex）を先頭 8 文字に切る（接続元の Mac の行と揃える）。ほかの名前はそのまま
    static func shortName(_ name: String) -> String {
        guard let dot = name.firstIndex(of: "."), PairingID(hex: String(name[..<dot])) != nil else { return name }
        return String(name[..<dot].prefix(8)) + "…" + String(name[dot...])
    }
}
