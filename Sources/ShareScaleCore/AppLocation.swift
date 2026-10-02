import Darwin
import Foundation
import ShareScaleHostCore

/// アプリの識別子と置き場所（仕様「置き場所と識別子」「配布」）
public enum AppIdentifiers {
    public static let app = BundleIdentifiers.app
    public static let host = BundleIdentifiers.host
    /// 開発の組み立ての印（`scripts/build-sharescale.sh --dev` の時だけ Info.plist に入る）
    public static let developmentBuildKey = "ShareScaleDevelopmentBuild"
    /// Homebrew の置き場所として認める `<prefix>`（アプリは `brew` を実行しない）
    public static let homebrewPrefixes = ["/opt/homebrew", "/usr/local"]
    public static let formula = "sharescale"
    public static let bundleName = "ShareScale.app"
}

/// 利用者のホームの下の置き場所（試験は一時フォルダをホームとして渡す）
public struct AppPaths: Equatable, Sendable {
    public let home: URL
    public init(home: URL) { self.home = home }
    public static func standard() -> AppPaths { AppPaths(home: FileManager.default.homeDirectoryForCurrentUser) }

    /// 複製（`~/Applications/ShareScale.app`）
    public var copy: URL { home.appendingPathComponent("Applications/\(AppIdentifiers.bundleName)", isDirectory: true) }
    public var applications: URL { home.appendingPathComponent("Applications", isDirectory: true) }
    /// 状態・設定（`~/Library/Application Support/ShareScale`）
    public var support: URL { home.appendingPathComponent("Library/Application Support/ShareScale", isDirectory: true) }
    public var pairings: URL { support.appendingPathComponent("pairings", isDirectory: true) }
    public var hostControl: URL { support.appendingPathComponent("host-control", isDirectory: true) }
    public var appState: URL { support.appendingPathComponent("app-state.json") }
    public var logs: URL { home.appendingPathComponent("Library/Logs/ShareScale", isDirectory: true) }
    /// 環境設定の 2 つのファイル（見る側・Host）
    public var preferenceFiles: [URL] {
        [AppIdentifiers.app, AppIdentifiers.host].map { home.appendingPathComponent("Library/Preferences/\($0).plist") }
    }
    public var savedState: URL { home.appendingPathComponent("Library/Saved Application State/\(AppIdentifiers.app).savedState", isDirectory: true) }
}

/// 起動した場所から決まる役（仕様「`~/Applications` への複製と引き渡し」）。
/// - `homebrew`: 自分の実体のパスが `<prefix>/Cellar/sharescale/<版>/ShareScale.app`（`<prefix>` は `/opt/homebrew` か `/usr/local`）。複製を作る・置き換える・開くだけ
/// - `copy`: `~/Applications/ShareScale.app`。見る側として動き、ログイン項目の登録と取り除きを行う
/// - `development`: 上のどちらでもなく、Info.plist に `ShareScaleDevelopmentBuild` がある（`--dev` の組み立て）。見る側として動く
/// - `elsewhere`: それ以外（組み立てたままのフォルダなど）。案内して終了する
public enum AppRole: Equatable, Sendable {
    case homebrew(HomebrewBundle)
    case copy
    case development
    case elsewhere

    /// 見る側の窓を出して動く役か
    public var runsViewer: Bool { self == .copy || self == .development }
    /// ログイン項目の登録・解除を行える役か（開発の組み立ては注意を添えて行える）
    public var canRegisterLoginItem: Bool { self == .copy || self == .development }
    /// 「ShareScale を取り除く」を行える役か（複製だけ）
    public var canUninstall: Bool { self == .copy }
}

/// Homebrew 側（Cellar の中の実体）
public struct HomebrewBundle: Equatable, Sendable {
    public let prefix: String       // `/opt/homebrew` か `/usr/local`
    public let realPath: String     // `<prefix>/Cellar/sharescale/<版>/ShareScale.app`
    /// 複製元として記録する版に依らない場所（`<prefix>/opt/sharescale/ShareScale.app`）
    public var optPath: String { "\(prefix)/opt/\(AppIdentifiers.formula)/\(AppIdentifiers.bundleName)" }
}

