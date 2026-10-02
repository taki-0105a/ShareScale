import Foundation
import ShareScaleProtocol

/// 受け付けの上限（仕様「攻撃への備え」）
public struct AdmissionLimits: Sendable {
    public var maxConnections = 4            // 同時接続は全体で 4 本まで
    public var reservedForKnown = 1          // うち 1 本は、直近 24 時間に照合に成功した送り元のために空けておく
    public var maxPerSource = 1              // 同じ送り元は 1 本まで
    public var failuresPerWindow = 10        // 60 秒に 10 回を超えたら
    public var failureWindow: Duration = .seconds(60)
    public var lockout: Duration = .seconds(300)          // 5 分間受け付けない
    public var knownFor: Duration = .seconds(24 * 3600)   // 照合に成功した送り元を「知っている」とみなす期間
    public var lockoutTableMax = 1024
    public var knownTableMax = 256
    public init() {}
    public static let standard = AdmissionLimits()
}

/// どの送り元を受け付けるか（仕様「送り元の分類」「受け付けるネットワーク」）
public struct NetworkPolicy: Equatable, Sendable {
    public var tailscaleOnly = false          // 設定「Tailscale 経由だけ」
    public var allowGlobal = false            // 設定「インターネットからの接続も受け付ける」
    public var localNetworks: [IPNetwork] = []  // 「同じネットワークのグローバル」の範囲（Wi‑Fi・有線から作る）
    public init(tailscaleOnly: Bool = false, allowGlobal: Bool = false, localNetworks: [IPNetwork] = []) {
        self.tailscaleOnly = tailscaleOnly; self.allowGlobal = allowGlobal; self.localNetworks = localNetworks
    }
}

/// TLS の前に断る理由（どれも「失敗」には数えない）
public enum RejectReason: String, Sendable, CaseIterable {
    case unknownSource        // 送り元のアドレスが分からない
    case notTailscale         // 「Tailscale 経由だけ」で、Tailscale 以外から
    case sourceNotAccepted    // 既定で受け付けない分類（グローバルなど）
    case lockedOut            // 締め出し中
    case tooManyConnections   // 全体の上限
    case tooManyFromSource    // 同じ送り元の上限
    case reservedForKnown     // 残りの枠は、知っている送り元のためのもの
}

/// 受け付けた接続の札。終わったら `AdmissionPolicy.finish` に返す
public struct AdmissionTicket: Equatable, Sendable {
    public let bucket: String      // 締め出し・同時接続でまとめる単位（「送り元の分類」のまとめ方）
    public let sourceClass: SourceClass
    public let source: IPAddress
}

public enum AdmissionDecision: Equatable, Sendable {
    case admit(AdmissionTicket)
    case reject(RejectReason)
}

/// 受け付けの方針（純粋な値。時計は外から渡す。受け側を開き直しても保つよう、受け側とは別に持つ）
public struct AdmissionPolicy: Sendable {
    public var limits: AdmissionLimits
    public var network: NetworkPolicy
    private var openTotal = 0
    private var openPerBucket: [String: Int] = [:]
    private struct Failures { var times: [ContinuousClock.Instant]; var lockedUntil: ContinuousClock.Instant?; var touched: ContinuousClock.Instant }
    private var failures: [String: Failures] = [:]
    private var known: [String: ContinuousClock.Instant] = [:]   // 最後に照合に成功した時刻
    /// 断った接続の集計: 分の番号（`origin` からの分）→ 理由ごとの件数。24 時間より古い分は捨てる（件数そのものに上限は無い）
    private var rejections: [Int: [RejectReason: Int]] = [:]
    private let origin: ContinuousClock.Instant
    static let rejectionRetentionMinutes = 24 * 60

    /// `origin` は方針を作った時刻（断った接続の集計の分の番号の起点。時計を差し替える時は同じ時計の値を渡す）
    public init(limits: AdmissionLimits = .standard, network: NetworkPolicy = NetworkPolicy(), origin: ContinuousClock.Instant = ContinuousClock.now) {
        self.limits = limits; self.network = network; self.origin = origin
    }

    public var openConnections: Int { openTotal }

    /// 新しい接続を受け付けるか（TLS を始める前に呼ぶ）
    public mutating func decide(source: IPAddress?, now: ContinuousClock.Instant) -> AdmissionDecision {
        let r = evaluate(source: source, now: now)
        if case let .reject(reason) = r { recordRejection(reason, now: now) }
        return r
    }

