import Foundation
import Security
import ShareScaleEngine

/// 実行体の引数（仕様「入れ替えの途中で動き続ける旧版の Host」）。**この形は以後の版で変えない**（旧版の Host が新版の子を起動するため）:
/// - 引数なし: 常駐
/// - `--apply-once <uuid> <factor> --version <n> --cdhash <hex>`: 倍率を 1 回変えて終わる子
/// - `--probe --version <n> --cdhash <hex>`: ディスプレイの一覧を書き出して終わる子
/// 版か CDHash が自分と違えば、子は何もせずに `ChildProcessDisplayProvider.updatingExitCode`（75）で終わる
public enum ChildArguments {
    public enum Invocation: Equatable, Sendable {
        case resident
        case probe(version: Int, cdhash: String)
        case applyOnce(uuid: String, factor: Int, version: Int, cdhash: String)
    }
    /// 引数の形が違う時の終了コード（sysexits の EX_USAGE）
    public static let usageExitCode: Int32 = 64

    public static func probe(version: Int, cdhash: String) -> [String] { ["--probe", "--version", String(version), "--cdhash", cdhash] }
    public static func applyOnce(uuid: String, factor: Int, version: Int, cdhash: String) -> [String] {
        ["--apply-once", uuid, String(factor), "--version", String(version), "--cdhash", cdhash]
    }
    /// 実行体の子の起動の仕方（`ChildProcessDisplayProvider` に渡す）。環境は最小限（PATH も渡さない。子は絶対パスの自分だけを動かす）
    public static func command(executable: URL, version: Int, cdhash: String) -> ChildCommand {
        ChildCommand(executable: executable, probeArguments: probe(version: version, cdhash: cdhash),
                     applyArguments: { u, f in applyOnce(uuid: u, factor: f, version: version, cdhash: cdhash) },
                     environment: ["LANG": "C"])
    }

    /// `CommandLine.arguments.dropFirst()` を読む。自分の引数は `--` で始まる。最初の `--` より前にある、`-` で始まる引数
    /// （Finder・LaunchServices・AppKit が付ける `-psn_…`、`-NSDocumentRevisionsDebugMode YES`・`-AppleLanguages (ja)` のような `-Key value`）は無視する
    /// （`-psn_…` は単独、ほかの `-Key` は `-` で始まらない値が続けばそれも飛ばす）。裸の語（`status` など）は形の誤り。
    /// `--` の引数が無ければ常駐。形が違えば nil（実行体は使い方を出して 64 で終わる）
    public static func parse(_ arguments: [String]) -> Invocation? {
        var args: [String] = []
        var i = 0
        while i < arguments.count {
            let a = arguments[i]
            if a.hasPrefix("--") { args = Array(arguments[i...]); break }
            guard a.hasPrefix("-") else { return nil }
            if !a.hasPrefix("-psn_"), i + 1 < arguments.count, !arguments[i + 1].hasPrefix("-") { i += 1 }
            i += 1
        }
        if args.isEmpty { return .resident }
        func tail(_ rest: ArraySlice<String>) -> (Int, String)? {
            guard rest.count == 4, rest[rest.startIndex] == "--version", rest[rest.startIndex + 2] == "--cdhash",
                  let v = Int(rest[rest.startIndex + 1]), v >= 0, isHex(rest[rest.startIndex + 3]) else { return nil }
            return (v, rest[rest.startIndex + 3])
        }
        switch args[0] {
        case "--probe":
            guard let (v, h) = tail(args.dropFirst()) else { return nil }
            return .probe(version: v, cdhash: h)
        case "--apply-once":
            guard args.count >= 3, let f = Int(args[2]), (1...4).contains(f), !args[1].isEmpty, args[1].utf8.count <= 64,
                  let (v, h) = tail(args.dropFirst(3)) else { return nil }
            return .applyOnce(uuid: args[1], factor: f, version: v, cdhash: h)
        default:
            return nil
        }
    }
    /// 版と CDHash が自分と同じか（違えば 75 で終わる）
    public static func matchesSelf(version: Int, cdhash: String, own: SelfIdentity) -> Bool {
        version == own.version && cdhash.lowercased() == own.cdhash.lowercased()
    }
    static func isHex(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 128 && s.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) || (0x41...0x46).contains($0) }
    }
    public static let usage = """
    usage: ShareScaleHost                                   (resident; menu bar)
           ShareScaleHost --probe --version <n> --cdhash <hex>
           ShareScaleHost --apply-once <uuid> <factor> --version <n> --cdhash <hex>
    """
}

/// 自分の版（`CFBundleVersion`）と CDHash（`SecCodeCopySelf` の `kSecCodeInfoUnique`）。
/// バンドルの外で動かした時（`swift build` の実行体）は版 0、CDHash が読めなければ "0"（親も子も同じ値になるので照合は通る）
public struct SelfIdentity: Equatable, Sendable {
    public var version: Int
    public var cdhash: String
    public init(version: Int, cdhash: String) { self.version = version; self.cdhash = cdhash }

    /// 子の引数に渡す自分（CDHash が読めなければ "0"。これは子の引数の形の決まりで、`app-state.json` などの記録には書かない。計画 2e-1）
    public static func current() -> SelfIdentity {
        SelfIdentity(version: bundleVersion() ?? 0, cdhash: codeHash() ?? "0")
    }
    /// `Info.plist` の `CFBundleVersion`（数。無ければ nil）
    public static func bundleVersion(_ info: [String: Any]? = Bundle.main.infoDictionary) -> Int? {
        guard let s = info?["CFBundleVersion"] as? String else { return nil }
        return Int(s.trimmingCharacters(in: .whitespaces))
    }
    /// 自分のコードの CDHash（小文字の hex）。署名が無ければ nil
    public static func codeHash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return codeHash(of: staticCode)
    }
    /// ディスクの上のコード（バンドル）の CDHash（小文字の hex）。署名が無い・読めなければ nil（計画 2e-1。ShareScaleCore の `CodeSignature` も使う）
    public static func codeHash(at url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return codeHash(of: staticCode)
    }
    /// CDHash を読む処理の 1 か所（`kSecCodeInfoUnique`）
    static func codeHash(of staticCode: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let d = info as? [String: Any], let h = d[kSecCodeInfoUnique as String] as? Data, !h.isEmpty else { return nil }
        return h.map { String(format: "%02x", $0) }.joined()
    }
}
