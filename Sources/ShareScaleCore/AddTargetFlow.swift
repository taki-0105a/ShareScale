import Foundation
import ShareScaleProtocol

/// 接続先の追加の窓の状態（仕様「ペアリング」の見る側の画面。純粋な値）。
/// 入力（接続コード／手入力）→ 検査（`check`）→ 名乗り中（`.connecting`）→ 確認番号の表示（`.awaitingApproval`）→ 確定中（`.confirming`）→
/// 結果（`.finished`: 確定／未確定／失敗／やめた／保存の後にやめた）。
/// - 「やめる」は進行中なら `.cancelling` にする（呼び出し側が `PairingFlow.run` の Task を取り消し、戻るのを待つ。保存の後なら未確定のまま帳簿に残る）
/// - 保存の後（確定の `status` を試している間など）にやめた時は「やめた」とは分ける（`.cancelledAfterSave`）。接続先は未確定のまま帳簿に残り、
///   接続先（Host）でも登録が済んでいるので、「追加をキャンセルしました」と出すと実態と逆になる（計画 2g の点検）
/// - 進み具合（`PairingFlow.Phase`）は呼ばれるスレッドが決まっていないので、画面は主スレッドに移してから `receive` に渡す。
///   移す途中で順が入れ替わっても戻らないよう、今より後の段階だけを受け取る。試行の番号（`run`）の違うもの・やめている途中・終わった後のものは捨てる
public struct AddTargetFlow: Equatable, Sendable {
    public enum Tab: Equatable, Sendable { case code, manual }

    public enum Step: Equatable, Sendable {
        case input                          // 入力中
        case connecting                     // 候補を試している（名乗りの前）
        case awaitingApproval(code: Int)    // 確認番号を出して、接続先の承認を待っている
        case confirming(attempt: Int)       // 新しい秘密で `status` を試している（1〜3）
        case cancelling                     // 「やめる」を押した（`PairingFlow.run` が戻るのを待っている）
        case finished(Finish)
    }

    public enum Finish: Equatable, Sendable {
        case confirmed(PairingID, name: String)
        case unconfirmed(PairingID, name: String, reason: String)
        case failed(PairingFlow.Failure)
        case cancelled
        /// 保存の後にやめた（接続先は未確定のまま帳簿に残っている。Host でも登録済み）
        case cancelledAfterSave(PairingID, name: String)
    }

    /// 今の欄の検査の結果
    public enum Check: Equatable, Sendable {
        case empty                          // まだ入力が足りない（理由は出さない）
        case invalid(String)                // 断る理由（1 文）
        case ready(PairingFlow.Entry)
    }

    public var tab: Tab = .code
    public var code = ""
    public var address = ""
    public var key = ""
    public private(set) var step: Step = .input
    /// 試行の番号（`start` のたびに増やす。前の試行の知らせを捨てるため）
    public private(set) var run = 0
    /// 進行中・直前の試行に使った欄（接続コードの時だけ、成功の後にクリップボードを消す）
    public private(set) var usedTab: Tab?

    public init() {}

    public var check: Check {
        switch tab {
        case .code:
            guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
            switch PairingFlow.entry(code: code) {
            case let .success(e): return .ready(e)
            case let .failure(f): return .invalid(AddTargetText.inputProblem(f))
            }
        case .manual:
            let a = ManualEntry.normalize(address)
            if !a.isEmpty {
                do { _ = try ManualEntry.parseAddress(a) }
                catch let e as ManualEntry.AddressError { return .invalid(AddTargetText.inputProblem(.address(e))) }
                catch { return .invalid(AddTargetText.inputProblem(.address(.badHost))) }
            }
            let count = AddTargetText.keyPreview(key).count
            if a.isEmpty, count > 0 { return .invalid(AddTargetText.inputProblem(.address(.empty))) }   // キーより先にアドレスを求める
            guard !a.isEmpty, count >= AddTargetText.keyLength else {
                return count > AddTargetText.keyLength ? .invalid(AddTargetText.inputProblem(.key(.badLength))) : .empty
            }
            switch PairingFlow.entry(address: a, key: key) {
            case let .success(e): return .ready(e)
            case let .failure(f): return .invalid(AddTargetText.inputProblem(f))
            }
        }
    }

