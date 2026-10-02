import Foundation

/// 接続先のディスプレイ1枚の状態（CoreGraphics から読んだ値。テストでは作り物を渡す）
public struct DisplaySnapshot: Equatable, Sendable {
    public var uuid: String
    public var vendor: UInt32, model: UInt32, serial: UInt32
    /// 作業領域（論理サイズ）と実画素
    public var width: Int, height: Int, pixelWidth: Int, pixelHeight: Int

    public init(uuid: String, vendor: UInt32, model: UInt32, serial: UInt32,
                width: Int, height: Int, pixelWidth: Int, pixelHeight: Int) {
        self.uuid = uuid; self.vendor = vendor; self.model = model; self.serial = serial
        self.width = width; self.height = height; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }

    /// 画面共有が作る仮想ディスプレイの作り物の識別情報（製造元 "aapl"・製品 0x1234・シリアル "mvs"）。
    /// 物理モニタは本物の EDID を持つので一致しない。Apple の内部仕様なので将来変わりうる（その時は予備の方式）
    public var isScreenSharingVirtual: Bool { vendor == 0x6161_706c && model == 0x1234 && serial == 0x6d76_7300 }

    /// モニタの電源が切れていて画面共有もしていない時に macOS が置く代わりのディスプレイ（製造元 "unkn"・製品 "virt"。
    /// 実機 2026-09-24: シリアル 0・1920x1080）。物理モニタでも画面共有の仮想ディスプレイでもないので、学習にも選択にも使わない
    public var isPlaceholder: Bool { vendor == 0x756e_6b6e && model == 0x7669_7274 }

    /// 描画倍率（1=等倍、2=Retina）
    public var scaleFactor: Int { width > 0 ? max(1, pixelWidth / width) : 1 }
}

public enum ScaleMode: String, Equatable, Sendable {
    case x1 = "1x", x2 = "2x", off
    public var factor: Int? { switch self { case .x1: return 1; case .x2: return 2; case .off: return nil } }
}

/// 仮想ディスプレイの見つけ方
public enum SelectionSource: String, Sendable { case signature, learned, none }

public struct Selection: Equatable, Sendable {
    public let source: SelectionSource
    public let candidates: [DisplaySnapshot]
    /// 操作対象。候補がちょうど1枚の時だけ（2枚以上は取り違えを避けて触らない）
    public var target: DisplaySnapshot? { candidates.count == 1 ? candidates[0] : nil }
    public var ambiguous: Bool { candidates.count > 1 }
}

/// 判定の中身。実際のディスプレイに触れない純粋な計算なので、全パターンをテストできる
public enum Decision {
    /// 画面共有中: 5900番の接続がある、または仮想ディスプレイの識別情報が見える
    public static func sessionActive(portSession: Bool, displays: [DisplaySnapshot]) -> Bool {
        portSession || displays.contains(where: \.isScreenSharingVirtual)
    }

    /// 1. 識別情報で見分ける（学習不要）  2. 予備: 画面共有中かつ学習済みの時、学習済みの物理モニタ以外。
    /// 代わりのディスプレイ（isPlaceholder）は最初から無いものとして扱う（物理とも仮想とも数えない）
    public static func select(displays all: [DisplaySnapshot], learned: Set<String>, portSession: Bool) -> Selection {
        let displays = all.filter { !$0.isPlaceholder }
        let signature = displays.filter(\.isScreenSharingVirtual)
        if !signature.isEmpty { return Selection(source: .signature, candidates: signature) }
        if portSession && !learned.isEmpty {
            return Selection(source: .learned, candidates: displays.filter { !learned.contains($0.uuid) })
        }
        return Selection(source: .none, candidates: [])
    }

    /// 学習すべき物理モニタの ID。学習してはいけない時（画面共有中・何も無い）は nil。
    /// 識別情報の一致するものは、画面共有の検知を見落とした時でも物理として覚えない。代わりのディスプレイも覚えない
    public static func learn(displays: [DisplaySnapshot], portSession: Bool) -> Set<String>? {
        guard !sessionActive(portSession: portSession, displays: displays) else { return nil }
        let ids = Set(displays.filter { !$0.isScreenSharingVirtual && !$0.isPlaceholder }.map(\.uuid))
        return ids.isEmpty ? nil : ids
    }

    /// 学習済みの一覧に今回の物理モニタを加える（置き換えない）。一時的な構成（モニタの電源が切れている等）で
    /// 本物のモニタを忘れると、予備の方式でそれを仮想ディスプレイと取り違えうるため。
    /// 順番は古い→新しい（今回見たものは最後へ移す）。cap 件を超えたら古い方から捨てる
    public static func mergeLearned(previous: [String], current: Set<String>, cap: Int = 16) -> [String] {
        var seen = Set<String>()
        let kept = previous.filter { !current.contains($0) && seen.insert($0).inserted }
        return Array((kept + current.sorted()).suffix(cap))
    }

    /// やるべき変更。不要・不可能なら nil
    public static func action(mode: ScaleMode?, selection: Selection) -> (uuid: String, factor: Int)? {
        guard let factor = mode?.factor, let t = selection.target, t.scaleFactor != factor else { return nil }
        return (t.uuid, factor)
    }
}

