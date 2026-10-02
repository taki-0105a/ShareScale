import Darwin
import Foundation

/// アプリの中の ShareScale Host（`Contents/Library/LoginItems/ShareScale Host.app`）があるか。
/// macOS 27 の `SMAppService.loginItem(identifier:).status` は、**一度も登録していないログイン項目にも `.notFound` を返す**（2026-09-30 実機で確認）ため、
/// 「中に Host が無い」は `SMAppService` の状態ではなく、バンドルの中を見て判断する（計画 2f-1）。
/// 途中のフォルダ・Host.app・Host.app/Contents が本物のフォルダ（リンクでない。`lstat`）で、`Contents/Info.plist`（リンクをたどらずに読む）の
/// `CFBundleIdentifier` が Host の識別子の時だけ「ある」。識別子だけを読み、署名（CDHash）は計算しない。起動はしない
public enum EmbeddedHost {
    public static let relativePath = "Contents/Library/LoginItems/ShareScale Host.app"

    public static func isPresent(in appBundle: URL) -> Bool {
        var path = appBundle.path
        for component in (relativePath + "/Contents").split(separator: "/") {
            path += "/" + component
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        }
        return bundleIdentifier(plist: path + "/Info.plist") == AppIdentifiers.host
    }

    /// `Info.plist` の `CFBundleIdentifier`（1 MiB まで。読めなければ nil）
    static func bundleIdentifier(plist path: String) -> String? {
        guard let data = BundleFacts.readSmallFile(path, limit: 1 << 20),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        return info["CFBundleIdentifier"] as? String
    }
}