    /// 接続コードの期限を自分の時計で 10 分以上過ぎていれば注意（拒否はしない）
    public func expiryWarning(now: Int64) -> String? {
        guard tab == .code, case let .ready(e) = check, e.probablyExpired(now: now) else { return nil }
        return AddTargetText.expiryWarning
    }

    /// 「追加する」を押せるか
    public var canStart: Bool {
        guard step == .input, case .ready = check else { return false }
        return true
    }
    /// 名乗りを進めている（やめている途中を含む）
    public var isRunning: Bool { Self.rank(step) != nil || step == .cancelling }

    /// 「追加する」: 検査が通っていれば名乗りを始める（試行の番号と入口を返す）
    public mutating func start() -> (run: Int, entry: PairingFlow.Entry)? {
        guard step == .input, case let .ready(e) = check else { return nil }
        run += 1
        usedTab = tab
        step = .connecting
        return (run, e)
    }

    /// 進み具合を受け取る（今より後の段階だけ）
    public mutating func receive(_ phase: PairingFlow.Phase, run r: Int) {
        guard r == run, let current = Self.rank(step), Self.rank(phase) > current else { return }
        switch phase {
        case .connecting: step = .connecting
        case let .awaitingApproval(c): step = .awaitingApproval(code: c)
        case let .confirming(a): step = .confirming(attempt: a)
        }
    }

    /// 「やめる」: 進行中なら `.cancelling` にして true（呼び出し側が Task を取り消す）。入力中・終わった後は false（窓を閉じるだけ）
    public mutating func cancel() -> Bool {
        guard Self.rank(step) != nil else { return false }
        step = .cancelling
        return true
    }

    /// `PairingFlow.run` の結果（`name` は追加した接続先の表示名。分からなければ id の先頭 8 文字）。
    /// `saved` は、やめた（`.failure(.cancelled)`）時に帳簿に残っていた接続先の id（保存の後にやめた。無ければ nil）
    public mutating func finish(_ result: Result<PairingFlow.Outcome, PairingFlow.Failure>, run r: Int, name: String?, saved: PairingID? = nil) {
        guard r == run, isRunning else { return }
        switch result {
        case let .success(.confirmed(id)):
            step = .finished(.confirmed(id, name: name ?? String(id.hex.prefix(8))))
        case let .success(.unconfirmed(id, reason)):
            step = .finished(.unconfirmed(id, name: name ?? String(id.hex.prefix(8)), reason: reason))
        case .failure(.cancelled):
            step = .finished(saved.map { .cancelledAfterSave($0, name: name ?? String($0.hex.prefix(8))) } ?? .cancelled)
        case let .failure(f):
            step = .finished(.failed(f))
        }
    }

    /// 失敗・やめた後の「やり直す」: 入力に戻る（入力した文字は残す）
    public mutating func retry() {
        switch step {
        case .finished(.failed), .finished(.cancelled): step = .input
        default: break
        }
    }

    /// 1 回の変更を貼り付け（⌘V）とみなすか: 前後の共通の先頭と末尾を除いた挿入部分が 20 文字以上で、新しい文字列が `sharescale1:` を含む。
    /// 手で打つ変更は 1 文字ずつなので当たらない。コードの上に別のコードを貼った時（選んで置き換え）も当たる
    public static func looksPasted(old: String, new: String) -> Bool {
        guard new.contains(PairingCode.prefix) else { return false }
        let o = Array(old), n = Array(new)
        var head = 0
        while head < o.count, head < n.count, o[head] == n[head] { head += 1 }
        var tail = 0
        while tail < o.count - head, tail < n.count - head, o[o.count - 1 - tail] == n[n.count - 1 - tail] { tail += 1 }
        return n.count - head - tail >= 20
    }

    static func rank(_ s: Step) -> Int? {
        switch s {
        case .connecting: return 1
        case .awaitingApproval: return 2
        case let .confirming(a): return 2 + max(1, a)
        case .input, .cancelling, .finished: return nil
        }
    }
    static func rank(_ p: PairingFlow.Phase) -> Int {
        switch p {
        case .connecting: return 1
        case .awaitingApproval: return 2
        case let .confirming(a): return 2 + max(1, a)
        }
    }
}