/// 短時間に何度も切り替えるのを止める（macOS が戻し続ける場合に、互いに切り替え合って画面が点滅し続けないように）。
/// 時刻は単調な時計の秒（壁時計を戻しても判定が変わらないように。ApplyLimiter・Backoff とも同じ）
public struct ApplyLimiter: Sendable {
    public let maxApplies: Int
    public let window: TimeInterval
    private var stamps: [TimeInterval] = []
    public init(maxApplies: Int, window: TimeInterval) { self.maxApplies = maxApplies; self.window = window }
    public mutating func allow(at now: TimeInterval) -> Bool {
        stamps.removeAll { now - $0 >= window }
        guard stamps.count < maxApplies else { return false }
        stamps.append(now); return true
    }
}

/// 適用に失敗し続ける時の待ち時間。失敗のたびに倍にし（base→…→maxWait）、
/// 失敗した時と状況（設定・仮想ディスプレイの大きさ）が変わっていれば待たない。
/// 設定の変更は利用者の新しい指示、大きさの変更は画面共有の窓の大きさが変わった（選べる倍率が変わりうる）ため。
public struct Backoff: Sendable {
    public let base: TimeInterval
    public let maxWait: TimeInterval
    public private(set) var failures = 0
    private var until: TimeInterval?
    private var failedCondition: String?

    public init(base: TimeInterval = 30, maxWait: TimeInterval = 600) { self.base = base; self.maxWait = maxWait }

    public func shouldWait(condition: String, now: TimeInterval) -> Bool {
        guard let until, condition == failedCondition else { return false }
        return now < until
    }

    /// 失敗を記録し、次に試すまでの秒数を返す
    @discardableResult
    public mutating func failed(condition: String, now: TimeInterval) -> TimeInterval {
        failures = condition == failedCondition ? failures + 1 : 1
        failedCondition = condition
        let wait = min(base * pow(2, Double(failures - 1)), maxWait)
        until = now + wait
        return wait
    }

    public mutating func reset() { failures = 0; until = nil; failedCondition = nil }
}

/// 学習の候補: 画面共有していない時に見えた物理モニタの組と、最初に見た時刻（単調な時計の秒）と、
/// その時の起動時刻（kern.boottime。単調な時計は再起動で 0 に戻るので、別の起動の候補を見分ける）
public struct LearnCandidate: Equatable, Sendable {
    public var ids: Set<String>
    public var since: TimeInterval
    public var boot: Int?
    public init(ids: Set<String>, since: TimeInterval, boot: Int? = nil) { self.ids = ids; self.since = since; self.boot = boot }
}

extension Decision {
    /// 同じ組が minInterval 秒以上続いて見えた時だけ学習する（切断直後に数秒残る仮想ディスプレイを覚えないように）。
    /// 組・起動時刻が変わった、時刻が壊れている（-inf 等）・時計が候補より前なら数え直し、
    /// 学習できない時（画面共有中・何も無い）は候補を捨てる
    public static func stableLearn(observed: Set<String>?, candidate: LearnCandidate?, now: TimeInterval,
                                   minInterval: TimeInterval, boot: Int? = nil) -> (candidate: LearnCandidate?, learn: Set<String>?) {
        guard let observed else { return (nil, nil) }
        guard let c = candidate, c.ids == observed, c.boot == boot, c.since.isFinite, now >= c.since else { return (LearnCandidate(ids: observed, since: now, boot: boot), nil) }
        return (c, now - c.since >= minInterval ? observed : nil)
    }

    /// 回数の上限に当たった時の記録。利用者がもう一度押した結果なら、何かが戻し続けているとは限らない
    public static func limitMessage(retryRequested: Bool) -> String {
        retryRequested ? "too many attempts; try again in a few seconds"
                       : "paused: switched too often (something keeps changing the scale back)"
    }
}

/// 常駐エージェントが少し待ってから行う判定1回分。待つ間に来た通知はまとめる
public struct PendingEvaluation: Equatable, Sendable {
    public var reason: String
    public var portMaxAge: TimeInterval
    public var retryRequested: Bool
    public init(reason: String, portMaxAge: TimeInterval = 0, retryRequested: Bool = false) {
        self.reason = reason; self.portMaxAge = portMaxAge; self.retryRequested = retryRequested
    }
    /// 理由は 設定の変更 > 再試行の依頼 > その他 の順に残す（同じ重さなら新しい方）。
    /// netstat は新しい結果を求める方（短い方）に、再試行の依頼はどちらかにあれば残す
    public func merged(with new: PendingEvaluation) -> PendingEvaluation {
        func rank(_ r: String) -> Int { r.hasPrefix("mode changed") ? 2 : r == "retry requested" ? 1 : 0 }
        return PendingEvaluation(reason: rank(reason) > rank(new.reason) ? reason : new.reason,
                                 portMaxAge: min(portMaxAge, new.portMaxAge),
                                 retryRequested: retryRequested || new.retryRequested)
    }
}
