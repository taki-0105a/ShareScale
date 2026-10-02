import Foundation

/// ShareScale.app と ShareScale Host.app のバンドル識別子（1 か所にまとめる。見る側の `AppIdentifiers`・`SystemChecks`・`SystemSettingsLink` はここを参照する。点検 2f-1）
public enum BundleIdentifiers {
    public static let app = "io.github.taki-0105a.ShareScale"
    public static let host = "io.github.taki-0105a.ShareScale.Host"
}