/// 接続先の追加の窓の文言（DESIGN.md「文言」: 丁寧で簡潔・「！」なし・エラーは「何が起きたか」＋「何をすればよいか」）
public enum AddTargetText: Sendable {
    /// 手入力のキーの文字数（77 文字＋検査文字 1 文字）
    public static let keyLength = 78

    public static var expiryWarning: String {
        tr("この接続コードは有効期限が過ぎている可能性があります。このまま試すこともできますが、接続できない場合は接続先で新しいコードを作成してください。",
           "This pairing code may have expired. You can still try it, but if it doesn’t work, create a new code on the Host.")
    }

    /// 入力を断る理由（1 文）
    public static func inputProblem(_ e: PairingFlow.InputError) -> String {
        switch e {
        case .code(.tooLarge):
            return tr("接続コードが長すぎます。接続先の「接続コード」ウインドウで「コピー」をクリックし、貼り付け直してください。", "The pairing code is too long. Click Copy in the Pairing Code window on the Host, then paste it again.")
        case .code(.notSharescale):
            return tr("接続コードは「sharescale1:」で始まります。接続先の「接続コード」ウインドウで「コピー」をクリックし、貼り付け直してください。", "A pairing code starts with “sharescale1:”. Click Copy in the Pairing Code window on the Host, then paste it again.")
        case .code(.badEncoding), .code(.badJSON), .code(.unknownOrMissingKey):
            return tr("接続コードが途中で切れているか、形式が正しくありません。接続先の「接続コード」ウインドウで「コピー」をクリックし、貼り付け直してください。", "The pairing code is cut off or malformed. Click Copy in the Pairing Code window on the Host, then paste it again.")
        case .code(.badVersion):
            return tr("このバージョンの ShareScale では読み込めない接続コードです。両方の Mac で同じバージョンの ShareScale を使ってください。", "This version of ShareScale can’t read the code. Use the same version of ShareScale on both Macs.")
        case .code(.badID), .code(.badSecret), .code(.badPort), .code(.badAddresses), .code(.badExpiry):
            return tr("接続コードの内容が正しくありません。接続先の「接続コード」ウインドウで「コピー」をクリックし、貼り付け直してください。", "The pairing code’s contents are invalid. Click Copy in the Pairing Code window on the Host, then paste it again.")
        case .address(.empty):
            return tr("アドレスを入力してください。", "Enter the address.")
        case .address(.badHost):
            return tr("アドレスの形式が正しくありません。接続先の「接続コード」ウインドウに表示されている「アドレス」をそのまま入力してください。", "The address isn’t valid. Enter the Address shown in the Pairing Code window on the Host exactly as shown.")
        case .address(.badPort):
            return tr("ポート（「:」の後）は 1〜65535 の数字にしてください。", "The port (after “:”) must be a number from 1 to 65535.")
        case .address(.ipv6NeedsBrackets):
            return tr("IPv6 のアドレスは [ ] で囲んでください（例 [fd7a::1]:47651）。", "Put an IPv6 address in [ ] (for example [fd7a::1]:47651).")
        case .key(.badLength):
            return tr("キーの文字数が正しくありません（区切りの空白を除いて 78 文字です）。", "The key has the wrong length (it’s 78 characters, not counting spaces).")
        case .key(.badCharacter):
            return tr("キーに使えない文字が含まれています。接続先の「接続コード」ウインドウの「キー」と見比べてください。", "The key contains characters that aren’t allowed. Compare it with the Key in the Pairing Code window on the Host.")
        case .key(.badPadding), .key(.checksumMismatch):
            return tr("キーに入力の誤りがあります。接続先の「接続コード」ウインドウの「キー」と 4 文字ずつ見比べてください。", "The key has a typo. Compare it with the Key in the Pairing Code window on the Host, four characters at a time.")
        }
    }

    /// 手入力のキーの表示補助（NFKC・大文字・空白とハイフンを除いた文字を 4 文字ずつ）
    public struct KeyPreview: Equatable, Sendable {
        public let groups: [String]
        public let count: Int
        /// VoiceOver 用（まとまりごとに、文字を 1 つずつ）
        public var accessibility: [String] { groups.map { $0.map(String.init).joined(separator: " ") } }
    }
    public static func keyPreview(_ key: String) -> KeyPreview {
        let s = ManualEntry.normalize(key).uppercased().filter { $0 != " " && $0 != "-" && !$0.isWhitespace }
        let groups = ManualEntry.grouped(s).split(separator: " ").map(String.init)
        return KeyPreview(groups: groups, count: s.count)
    }

