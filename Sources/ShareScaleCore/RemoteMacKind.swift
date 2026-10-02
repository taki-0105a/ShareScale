import Foundation

/// 接続先の機種。見出しのアイコンを機種に合わせるために使う（接続先は Mac Studio とは限らない）
public struct RemoteMacKind: Equatable, Sendable {
    public let symbol: String

    public init(model: String?) {
        let m = (model ?? "").lowercased()
        if m.contains("mac studio") { symbol = "macstudio" }
        else if m.contains("mac mini") { symbol = "macmini" }
        else if m.contains("macbook") { symbol = "laptopcomputer" }
        else if m.contains("mac pro") { symbol = "macpro.gen3" }
        else { symbol = "desktopcomputer" }   // iMac・不明な機種
    }
}