public enum AppLocation {
    /// 役を決める（純粋な関数）。`bundlePath` はシンボリックリンクを解決した実体のパス、`home` も解決したもの
    public static func classify(bundlePath: String, home: String, isDevelopmentBuild: Bool) -> AppRole {
        let path = trimmed(bundlePath)
        if let h = homebrew(path) { return .homebrew(h) }
        if path == trimmed(home) + "/Applications/" + AppIdentifiers.bundleName { return .copy }
        return isDevelopmentBuild ? .development : .elsewhere
    }

    /// `<prefix>/Cellar/sharescale/<版>/ShareScale.app` の形なら Homebrew 側（`<版>` は 1 つのフォルダの名前で、`.`・`..` は認めない）。
    /// 複製が Homebrew 側を開く前にも、解決した実体のパスがこの形かを確かめる（計画 2e-1 の点検 D）
    public static func homebrew(_ path: String) -> HomebrewBundle? {
        for prefix in AppIdentifiers.homebrewPrefixes {
            let head = "\(prefix)/Cellar/\(AppIdentifiers.formula)/"
            guard path.hasPrefix(head), path.hasSuffix("/" + AppIdentifiers.bundleName) else { continue }
            let version = path.dropFirst(head.count).dropLast(AppIdentifiers.bundleName.count + 1)
            guard !version.isEmpty, !version.contains("/"), version != ".", version != ".." else { continue }
            return HomebrewBundle(prefix: prefix, realPath: path)
        }
        return nil
    }