    /// 確認番号の表示（「012 345」）と VoiceOver の読み（数字を 1 つずつ。Host の確認の窓 `ApprovalPresentation` と同じ流儀）
    public static func code(_ n: Int) -> String { ConfirmationCode.format(n) }
    public static func codeAccessibility(_ n: Int) -> String {
        tr("確認番号 ", "Confirmation number ") + ConfirmationCode.format(n).filter(\.isNumber).map(String.init).joined(separator: " ")
    }

    /// 進行中の見出しと添え書き
    public static func progress(_ step: AddTargetFlow.Step, confirmAttempts: Int = 3) -> ViewerNotice.Text? {
        switch step {
        case .connecting:
            return ViewerNotice.Text(tr("接続先に接続しています…", "Connecting to the Host…"),
                                     tr("接続すると、接続先に確認のウインドウが表示されます。", "Once connected, a confirmation window appears on the Host."))
        case .awaitingApproval:
            return ViewerNotice.Text(tr("確認番号", "Confirmation Number"),
                                     tr("接続先に同じ番号が表示されていれば、接続先で「追加する」をクリックしてください。", "If the Host shows the same number, click Add on the Host."))
        case let .confirming(a):
            return ViewerNotice.Text(tr("登録を確認しています（\(a)/\(confirmAttempts)）…", "Confirming (\(a)/\(confirmAttempts))…"),
                                     tr("接続先に接続し直しています。", "Reconnecting to the Host."))
        case .cancelling:
            return ViewerNotice.Text(tr("キャンセルしています…", "Cancelling…"), tr("接続先との通信が終わるまでお待ちください。", "Waiting for the connection to finish."))
        case .input, .finished:
            return nil
        }
    }

    /// 結果の見出し・本文・誤りか・コピーできる生の内容
    public struct ResultText: Equatable, Sendable {
        public let text: ViewerNotice.Text
        public let isError: Bool
        public let copyable: String?
    }
    public static func result(_ f: AddTargetFlow.Finish) -> ResultText {
        switch f {
        case let .confirmed(_, name):
            return ResultText(text: ViewerNotice.Text(tr("「\(name)」を追加しました", "Added “\(name)”"),
                                                  tr("メインウインドウで表示倍率を切り替えられます。", "You can switch the display scale in the main window.")), isError: false, copyable: nil)
        case let .unconfirmed(_, name, reason):
            return ResultText(text: ViewerNotice.Text(tr("「\(name)」を追加しました（確認待ち）", "Added “\(name)” (pending confirmation)"),
                                                  tr("接続先の ShareScale Host のメニューにこの Mac が表示されているか確認し、表示されていなければペアリングし直してください。", "Check that this Mac appears in the ShareScale Host menu on the Host. If it doesn’t, pair again.")),
                          isError: true, copyable: reason)
        case .cancelled:
            return ResultText(text: ViewerNotice.Text(tr("追加をキャンセルしました", "Cancelled"),
                                                  tr("接続先に確認のウインドウが表示されている場合は「追加しない」をクリックしてください。", "If a confirmation window is showing on the Host, click Don’t Add.")), isError: false, copyable: nil)
        case let .cancelledAfterSave(_, name):
            // キャンセルより前に保存まで済んでいた（接続先でも登録済み）。「キャンセルしました」とは出さない
            return ResultText(text: ViewerNotice.Text(tr("「\(name)」は追加されています（確認待ち）", "“\(name)” was already added (pending confirmation)"),
                                                  tr("キャンセルの前に、接続先での登録が済んでいました。不要な場合は、設定 › 接続先で削除してください。",
                                                     "The Host had already registered this Mac before you cancelled. If you don’t need it, delete it in Settings › Targets.")),
                          isError: true, copyable: nil)
        case let .failed(e):
            return failure(e)
        }
    }

