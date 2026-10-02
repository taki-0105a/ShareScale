import Darwin
import Foundation
import Security
import ShareScaleHostCore

/// バンドルの識別子・版（`CFBundleVersion` の数）・CDHash（`kSecCodeInfoUnique`。小文字の hex）。読めないものは nil
public struct BundleFacts: Equatable, Sendable {
    public var identifier: String?
    public var version: Int?
    public var cdhash: String?
    public init(identifier: String?, version: Int?, cdhash: String?) { self.identifier = identifier; self.version = version; self.cdhash = cdhash }

    /// ディスクの上のバンドルを読む（Info.plist は 1 MiB まで。署名が無ければ `cdhash` は nil）。起動はしない
    public static func read(_ bundle: URL) -> BundleFacts {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        var identifier: String?, version: Int?
        if let data = readSmallFile(plist.path, limit: 1 << 20),
           let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
            identifier = info["CFBundleIdentifier"] as? String
            version = (info["CFBundleVersion"] as? String).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        return BundleFacts(identifier: identifier, version: version, cdhash: CodeSignature.cdhash(bundle))
    }

    /// リンクをたどらずに開き、通常ファイルなら `limit` バイトまで読む
    static func readSmallFile(_ path: String, limit: Int) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= limit else { return nil }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while out.count <= limit {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR { continue }; return nil }
            if n == 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return out.count <= limit ? out : nil
    }
}

/// 署名の読み取りと確かめ（Security.framework。アプリを起動しない）
public enum CodeSignature {
    /// ディスクの上のコードの CDHash（小文字の hex）。署名が無い・読めなければ nil（読む処理は `SelfIdentity.codeHash(of:)` の 1 か所。仮の値は使わない）
    public static func cdhash(_ bundle: URL) -> String? { SelfIdentity.codeHash(at: bundle) }

    /// 複製が壊れていない（複製元と同じ）ことの確かめ（仕様「置き換えの手順」3）。
    /// `SecStaticCodeCheckValidity`（`kSecCSCheckNestedCode | kSecCSStrictValidate`）を、要件
    /// `identifier "<identifier>" and cdhash H"<cdhash>"` に対して行う。出どころは示さない（出どころは `HandoffSafety` で確かめる）
    public static func verify(_ bundle: URL, identifier: String, cdhash: String) -> OSStatus {
        guard identifier.utf8.allSatisfy({ $0 != UInt8(ascii: "\"") && $0 >= 0x20 }), isHex(cdhash) else { return errSecParam }
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(bundle as CFURL, [], &code)
        guard status == errSecSuccess, let code else { return status }
        var requirement: SecRequirement?
        status = SecRequirementCreateWithString("identifier \"\(identifier)\" and cdhash H\"\(cdhash)\"" as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else { return status }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate), requirement)
    }

    static func isHex(_ s: String) -> Bool {
        (2...128).contains(s.utf8.count) && s.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
