import CoreServices
import Foundation
import ServiceManagement

/// 診断の行・案内から直接開くシステム設定の場所（計画 2f-1 案 5）。✗ と ? の行の右に「〜の設定を開く…」のボタンを出す
public enum DiagnosticAction: String, Equatable, Hashable, Sendable, CaseIterable {
    case openLocalNetworkSettings
    case openFirewallSettings
    case openLoginItemsSettings
    case openFileVaultSettings
    case openNotificationSettings

    /// ボタンの文言（ウインドウが開くので「…」を付ける。DESIGN.md「ShareScale Host の窓」のメニューと同じ流儀）
    public func title(_ L: HostLanguage) -> String {
        switch self {
        case .openLocalNetworkSettings: return L.t("ローカルネットワークの設定を開く…", "Open Local Network Settings…")
        case .openFirewallSettings: return L.t("ファイアウォールの設定を開く…", "Open Firewall Settings…")
        case .openLoginItemsSettings: return L.t("ログイン項目を開く…", "Open Login Items…")
        case .openFileVaultSettings: return L.t("FileVault の設定を開く…", "Open FileVault Settings…")
        case .openNotificationSettings: return L.t("通知の設定を開く…", "Open Notification Settings…")
        }
    }
}

/// システム設定を開く口（試験では差し替える。実物は `SystemSettingsLink.live`）
public protocol SystemSettingsOpening: Sendable {
    /// URL を開く（開けなければ false）
    func open(_ url: URL) -> Bool
    /// システム設定 › 一般 › ログイン項目（`SMAppService.openSystemSettingsLoginItems()`）
    func openLoginItems()
}

/// システム設定の URL の表（1 か所にまとめる）。候補を順に試し、どれも開けなければシステム設定そのものを開く。
///
/// 出典と確かさ（2026-09-30。ネットを引かずにこの Mac（macOS 27.0.1）のローカルの資料で調べた）:
/// - 拡張の識別子（`com.apple.settings.PrivacySecurity.extension`・`com.apple.Network-Settings.extension`・`com.apple.LoginItems-Settings.extension`・
///   `com.apple.Notifications-Settings.extension`）と、それぞれが `x-apple.systempreferences:` を受け付けること
///   （`SettingsExtensionAttributes.allowsXAppleSystemPreferencesURLScheme = true`）、旧い識別子（`legacyBundleIdentifier`:
///   `com.apple.preference.security`・`com.apple.preference.network`・`com.apple.preference.notifications`）は、
///   `/System/Library/ExtensionKit/Extensions/<名前>.appex/Contents/Info.plist` で確かめた（一次資料）。macOS 13 以降のシステム設定は同じ形
/// - ログイン項目: `SMAppService.openSystemSettingsLoginItems()`（Apple の SDK の `SMAppService.h`。macOS 13 以降）。URL は使わない
/// - 区画の名前（`?` の後）: `Privacy_LocalNetwork`・`FileVault`・`Firewall`・`id=<バンドル識別子>` は Apple の文書に無く、**未確認**。
///   拡張の実行ファイルの文字列に `FileVault`・`Privacy_*` の形の名前はあるが、`Privacy_LocalNetwork`・`Firewall` そのものは見つからなかった。
///   区画の名前が違っても設定の画面（ペイン）は開く。正しい区画が開くかは利用者が実機で確かめる（計画 2f-1「利用者が実機で確かめること」）
/// - `open` は、システム設定が URL を受け取れば区画の名前が合わなくても true を返す。候補の 2 つ目以降は、1 つ目を受け付けない版のための予備
public enum SystemSettingsLink {
    static let scheme = "x-apple.systempreferences:"
    public static let appBundleIdentifier = BundleIdentifiers.app
    /// どれも開けない時に開くシステム設定そのもの
    public static let settingsApp = URL(fileURLWithPath: "/System/Applications/System Settings.app")

    /// 試す順の URL（ログイン項目は `SMAppService` を先に使うので、ここは予備だけ）
    public static func candidates(_ a: DiagnosticAction) -> [URL] {
        let s: [String]
        switch a {
        case .openLocalNetworkSettings:
            s = ["com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork",
                 "com.apple.preference.security?Privacy_LocalNetwork",
                 "com.apple.settings.PrivacySecurity.extension"]
        case .openFirewallSettings:
            s = ["com.apple.Network-Settings.extension?Firewall",
                 "com.apple.preference.security?Firewall",
                 "com.apple.Network-Settings.extension"]
        case .openLoginItemsSettings:
            // 未使用（`open` はログイン項目を `SMAppService.openSystemSettingsLoginItems()` で開く）。表をすべての操作で埋めておくための記録
            s = ["com.apple.LoginItems-Settings.extension"]
        case .openFileVaultSettings:
            s = ["com.apple.settings.PrivacySecurity.extension?FileVault",
                 "com.apple.preference.security?FDE",
                 "com.apple.settings.PrivacySecurity.extension"]
        case .openNotificationSettings:
            s = ["com.apple.Notifications-Settings.extension?id=\(appBundleIdentifier)",
                 "com.apple.preference.notifications?id=\(appBundleIdentifier)",
                 "com.apple.Notifications-Settings.extension"]
        }
        return s.compactMap { URL(string: scheme + $0) }
    }

    /// 開く。ログイン項目は `openLoginItems`、ほかは候補を順に試し、どれも開けなければシステム設定そのもの。開いたものを返す（試験用）
    @discardableResult
    public static func open(_ a: DiagnosticAction, using opener: SystemSettingsOpening) -> URL? {
        if a == .openLoginItemsSettings { opener.openLoginItems(); return nil }
        for u in candidates(a) where opener.open(u) { return u }
        return opener.open(settingsApp) ? settingsApp : nil
    }

    /// 実物（LaunchServices と `SMAppService`。AppKit を使わない）
    public static let live: SystemSettingsOpening = LiveOpener()

    struct LiveOpener: SystemSettingsOpening {
        func open(_ url: URL) -> Bool { LSOpenCFURLRef(url as CFURL, nil) == noErr }
        func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
    }
}