    static func failure(_ e: PairingFlow.Failure) -> ResultText {
        switch e {
        case .limitReached:
            return ResultText(text: ViewerNotice.Text(tr("これ以上追加できません", "Can’t add more targets"),
                                                  tr("接続先は \(Limits.maxPairings) 台まで登録できます。設定 › 接続先で、使わない接続先を削除してください。", "You can add up to \(Limits.maxPairings) targets. Delete one you don’t use in Settings › Targets.")),
                          isError: true, copyable: nil)
        case let .connection(f):
            return ResultText(text: connection(f), isError: true, copyable: rawDetail(f))
        case .pairing(.notPaired):
            return ResultText(text: ViewerNotice.Text(tr("接続先で追加されませんでした", "The Host didn’t add this Mac"),
                                                  tr("接続先に確認のウインドウが表示されている場合は「追加しない」をクリックしてから、新しい接続コードでペアリングし直してください。",
                                                     "If a confirmation window is showing on the Host, click Don’t Add. Then create a new pairing code on the Host and pair again.")),
                          isError: true, copyable: nil)
        case .pairing(.timedOut):
            return ResultText(text: ViewerNotice.Text(tr("接続先で時間内に「追加する」がクリックされませんでした", "Add wasn’t clicked on the Host in time"),
                                                  tr("接続先で新しい接続コードを作成し、確認のウインドウが表示されたら、時間内に「追加する」をクリックしてください。",
                                                     "Create a new pairing code on the Host, then click Add in the confirmation window before time runs out.")),
                          isError: true, copyable: nil)
        case let .pairing(f):
            return ResultText(text: ViewerNotice.Text(tr("ペアリングの途中で接続が切れました", "The connection dropped while pairing"),
                                                  tr("接続先で新しい接続コードを作成して、もう一度試してください。続く場合は「詳細をコピー」で内容を控えてください。",
                                                     "Create a new pairing code on the Host and try again. If this keeps happening, use Copy Details to save the message.")),
                          isError: true, copyable: "\(f)")
        case let .save(raw):
            return ResultText(text: ViewerNotice.Text(tr("この Mac に保存できませんでした", "Couldn’t save on this Mac"),
                                                  tr("~/Library/Application Support/ShareScale/pairings/viewer/ のアクセス権を確認してから、新しい接続コードでペアリングし直してください（接続先では 10 分後に自動的に登録が解除されます）。",
                                                     "Check the permissions of ~/Library/Application Support/ShareScale/pairings/viewer/, then pair again with a new code (the Host removes this pairing automatically after 10 minutes).")),
                          isError: true, copyable: raw)
        case .cancelled:
            return result(.cancelled)
        }
    }

    /// コードの秘密でつながらなかった時（TLS が成立しない＝使用済み・期限切れ・取り消されたコード）
    static func connection(_ f: ViewerFailure) -> ViewerNotice.Text {
        switch f {
        case .localNetworkDenied:
            return ViewerNotice.Text(tr("ローカルネットワークへのアクセスが許可されていません", "Local network access isn’t allowed"),
                                     tr("システム設定 › プライバシーとセキュリティ › ローカルネットワークで ShareScale をオンにしてから、もう一度試してください。",
                                        "Turn on ShareScale in System Settings › Privacy & Security › Local Network, then try again."))
        case .handshakeFailed:
            return ViewerNotice.Text(tr("接続コードを使えませんでした", "The pairing code didn’t work"),
                                     tr("使用済みか、有効期限が切れたか、取り消されたコードの可能性があります。接続先の ShareScale Host のメニューで「接続元の Mac を追加…」をもう一度選び、新しいコードで試してください。",
                                        "It may have been used, expired, or revoked. On the Host, choose Add a Mac to Connect From… in the ShareScale Host menu again and try the new code."))
        case .timedOut, .unreachable:
            // 主の窓の「接続できません」と同じ見出し・同じ確認すること（ファイアウォールの手がかりを含む。計画 2i。
            // 接続先でファイアウォールの確認が出ている間は、ここで止まる）
            return ViewerNotice.Text(ViewerNotice.unreachableTitle, ViewerNotice.unreachableChecks(hostName: nil))
        case .notPaired, .unsupportedVersion, .paused, .busy, .cancelled, .other:
            return ViewerNotice.Text(tr("接続先と通信できませんでした", "Couldn’t communicate with the Host"),
                                     tr("少し待ってから、もう一度試してください。続く場合は「詳細をコピー」で内容を控えてください。",
                                        "Wait a moment and try again. If this keeps happening, use Copy Details to save the message."))
        }
    }

    static func rawDetail(_ f: ViewerFailure) -> String? {
        if case let .other(raw) = f { return raw }
        return nil
    }
}
