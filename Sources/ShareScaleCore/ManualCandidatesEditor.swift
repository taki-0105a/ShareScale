import Foundation
import ShareScaleProtocol

/// 接続先の候補アドレスと通信口を手で直す（設定の「接続先」の「候補を直す…」。仕様「見る側」の候補の更新。純粋な値）。
/// - 候補は 1 行に 1 件（`,` で区切ってもよい）。NFKC で全角を半角にし、前後の空白を除く。空の項目は無視し（「n 件目」にも数えない）、同じものは 1 件にする
/// - IPv6 は角括弧で囲んでも囲まなくてもよい（保存は角括弧なしの書き直した形）。ゾーン（`%en0`）は付けられない
/// - IP は書き直した形（小文字・0 の省略）で保存し、ホスト名は `CandidateAddress.isValid` の規則（数字だけの最後のラベル・`0x` で始まるものは不可）
/// - 通信口は 1〜65535（空なら既定の 47651）
/// - 返すのは「候補・通信口・手で直した印」の 3 つだけ（`Candidates`）。保存する側（`ViewerTargets.saveCandidates`）が帳簿の今の付帯情報を読み直し、
///   その 3 つだけを差し替える（窓を開いている間に名前や確定が変わっても、古い写しで上書きしない）
/// - 保存すると `manual: true`（Host の `status` の `addrs` で書き換えない）。「接続先に任せる」（`automatic`）は `manual: false` に戻す（候補は今のまま）
public struct ManualCandidatesEditor: Equatable, Sendable {
    public var addressesText: String
    public var portText: String
    /// 窓を開いた時の付帯情報（初めの表示と「接続先に任せる」を出すかの判断にだけ使う）
    public let original: ViewerMeta

    public init(_ meta: ViewerMeta) {
        original = meta
        addressesText = meta.addresses.joined(separator: "\n")
        portText = String(meta.port)
    }

    /// 直した値（候補・通信口・手で直した印）
    public struct Candidates: Equatable, Sendable {
        public let addresses: [String]
        public let port: Int
        public let manual: Bool
        public init(addresses: [String], port: Int, manual: Bool) { self.addresses = addresses; self.port = port; self.manual = manual }
        /// 付帯情報のこの 3 つだけを差し替えた形（名前・確定・付けた名前はそのまま。前回の候補は残っていれば持つ）。規則に合わなければ nil
        public func applied(to m: ViewerMeta) -> ViewerMeta? {
            ViewerMeta(name: m.name, port: port, addresses: addresses, manual: manual, lastOKAddress: m.lastOKAddress, confirmed: m.confirmed, alias: m.alias)
        }
    }

    public enum Problem: Error, Equatable, Sendable {
        case empty
        case tooMany(Int)
        case badAddress(line: Int, text: String)
        case badPort
        case invalid        // 候補の規則（`ViewerMeta`）に合わない
    }

    /// 直した値（`manual: true`）。規則に合わなければ理由
    public func validate() -> Result<Candidates, Problem> {
        var addrs: [String] = []
        let items = addressesText.split(whereSeparator: { $0.isNewline || $0 == "," }).map { ManualEntry.normalize(String($0)) }.filter { !$0.isEmpty }
        for (i, raw) in items.enumerated() {
            guard let a = Self.canonical(raw) else { return .failure(.badAddress(line: i + 1, text: raw)) }
            if !addrs.contains(a) { addrs.append(a) }
        }
        guard !addrs.isEmpty else { return .failure(.empty) }
        guard addrs.count <= Limits.maxCandidateAddresses else { return .failure(.tooMany(addrs.count)) }
        let p = ManualEntry.normalize(portText)
        let port: Int
        if p.isEmpty {
            port = Limits.defaultPort
        } else {
            guard p.count <= 5, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p), Limits.portRange.contains(n) else { return .failure(.badPort) }
            port = n
        }
        let c = Candidates(addresses: addrs, port: port, manual: true)
        guard c.applied(to: original) != nil else { return .failure(.invalid) }
        return .success(c)
    }

    /// 「接続先に任せる」: 手で直した印を外す（候補と通信口は今のまま）
    public var automatic: Candidates { Candidates(addresses: original.addresses, port: original.port, manual: false) }

    /// 1 件の書き直し（IP は書き直した形。IPv6 の角括弧は外す。ゾーンは不可）
    static func canonical(_ s: String) -> String? {
        var t = s
        if t.hasPrefix("["), t.hasSuffix("]") { t = String(t.dropFirst().dropLast()) }
        guard !t.contains("%") else { return nil }
        if let ip = IPAddress(t) { return ip.text }
        return CandidateAddress.isValid(t) ? t : nil
    }

    /// 断る理由（1 文）
    public static func message(_ p: Problem) -> String {
        switch p {
        case .empty:
            return tr("接続先のアドレスを 1 つ以上入力してください。", "Enter at least one address for the Host.")
        case let .tooMany(n):
            return tr("アドレスは \(Limits.maxCandidateAddresses) 個まで入力できます（今は \(n) 個）。", "You can enter up to \(Limits.maxCandidateAddresses) addresses (now \(n)).")
        case let .badAddress(line, text):
            return tr("\(line) 番目の「\(text)」はアドレスとして使えません。ホスト名（例: studio.local）か IP アドレスを入力してください。",
                      "Address \(line), “\(text)”, isn’t valid. Enter a host name (such as studio.local) or an IP address.")
        case .badPort:
            return tr("ポートは 1〜65535 の数字にしてください（空欄の場合は 47651）。", "The port must be a number from 1 to 65535 (leave it empty for 47651).")
        case .invalid:
            return tr("アドレスの形式が正しくありません。ホスト名か IP アドレスを 1 行に 1 つずつ入力してください。", "The addresses aren’t valid. Enter one host name or IP address per line.")
        }
    }
}
