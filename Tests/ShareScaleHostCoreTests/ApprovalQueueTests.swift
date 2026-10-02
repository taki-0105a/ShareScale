import XCTest
@testable import ShareScaleHostCore
import ShareScaleProtocol

/// 確認の窓の待ち行列（純粋な状態機械。AppKit には触れない）
final class ApprovalQueueTests: XCTestCase {
    func req(_ n: UInt8) -> ApprovalRequest {
        ApprovalRequest(codeID: pid(n), name: "Mac \(n)", confirmationCode: Int(n) * 111, source: "192.168.1.\(n)", sourceClass: .privateV4)
    }

    func testOneAtATimeInArrivalOrder() {
        var q = ApprovalQueue()
        let (a, b, c) = (req(1), req(2), req(3))
        XCTAssertEqual(q.enqueue(a), [.present(a)])
        XCTAssertEqual(q.enqueue(b), []); XCTAssertEqual(q.enqueue(c), [])
        XCTAssertEqual(q.current, a); XCTAssertEqual(q.waiting, [b, c])
        XCTAssertEqual(q.answer(a, true), [.resume(a, true), .close, .present(b)])
        XCTAssertEqual(q.answer(b, false), [.resume(b, false), .close, .present(c)])
        XCTAssertEqual(q.answer(c, true), [.resume(c, true), .close])
        XCTAssertNil(q.current); XCTAssertEqual(q.waiting, [])
    }
    // 点検 A の筋: A を表示中に B が届き、直後に A が取り下げられる → A の答えは false で 1 回、B が出る。遅れて来た A の答えは何もしない
    func testWithdrawOfTheShownRequestWhileAnotherWaits() {
        var q = ApprovalQueue()
        let (a, b) = (req(1), req(2))
        _ = q.enqueue(a); _ = q.enqueue(b)
        XCTAssertEqual(q.withdraw(a), [.resume(a, false), .close, .present(b)])
        XCTAssertEqual(q.current, b)
        XCTAssertEqual(q.answer(a, true), [], "取り下げた後に押された A の答えは使わない（B を閉じない）")
        XCTAssertEqual(q.withdraw(a), [], "二重の取り下げも何もしない")
        XCTAssertEqual(q.answer(b, true), [.resume(b, true), .close])
    }
    func testWithdrawOfAWaitingRequestResumesFalseWithoutTouchingTheWindow() {
        var q = ApprovalQueue()
        let (a, b, c) = (req(1), req(2), req(3))
        _ = q.enqueue(a); _ = q.enqueue(b); _ = q.enqueue(c)
        XCTAssertEqual(q.withdraw(b), [.resume(b, false)])
        XCTAssertEqual(q.current, a); XCTAssertEqual(q.waiting, [c])
        XCTAssertEqual(q.answer(a, false), [.resume(a, false), .close, .present(c)])
    }
    func testAnswersAreResumedExactlyOnce() {
        var q = ApprovalQueue()
        let a = req(1)
        _ = q.enqueue(a)
        XCTAssertEqual(q.answer(a, true), [.resume(a, true), .close])
        XCTAssertEqual(q.answer(a, true), [], "二重の答え")
        XCTAssertEqual(q.answer(a, false), [])
        XCTAssertEqual(q.withdraw(a), [], "答えた後の取り下げ")
        XCTAssertEqual(q.cancelledEarly, [], "答えた後の取り下げは「先に取り消された」と取り違えない")
        XCTAssertEqual(q.recentlyFinished, [a])
        XCTAssertEqual(q.answer(req(9), true), [], "知らないもの")
        XCTAssertEqual(q.withdraw(req(9)), [])
    }
    // 取り消しが登録より先に届いた: 覚えておき、登録の時に出さずに false。覚えるのは 64 件まで（古いものから捨てる）
    func testCancellationBeforeEnqueueIsRememberedUpTo64() {
        var q = ApprovalQueue()
        let a = req(1)
        XCTAssertEqual(q.withdraw(a), [])
        XCTAssertEqual(q.cancelledEarly, [a])
        XCTAssertEqual(q.enqueue(a), [.resume(a, false)], "出さずに false")
        XCTAssertNil(q.current); XCTAssertEqual(q.cancelledEarly, [])
        for n in 1...65 { _ = q.withdraw(req(UInt8(n))) }
        XCTAssertEqual(q.cancelledEarly.count, ApprovalQueue.maxCancelledEarly)
        XCTAssertEqual(q.enqueue(req(1)), [.present(req(1))], "上限を超えて捨てられたものはふつうに出る")
        XCTAssertEqual(q.enqueue(req(65)), [.resume(req(65), false)])
    }
    func testAnswerForAWaitingRequestIsIgnored() {
        var q = ApprovalQueue()
        let (a, b) = (req(1), req(2))
        _ = q.enqueue(a); _ = q.enqueue(b)
        XCTAssertEqual(q.answer(b, true), [], "待ち行列の中のものは窓に出ていないので答えられない")
        XCTAssertEqual(q.waiting, [b])
    }
}
