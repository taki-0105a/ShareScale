import Foundation
import ShareScaleProtocol

/// Host の設定（`~/Library/Preferences/io.github.taki-0105a.ShareScale.Host.plist`。仕様「置き場所と識別子」）。
/// 「Tailscale 経由だけ」「インターネットからも受け付ける」「通信口」「メニューバーの知らせを出したか」。読み書きの形は辞書で、`UserDefaults` との出し入れは実行体が行う
/// （試験は辞書だけを扱い、利用者の環境設定には書かない）
public struct HostPreferences: Equatable, Sendable {
    public static let suite = BundleIdentifiers.host
    public static let keys = (tailscaleOnly: "tailscaleOnly", allowGlobal: "allowGlobal", port: "port", menuBarNoticeShown: "menuBarNoticeShown")
    public var tailscaleOnly = false
    public var allowGlobal = false
    public var port = Limits.defaultPort
    /// 初回の起動で「メニューバーで動いています」の知らせを出した（実機確認 2026-09-30: 記号が切り欠きに隠れて見つからない）。
    /// 出したら真にして保存し、次からは出さない
    public var menuBarNoticeShown = false
    public init() {}

    /// 辞書から（型が違う・範囲の外の値は既定値）
    public init(dictionary d: [String: Any]) {
        if let b = d[Self.keys.tailscaleOnly] as? Bool { tailscaleOnly = b }
        if let b = d[Self.keys.allowGlobal] as? Bool { allowGlobal = b }
        if let n = d[Self.keys.port] as? Int, Limits.portRange.contains(n) { port = n }
        if let b = d[Self.keys.menuBarNoticeShown] as? Bool { menuBarNoticeShown = b }
    }
    public var dictionary: [String: Any] {
        [Self.keys.tailscaleOnly: tailscaleOnly, Self.keys.allowGlobal: allowGlobal, Self.keys.port: port, Self.keys.menuBarNoticeShown: menuBarNoticeShown]
    }
    /// Host の環境設定の置き場所。実行体の識別子が `suite` そのもの（`ShareScale Host.app` として動いている）なら `.standard`
    /// （自分の識別子を `UserDefaults(suiteName:)` に渡すのは不正で、`.standard` と同じ域を指す）。それ以外（`swift build` の実行体・試験）は suite
    public static func defaults() -> UserDefaults {
        if Bundle.main.bundleIdentifier == suite { return .standard }
        return UserDefaults(suiteName: suite) ?? .standard
    }
    /// 自分の域の値だけを読む（`dictionaryRepresentation()` はグローバルの域も含むので使わない）
    public static func load(from defaults: UserDefaults) -> HostPreferences {
        var d: [String: Any] = [:]
        for k in [keys.tailscaleOnly, keys.allowGlobal, keys.port, keys.menuBarNoticeShown] { if let v = defaults.object(forKey: k) { d[k] = v } }
        return HostPreferences(dictionary: d)
    }
    public func save(to defaults: UserDefaults) {
        for (k, v) in dictionary { defaults.set(v, forKey: k) }
    }
}