    static func trimmed(_ p: String) -> String {
        var s = p
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// シンボリックリンクを解決した実体のパス（無ければ nil）
    public static func realPath(_ path: String) -> String? {
        if case let .success(p) = resolve(path) { return p }
        return nil
    }

    /// シンボリックリンクを解決した実体のパスか、解決できなかった理由（`errno` を後から読まない形。点検 T）
    public static func resolve(_ path: String) -> Result<String, POSIXError> {
        guard let r = realpath(path, nil) else { return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)) }
        defer { free(r) }
        return .success(String(cString: r))
    }

    /// Info.plist に開発の組み立ての印があるか
    public static func isDevelopmentBuild(_ info: [String: Any]?) -> Bool {
        (info?[AppIdentifiers.developmentBuildKey] as? Bool) == true
    }

    /// 複製（`~/Applications/ShareScale.app`）を、案内のウインドウのボタンから開いてよいか（計画 2h）。
    /// Homebrew 側が複製を開く時（`Handoff.plan` が断らない形）と同じ条件: リンクでない・本人のもの・ShareScale の識別子・版と署名を読める。
    /// 満たさないもの（リンク・ほかの利用者のもの・別のアプリ・署名の無いもの）は、アプリからは開かない（案内だけ）。
    /// さらに、複製の実体のパスが「複製」の役になること（`classify`）。`~/Applications` そのものがリンクだと、開いた先のアプリは実体のパスで役を決めるので
    /// 「それ以外」になり、同じ案内がまた出て堂々めぐりになる（点検 2h）。`home` は、リンクを解決したホーム
    public static func canOpenCopy(_ copy: CopySnapshot, home: String) -> Bool {
        guard let facts = copy.facts, !facts.isSymlink, facts.ownerIsMe else { return false }
        guard facts.bundle.identifier == AppIdentifiers.app, facts.bundle.version != nil, facts.bundle.cdhash != nil else { return false }
        guard let real = copy.realPath else { return false }
        return classify(bundlePath: real, home: home, isDevelopmentBuild: false) == .copy
    }

    /// それ以外の場所から開かれた時の案内（複製があればそれを、無ければ Homebrew から入れたアプリか予備の手順を案内する）。
    /// 複製を開ける時（`canOpenCopy`）は、既定のボタン「~/Applications の ShareScale を開く」を付ける（押すと複製を開いて、自分は終了する。
    /// 計画 2h。実機確認 A: 組み立て用のフォルダの ShareScale が名前で開かれ、案内のウインドウに気づかないまま止まっていた）。
    /// 自分（開かれた方）の版が複製より新しい時は、入れ直し方を 1 文添える（組み立てただけで、入れていない時。点検 2h）
    public static func elsewhereGuidance(copy: CopySnapshot, home: String, ownVersion: Int?) -> ElsewhereGuidance {
        if canOpenCopy(copy, home: home) {
            // 見出しとボタンで同じ文を重ねない（見出しは起きたこと、本文はすること、ボタンは動詞で始める）
            var detail = tr("~/Applications にインストールされている ShareScale を開いてください。", "Open the ShareScale installed in ~/Applications instead.")
            if let mine = ownVersion, let theirs = copy.facts?.bundle.version, mine > theirs {
                detail += tr("この場所の ShareScale の方が新しいバージョンです。インストールするには、ソースのフォルダで scripts/build-sharescale.sh --install を実行してください。",
                             " This copy is newer than the one in ~/Applications. To install it, run scripts/build-sharescale.sh --install in the source folder.")
            }
            return ElsewhereGuidance(title: tr("この場所の ShareScale は開けません", "This copy of ShareScale can’t be opened from here"), detail: detail,
                                     openCopyTitle: tr("~/Applications の ShareScale を開く", "Open ShareScale in ~/Applications"))
        }
        if copy.facts != nil {
            return ElsewhereGuidance(title: tr("~/Applications の ShareScale を開いてください", "Open ShareScale in ~/Applications"),
                                     detail: tr("このアプリはこの場所からは開けません。~/Applications/ShareScale.app を開いてください。",
                                                "This copy of ShareScale doesn’t run from here. Open ~/Applications/ShareScale.app."),
                                     openCopyTitle: nil)
        }
        return ElsewhereGuidance(title: tr("Homebrew でインストールした ShareScale を開いてください", "Open the ShareScale installed with Homebrew"),
                                 detail: tr("このアプリはこの場所からは開けません。ターミナルで open \"$(brew --prefix)/opt/sharescale/ShareScale.app\" を実行するか、ソースから scripts/build-sharescale.sh --install でインストールしてください。",
                                            "This copy of ShareScale doesn’t run from here. In Terminal, run open \"$(brew --prefix)/opt/sharescale/ShareScale.app\", or install from source with scripts/build-sharescale.sh --install."),
                                 openCopyTitle: nil)
    }

    /// 案内のウインドウを閉じた後に行うこと（純粋な判断。点検 2h）。
    /// - 既定のボタン以外（「終了」・ウインドウを閉じた）なら、何も開かずに終わる
    /// - 既定のボタンなら、**押した時の複製の様子を読み直して**（`recheck`。ウインドウを出している間に入れ替わっていないか）、開けなければ開かない
    /// - 複製が動いていれば、開き直しを頼む（主の窓を閉じてメニューバーにだけ居る時も、主の窓が出るように）。動いていなければ新しく開く
    public static func elsewhereAction(pressed: LaunchAlertButton, home: String, recheck: () -> CopySnapshot, copyRunning: () -> Bool) -> ElsewhereAction {
        guard pressed == .primary else { return .quit }
        guard canOpenCopy(recheck(), home: home) else { return .cannotOpen }
        return copyRunning() ? .reopenRunningCopy : .launchCopy
    }

    /// 動いている複製に開き直しを頼む手順（再点検 2h）: 前に出してから、**新しい実体を作らずに**開く
    /// （Finder や Dock から開いた時と同じ。動いているアプリに開き直しの知らせが届き、主の窓を閉じてメニューバーにだけ居る複製も、主の窓を開く）
    public static let reopenRunningCopySteps: [CopyOpenStep] = [.activateRunning, .open(newInstance: false)]
    /// 複製を新しく開く手順: **新しい実体として**開く（同じ識別子の自分が動いているので、既存のものが前に出るだけにならないように）
    public static let launchCopySteps: [CopyOpenStep] = [.open(newInstance: true)]

    /// 案内のボタンの後の、複製の開き方（手順の並び。前の並びで開けなければ、次の並びを試す）。
    /// 開き直しを頼めなかった時は、新しく開く手順に落とす（どちらも駄目なら、開けなかった案内）
    public static func openAttempts(for action: ElsewhereAction) -> [[CopyOpenStep]] {
        switch action {
        case .reopenRunningCopy: return [reopenRunningCopySteps, launchCopySteps]
        case .launchCopy: return [launchCopySteps]
        case .quit, .cannotOpen: return []
        }
    }
}

