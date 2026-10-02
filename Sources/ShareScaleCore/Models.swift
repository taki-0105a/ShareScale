import Foundation
import ShareScaleProtocol

/// 仮想ディスプレイの描画倍率。1x=等倍、2x=Retina（通信の `Mode` と 1 対 1）
public enum DisplayMode: String, Equatable, Sendable {
    case x1 = "1x"
    case x2 = "2x"
    case off = "off"

    /// 見る側ディスプレイの倍率から、合わせるべきモードを決める。
    /// 1.0 を超えるものはすべて Retina 扱い。
    public static func recommended(forBackingScale scale: Double) -> DisplayMode {
        scale > 1.0 ? .x2 : .x1
    }

    public var label: String {
        switch self {
        case .x1: return tr("等倍 (1x)", "Standard (1x)")
        case .x2: return "Retina (2x)"
        case .off: return tr("自動調整しない", "Don’t adjust")   // DataSaving.optionLabel と同じ言葉（「自動維持」は画面に出さない）
        }
    }

    /// 通信の `Mode`（`set` の `mode`）
    public var wire: Mode {
        switch self { case .x1: return .oneX; case .x2: return .twoX; case .off: return .off }
    }
    public init(_ mode: Mode) {
        switch mode { case .oneX: self = .x1; case .twoX: self = .x2; case .off: self = .off }
    }
}

public struct Resolution: Equatable, Sendable, CustomStringConvertible {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// "1920x997" 形式を読む。
    public init?(string: String) {
        let parts = string.split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
        self.init(width: w, height: h)
    }

    /// 論理サイズからそのモードでの実画素数を求める。
    public func framebuffer(for mode: DisplayMode) -> Resolution {
        mode == .x2 ? Resolution(width: width * 2, height: height * 2) : self
    }

    public var description: String { "\(width)×\(height)" }
}

public struct VirtualDisplay: Equatable, Sendable {
    public let logical: Resolution
    public let scaling: DisplayMode
    /// 見分け方（`signature`＝識別情報、`learned`＝予備の方法）
    public let source: String
    public init(logical: Resolution, scaling: DisplayMode, source: String) { self.logical = logical; self.scaling = scaling; self.source = source }
}

/// 接続先の状態（`status`・`set` の応答 `StatusPayload` から作る）。
/// Host から来た文字列（名前・機種・直近の失敗）は Cc・Cf・Zl・Zp を除いてから持つ（画面は `Text(verbatim:)` で出す）
public struct RemoteState: Equatable, Sendable {
    public var sessionActive = false
    public var mode: DisplayMode?
    public var virtualDisplay: VirtualDisplay?
    /// 正体不明のディスプレイが2枚以上あり、仮想ディスプレイを特定できない
    public var virtualAmbiguous = false
    /// 相手の Mac のコンピュータ名
    public var computerName: String?
    /// 接続先の機種名（Mac Studio / Mac mini / MacBook Pro …）
    public var model: String?
    /// 接続先で最後に起きた切り替えの失敗（生の内容。画面の本文には出さない）
    public var lastError: String?
    /// Host のメニューの「一時停止」中（`set` は断られる）
    public var paused = false
    /// 最後に倍率を設定したのがほかの見る側（自分なら false。誰も設定していなければ nil）
    public var setByOther: Bool?
    /// 最後に倍率を設定した時刻（UNIX 秒）
    public var setAt: Int64?
    /// Host の今の候補アドレスと通信口（照合済みの応答に入っていたもの。候補の更新に使う）
    public var port: Int?
    public var addresses: [String] = []

    public init() {}

    public init(_ p: StatusPayload) {
        func text(_ s: String) -> String? { let t = TextRules.stripControls(s); return t.isEmpty ? nil : t }
        sessionActive = p.session
        mode = DisplayMode(p.mode)
        virtualDisplay = p.virtualDisplay.flatMap { vd in
            Resolution(string: vd.resolution).map { VirtualDisplay(logical: $0, scaling: vd.scaling == .twoX ? .x2 : .x1, source: vd.source.rawValue) }
        }
        virtualAmbiguous = p.ambiguous
        computerName = text(p.name)
        model = text(p.model)
        lastError = p.lastError.flatMap(text)
        paused = p.paused
        setByOther = p.setBy.map { !$0.byYou }
        setAt = p.setBy?.at
        port = p.port
        addresses = p.addresses
    }
}

/// 接続先への問い合わせの失敗の分類（仕様「見る側」の案内の区別に使う）
public enum ViewerFailure: Error, Equatable, Sendable {
    case unreachable                // どの候補にもつながらない（接続先が落ちている・別のネットワーク・Host が待ち受けていない）
    case localNetworkDenied         // ローカルネットワークの許可が無い（macOS 15 以降。`.waiting` で経路の理由が localNetworkDenied）
    /// TLS の手続きが成立しない（秘密が一致しない＝接続先で解除された、または同じアドレスに別の機器が応答している。消さずに案内する）。
    /// `othersUnreachable` は、届かない候補も混ざっていたか
    case handshakeFailed(othersUnreachable: Bool)
    case notPaired                  // Host が `not_paired` を返した（解除された・一致しない。消さずに案内する）
    case unsupportedVersion         // 接続先の版が古い（`unsupported_version`）
    case paused                     // `set` が断られた（Host が一時停止中）
    case busy                       // `set` が断られた（前の反映がまだ終わっていない）／Host が候補アドレスを作れない
    case timedOut                   // 候補の試行全体の上限、または応答が来ない
    case cancelled                  // 呼び出し側の Task が取り消された（案内は出さない。画面の状態も変えない）
    case other(String)              // 想定外（応答の形が違う・書き出せない指示など。生の内容は本文に出さない）

    /// Host が照合済みの応答で断った（`set` への「一時停止中」、`set`・`status` への「処理中」。`status` も、Host が候補アドレスを作れない時は
    /// 「処理中」で断られる）。Host には届いていて、ペアリングも通っている＝接続できない失敗ではない。
    /// 接続の状態（バッジ・メニューの 1 行）・見出し・カード・診断の「接続」「ペアリング」は、接続できている扱いのままにする
    /// （計画 2i。実機確認 B: 一時停止の間にカードを押すと、案内は正しいのにバッジが「接続できません」になった）
    public var isRefusal: Bool { self == .paused || self == .busy }
}
