import Foundation

/// 見ている側のディスプレイ。AppKit から切り離してテストできる形にしてある
public struct LocalDisplay: Identifiable, Equatable, Sendable {
    public let id: UInt32
    public let name: String
    public let pixels: Resolution
    public let backingScale: Double
    public let isBuiltIn: Bool
    /// ディスプレイの永続 ID（抜き差ししても変わらない）。選んだ倍率を覚えるのに使う
    public let uuid: String?

    public init(id: UInt32, name: String, pixels: Resolution, backingScale: Double, isBuiltIn: Bool, uuid: String? = nil) {
        self.id = id; self.name = name; self.pixels = pixels
        self.backingScale = backingScale; self.isBuiltIn = isBuiltIn; self.uuid = uuid
    }

    /// 設定を覚えるための鍵。永続 ID が無ければ名前と種類で代用する
    public var preferenceKey: String { uuid ?? "\(name)|\(isBuiltIn ? "builtin" : "external")" }

    public var recommended: DisplayMode { DisplayMode.recommended(forBackingScale: backingScale) }
    public var panelLabel: String { backingScale > 1.0 ? "Retina" : tr("等倍パネル", "Standard") }
    public var symbol: String { isBuiltIn ? "laptopcomputer" : "display" }
}

/// 接続先の Mac との通信。本物は `TargetSession`（`Connector` で候補を試す）、テストでは偽物を差し込む
public protocol TargetControlling: Sendable {
    func status() async -> Result<RemoteState, ViewerFailure>
    func set(_ mode: DisplayMode) async -> Result<RemoteState, ViewerFailure>
}