    private mutating func evaluate(source: IPAddress?, now: ContinuousClock.Instant) -> AdmissionDecision {
        guard let source else { return .reject(.unknownSource) }
        if network.tailscaleOnly && !isTailscaleAddress(source) { return .reject(.notTailscale) }
        let d = SourceClassifier.classify(source, localNetworks: network.localNetworks, allowGlobal: network.allowGlobal)
        guard d.accepted else { return .reject(.sourceNotAccepted) }
        if let f = failures[d.bucket], let until = f.lockedUntil, until > now { return .reject(.lockedOut) }
        guard openTotal < limits.maxConnections else { return .reject(.tooManyConnections) }
        guard (openPerBucket[d.bucket] ?? 0) < limits.maxPerSource else { return .reject(.tooManyFromSource) }
        if !isKnown(d.bucket, now: now), openTotal >= limits.maxConnections - limits.reservedForKnown { return .reject(.reservedForKnown) }
        openTotal += 1
        openPerBucket[d.bucket, default: 0] += 1
        return .admit(AdmissionTicket(bucket: d.bucket, sourceClass: d.sourceClass, source: source))
    }

    /// 接続が終わった。失敗なら数え、上限を超えたら締め出す。
    /// `authenticated`（その接続で照合に成功した）なら「知っている送り元」に入れる（結末の種類では決めない。照合の後の `bad_request` や切断でも入れる）
    public mutating func finish(_ ticket: AdmissionTicket, outcome: HostOutcome, authenticated: Bool, now: ContinuousClock.Instant) {
        assert(openTotal > 0, "finish が二重に呼ばれた")
        openTotal = max(0, openTotal - 1)
        if let n = openPerBucket[ticket.bucket] { if n <= 1 { openPerBucket[ticket.bucket] = nil } else { openPerBucket[ticket.bucket] = n - 1 } }
        if outcome.countsAsFailure { recordFailure(ticket.bucket, now: now) }
        if authenticated { recordKnown(ticket.bucket, now: now) }
    }

    func isKnown(_ bucket: String, now: ContinuousClock.Instant) -> Bool {
        guard let t = known[bucket] else { return false }
        return now - t <= limits.knownFor
    }
    public func isLockedOut(_ bucket: String, now: ContinuousClock.Instant) -> Bool {
        guard let until = failures[bucket]?.lockedUntil else { return false }
        return until > now
    }
    /// `since` の分から今までに断った件数（診断・記録の集計に使う。理由ごと。分の単位で数える）
    public func rejectionCounts(since: ContinuousClock.Instant) -> [RejectReason: Int] {
        let from = minute(of: since)
        var out: [RejectReason: Int] = [:]
        for (m, counts) in rejections where m >= from { for (r, n) in counts { out[r, default: 0] += n } }
        return out
    }
    /// 診断用: 集計に残っている分の数
    var rejectionMinutes: Int { rejections.count }

    private func minute(of t: ContinuousClock.Instant) -> Int { Int(((t - origin) / .seconds(60)).rounded(.down)) }
    private mutating func recordRejection(_ reason: RejectReason, now: ContinuousClock.Instant) {
        let m = minute(of: now)
        if rejections[m] == nil {   // 新しい分に入った時だけ、24 時間より古い分を捨てる
            let cutoff = m - Self.rejectionRetentionMinutes
            rejections = rejections.filter { $0.key > cutoff }
        }
        rejections[m, default: [:]][reason, default: 0] += 1
    }

    private mutating func recordFailure(_ bucket: String, now: ContinuousClock.Instant) {
        var f = failures[bucket] ?? Failures(times: [], lockedUntil: nil, touched: now)
        f.times = f.times.filter { now - $0 <= limits.failureWindow }
        f.times.append(now)
        f.touched = now
        if f.times.count > limits.failuresPerWindow {
            f.lockedUntil = now + limits.lockout
            f.times = []
        }
        failures[bucket] = f
        evictOldest(&failures, max: limits.lockoutTableMax) { $0.touched }
    }
    private mutating func recordKnown(_ bucket: String, now: ContinuousClock.Instant) {
        known[bucket] = now
        evictOldest(&known, max: limits.knownTableMax) { $0 }
    }
    /// 表が上限を超えたら、いちばん古いものから捨てる
    private func evictOldest<V>(_ table: inout [String: V], max: Int, time: (V) -> ContinuousClock.Instant) {
        while table.count > max, let oldest = table.min(by: { time($0.value) < time($1.value) }) {
            table.removeValue(forKey: oldest.key)
        }
    }
}
