import Foundation

/// 文字列を読み書きできる保存先。本番は UserDefaults、テストはメモリ上の偽物（ファイルを作らない）
public protocol StringStore: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: Any?, forKey key: String)
}
extension UserDefaults: StringStore {}

/// 見る側のディスプレイごとに選んだ倍率を覚える
public struct DisplayPreferences {
    private let store: StringStore
    public init(store: StringStore) { self.store = store }

    public func mode(for d: LocalDisplay) -> DisplayMode? {
        store.string(forKey: "scale." + d.preferenceKey).flatMap(DisplayMode.init(rawValue:)).flatMap { $0 == .off ? nil : $0 }
    }
    public func setMode(_ m: DisplayMode, for d: LocalDisplay) { store.set(m.rawValue, forKey: "scale." + d.preferenceKey) }
}

/// メモリ上の保存先（既定値。本番はアプリが UserDefaults を渡す）
public final class InMemoryStringStore: StringStore {
    private var values: [String: String] = [:]
    public init() {}
    public func string(forKey key: String) -> String? { values[key] }
    public func set(_ value: Any?, forKey key: String) { values[key] = value as? String }
}
