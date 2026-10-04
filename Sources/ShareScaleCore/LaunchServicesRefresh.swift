import CoreServices
import Foundation

/// 置き換えた後のバンドルの中身で、LaunchServices の登録を更新させる（公開の API `LSRegisterURL(url, true)`。計画 2j）。
/// 更新の後のログイン項目の登録し直しの前に呼ぶ。簡易署名の Host は、launchd の起動の条件（LWCR）が Host の指紋（cdhash）で固定され、
/// 登録し直した後の 1 回目の起動が止められる（2026-10-02〜04 実機。macOS が古い指紋を覚えているから、というのは推測。仕様「ログイン項目の登録」）。
/// LaunchServices を新しい中身で更新させれば止められなくなるかは、**未確認**（実機で、次の更新の時に確かめる）。
/// 害が無いように: 裏のスレッドで呼び、`limit`（既定 `timeout`＝2 秒）で待つのをやめ、見切った後は残りを始めない
/// （止まった呼び出しのスレッドは、戻るまで残る）。失敗しても投げず、結果を返すだけ（登録し直しは、結果に依らず続ける）
public enum LaunchServicesRefresh {
    /// 待つ上限（秒）。ふつうは 1 つの URL につき数十ミリ秒（実機の値は実機確認で見る）
    public static let timeout = 2.0

    /// 各 URL を順に更新する（大事なものを先に渡す）。結果は URL の順（`noErr` = 0。待ちきれなかったもの・始めなかったものは nil）。
    /// 上限で見切った後は、残りの URL の呼び出しを新しく始めない（後に続く解除・登録と重ねない。点検 2j-B）。
    /// 止まった呼び出しのスレッドは、戻るまで残る（1 回の更新で 1 本）。`call` は試験で差し替える（実物の LaunchServices に触れない）
    public static func run(_ urls: [URL], limit: Double = timeout,
                           call: @escaping @Sendable (URL) -> Int32 = { LSRegisterURL($0 as CFURL, true) }) async -> [Int32?] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[Int32?], Never>) in
            let box = ResultBox(count: urls.count, continuation: continuation)
            DispatchQueue.global(qos: .utility).async {
                for (i, url) in urls.enumerated() {
                    if box.isFinished { break }
                    box.set(i, call(url))
                }
                box.finish()
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limit) { box.finish() }
        }
    }

    /// 結果を集め、1 回だけ返す（先に終わった方: すべて呼び終えた時か、上限の時）
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Int32?]
        private var continuation: CheckedContinuation<[Int32?], Never>?
        init(count: Int, continuation: CheckedContinuation<[Int32?], Never>) {
            results = Array(repeating: nil, count: count); self.continuation = continuation
        }
        func set(_ i: Int, _ r: Int32) { lock.withLock { if continuation != nil { results[i] = r } } }
        /// 返し終えたか（上限で見切った後も含む）
        var isFinished: Bool { lock.withLock { continuation == nil } }
        func finish() {
            let pending: (CheckedContinuation<[Int32?], Never>, [Int32?])? = lock.withLock {
                guard let c = continuation else { return nil }
                continuation = nil
                return (c, results)
            }
            if let (c, r) = pending { c.resume(returning: r) }
        }
    }
}
