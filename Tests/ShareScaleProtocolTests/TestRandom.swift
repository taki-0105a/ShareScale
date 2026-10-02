/// 試験用の決まった乱数（線形合同法）。標準ライブラリの `Int.random(in:using:)` などは版で結果が変わりうるので使わない
struct TestLCG {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
    /// 0..<n（上位のビットを使う。下位のビットは周期が短いため）
    mutating func below(_ n: Int) -> Int {
        precondition(n > 0)
        return Int((next() >> 33) % UInt64(n))
    }
    mutating func inRange(_ r: ClosedRange<Int>) -> Int { r.lowerBound + below(r.count) }
    mutating func bool() -> Bool { next() >> 63 == 1 }
    mutating func pick<T>(_ items: [T]) -> T { items[below(items.count)] }
    mutating func bytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in UInt8(truncatingIfNeeded: next() >> 56) } }
}
