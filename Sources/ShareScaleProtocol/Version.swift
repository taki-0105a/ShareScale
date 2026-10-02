import Foundation

/// `VERSION`（x.y.z、各 0〜99）と `CFBundleVersion`（x×10000 + y×100 + z）
public struct AppVersion: Equatable, Comparable, Sendable {
    public let major: Int, minor: Int, patch: Int

    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var nums: [Int] = []
        for p in parts {
            guard (1...2).contains(p.count), p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p),
                  !(p.count == 2 && p.first == "0") else { return nil }
            nums.append(n)
        }
        (major, minor, patch) = (nums[0], nums[1], nums[2])
    }

    public var bundleVersion: Int { major * 10000 + minor * 100 + patch }
    public var shortString: String { "\(major).\(minor).\(patch)" }

    public static func < (a: AppVersion, b: AppVersion) -> Bool { a.bundleVersion < b.bundleVersion }
}