/// 複製を開く時の 1 手（純粋な値。`RunningCopies.run` が、この順に行う）
public enum CopyOpenStep: Equatable, Sendable {
    /// 動いている複製を前に出す
    case activateRunning
    /// `NSWorkspace.openApplication(at:)` で開く。`newInstance` が偽なら、新しい実体を作らない（動いていれば、開き直しの知らせだけが届く）
    case open(newInstance: Bool)
}

/// 複製（`~/Applications/ShareScale.app`）のある時点の様子: 中身（`CopyFacts`。無ければ nil）と、リンクを解決した実体のパス
public struct CopySnapshot: Equatable, Sendable {
    public var facts: CopyFacts?
    public var realPath: String?
    public init(facts: CopyFacts?, realPath: String?) { self.facts = facts; self.realPath = realPath }
    /// ディスクから読む（起動はしない）
    public static func read(_ copy: URL) -> CopySnapshot {
        CopySnapshot(facts: CopyFacts.read(copy), realPath: AppLocation.realPath(copy.path))
    }
}

/// それ以外の場所から開かれた時の案内のウインドウの中身（純粋な値。`LaunchFlow.elsewhere` が NSAlert に並べる）
public struct ElsewhereGuidance: Equatable, Sendable {
    public let title: String
    public let detail: String
    /// 既定のボタンの題名（複製を開ける時だけ。無ければ「終了」だけ）
    public let openCopyTitle: String?
    public init(title: String, detail: String, openCopyTitle: String?) { self.title = title; self.detail = detail; self.openCopyTitle = openCopyTitle }
}

/// 案内のウインドウを閉じた後に行うこと
public enum ElsewhereAction: Equatable, Sendable {
    /// 何も開かずに終わる
    case quit
    /// 開けない（「~/Applications の ShareScale を開けませんでした」と案内して終わる）
    case cannotOpen
    /// 動いている複製に開き直しを頼む（主の窓が出る）
    case reopenRunningCopy
    /// 複製を新しく開く
    case launchCopy
}

/// 窓を出す前の案内のウインドウ（`NSAlert`）のボタン
public enum LaunchAlertButton: Equatable, Sendable { case primary, quit, copy }

/// 案内のウインドウのボタンの並び（足す順。1 つ目が既定のボタン＝Return）と、押された番号の読み方（純粋な値。点検 2h）
public struct LaunchAlertLayout: Equatable, Sendable {
    /// 足す順: 既定のボタン（あれば）→「終了」→「詳細をコピー」（あれば）
    public let buttons: [LaunchAlertButton]
    public init(hasPrimary: Bool, hasCopyable: Bool) {
        buttons = (hasPrimary ? [.primary] : []) + [.quit] + (hasCopyable ? [.copy] : [])
    }
    /// 「終了」に Esc を当てるか（既定のボタンが別にある時だけ。無い時は「終了」が既定のボタンで Return）
    public var quitTakesEscape: Bool { buttons.first == .primary }
    /// 押されたボタン（`index` は足した順の番号。範囲の外＝ウインドウが別の形で閉じた時は「終了」）
    public func pressed(_ index: Int) -> LaunchAlertButton {
        buttons.indices.contains(index) ? buttons[index] : .quit
    }
}
