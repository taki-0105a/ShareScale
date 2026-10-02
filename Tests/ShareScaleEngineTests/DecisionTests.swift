import XCTest
@testable import ShareScaleEngine

// 仮想ディスプレイの見分け・学習・倍率の決定を、判定の中身に対して確かめる
let VIRT = "00000000-0000-0000-0000-00000000000A"
let VIRT2 = "00000000-0000-0000-0000-00000000000C"
let PHYS = "00000000-0000-0000-0000-00000000000B"
let HOT = "00000000-0000-0000-0000-0000000000F0"
let PLACE = "00000000-0000-0000-0000-0000000000E0"

func virtual(_ id: String = VIRT, factor: Int = 2) -> DisplaySnapshot {
    DisplaySnapshot(uuid: id, vendor: 0x6161706c, model: 0x1234, serial: 0x6d767300,
                    width: 1920, height: 997, pixelWidth: 1920 * factor, pixelHeight: 997 * factor)
}
func physical(_ id: String = PHYS) -> DisplaySnapshot {
    DisplaySnapshot(uuid: id, vendor: 0x1e6d, model: 0x5b11, serial: 1,
                    width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160)
}
/// モニタの電源が切れていて画面共有もしていない時に macOS が置く代わりのディスプレイ（実機 2026-09-24:
/// 製造元 "unkn"・製品 "virt"・シリアル 0・1920x1080）。物理モニタでも画面共有の仮想ディスプレイでもない
func placeholder(_ id: String = PLACE) -> DisplaySnapshot {
    DisplaySnapshot(uuid: id, vendor: 0x756e6b6e, model: 0x76697274, serial: 0,
                    width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080)
}
/// 仮想ディスプレイだが、Apple が識別情報を変えた場合を想定したもの（予備の方式でしか見分けられない）
func unknownVirtual(_ id: String = VIRT, factor: Int = 2) -> DisplaySnapshot {
    DisplaySnapshot(uuid: id, vendor: 0x1111, model: 0x2222, serial: 3,
                    width: 1920, height: 997, pixelWidth: 1920 * factor, pixelHeight: 997 * factor)
}

final class SignatureTests: XCTestCase {
    func testRecognizesScreenSharingVirtualDisplay() {
        XCTAssertTrue(virtual().isScreenSharingVirtual)
        XCTAssertFalse(physical().isScreenSharingVirtual)
    }
    func testRecognizesPlaceholder() {
        XCTAssertTrue(placeholder().isPlaceholder)
        XCTAssertFalse(placeholder().isScreenSharingVirtual)
        XCTAssertFalse(physical().isPlaceholder); XCTAssertFalse(virtual().isPlaceholder); XCTAssertFalse(unknownVirtual().isPlaceholder)
    }
    func testScaleFactor() {
        XCTAssertEqual(virtual(factor: 1).scaleFactor, 1)
        XCTAssertEqual(virtual(factor: 2).scaleFactor, 2)
    }
}

final class SelectionTests: XCTestCase {
    func testSignatureWinsWithoutLearning() {                     // 【特徴で判定】未学習でも仮想を特定
        let s = Decision.select(displays: [virtual()], learned: [], portSession: true)
        XCTAssertEqual(s.source, .signature); XCTAssertEqual(s.target?.uuid, VIRT)
    }
    func testHotplugDuringSessionTouchesOnlyVirtual() {           // 【特徴で判定】物理モニタを挿しても仮想だけ
        let s = Decision.select(displays: [virtual(), physical(HOT)], learned: [PHYS], portSession: true)
        XCTAssertEqual(s.target?.uuid, VIRT); XCTAssertFalse(s.ambiguous)
    }
    func testTwoVirtualDisplaysAreAmbiguous() {                   // 【特徴で判定】仮想2枚なら触らない
        let s = Decision.select(displays: [virtual(), virtual(VIRT2)], learned: [], portSession: true)
        XCTAssertTrue(s.ambiguous); XCTAssertNil(s.target)
    }
    func testFallbackUsesLearnedPhysical() {                      // 予備: 学習済み以外で1枚
        let s = Decision.select(displays: [unknownVirtual(), physical()], learned: [PHYS], portSession: true)
        XCTAssertEqual(s.source, .learned); XCTAssertEqual(s.target?.uuid, VIRT)
    }
    func testFallbackHotplugIsAmbiguous() {                       // 【バグ1】予備で正体不明が2枚なら触らない
        let s = Decision.select(displays: [unknownVirtual(), physical(HOT)], learned: [PHYS], portSession: true)
        XCTAssertTrue(s.ambiguous); XCTAssertNil(s.target)
    }
    func testFallbackNeedsLearning() {                            // 未学習なら何もしない
        let s = Decision.select(displays: [unknownVirtual()], learned: [], portSession: true)
        XCTAssertEqual(s.source, .none); XCTAssertNil(s.target)
    }
    // 【実機 2026-09-24】代わりのディスプレイは物理でも仮想でもない。予備の方式でも候補に数えない
    func testPlaceholderIgnoredInFallback() {                     // 正体不明の仮想と一緒でも取り違えない
        let s = Decision.select(displays: [unknownVirtual(), placeholder()], learned: [PHYS], portSession: true)
        XCTAssertEqual(s.target?.uuid, VIRT); XCTAssertFalse(s.ambiguous)
    }
    func testPlaceholderNeverChosenAsTarget() {                   // 代わりのディスプレイしか残らなければ何もしない
        let s = Decision.select(displays: [placeholder(), physical()], learned: [PHYS], portSession: true)
        XCTAssertNil(s.target); XCTAssertFalse(s.ambiguous)
    }
    func testFallbackNeedsPortSession() {
        let s = Decision.select(displays: [unknownVirtual(), physical()], learned: [PHYS], portSession: false)
        XCTAssertEqual(s.source, .none)
    }
}

final class SessionTests: XCTestCase {
    func testSignatureMeansSessionEvenWithoutPort() {             // 【リスク2】
        XCTAssertTrue(Decision.sessionActive(portSession: false, displays: [virtual()]))
    }
    func testPortAloneMeansSession() {
        XCTAssertTrue(Decision.sessionActive(portSession: true, displays: [physical()]))
    }
    func testNoSession() {
        XCTAssertFalse(Decision.sessionActive(portSession: false, displays: [physical()]))
    }
}

final class LearningTests: XCTestCase {
    func testLearnsPhysicalWhenIdle() {                           // 未接続なら物理を学習
        XCTAssertEqual(Decision.learn(displays: [physical()], portSession: false), [PHYS])
    }
    func testNeverLearnsVirtualEvenIfPortMissed() {               // 【リスク1】
        XCTAssertNil(Decision.learn(displays: [virtual()], portSession: false))
    }
    func testDoesNotLearnDuringSession() {
        XCTAssertNil(Decision.learn(displays: [physical()], portSession: true))
    }
    func testHeadlessLearnsNothing() {                            // モニタなし（Mac mini 等）
        XCTAssertNil(Decision.learn(displays: [], portSession: false))
    }
    // 学習は積み上げる（下の mergeLearned）ので、万一の誤学習は上書きされずに残る。ただし誤学習は
    // 同じ構成が 10 秒続いた時だけ学習すること（StableLearningTests）で起きにくくし、その ID が画面共有の
    // 識別情報で見えたら学習済みから外す（ScaleMaintainerTests.testLearnedIDSeenAsVirtualIsForgotten）。
    // 残っても予備の方式でその仮想ディスプレイを候補から外す（何もしない）だけで、物理モニタは触らない。
    // 置き換えだと、代わりのディスプレイ等の一時的な構成で本物のモニタを忘れ、そちらの方が危ない
    func testLingeringUnknownVirtualStaysLearned() {
        XCTAssertEqual(Decision.learn(displays: [unknownVirtual()], portSession: false), [VIRT])
        XCTAssertEqual(Decision.learn(displays: [physical()], portSession: false), [PHYS])
        XCTAssertEqual(Decision.mergeLearned(previous: [VIRT], current: [PHYS]), [VIRT, PHYS])
    }
    // 【実機 2026-09-24】モニタの電源が切れている時の代わりのディスプレイは覚えない
    func testNeverLearnsPlaceholder() {
        XCTAssertNil(Decision.learn(displays: [placeholder()], portSession: false))
        XCTAssertEqual(Decision.learn(displays: [placeholder(), physical()], portSession: false), [PHYS])
    }
    // 学習は前の分との和。新しく見たものは最後（見直したものも最後へ移す）
    func testMergeAccumulatesNewestLast() {
        XCTAssertEqual(Decision.mergeLearned(previous: [], current: [PHYS]), [PHYS])
        XCTAssertEqual(Decision.mergeLearned(previous: [PHYS], current: [PHYS]), [PHYS])
        XCTAssertEqual(Decision.mergeLearned(previous: [PHYS, HOT], current: [PHYS]), [HOT, PHYS])
        XCTAssertEqual(Decision.mergeLearned(previous: [HOT, HOT], current: [PHYS]), [HOT, PHYS], "重複は1つに")
    }
    // 16 件を超えたら古い方から捨てる
    func testMergeCapsAt16() {
        let old = (0..<16).map { String(format: "OLD%02d", $0) }
        let m = Decision.mergeLearned(previous: old, current: [PHYS])
        XCTAssertEqual(m.count, 16); XCTAssertEqual(m.first, "OLD01"); XCTAssertEqual(m.last, PHYS)
    }
}

final class ActionTests: XCTestCase {
    func testAppliesWhenScaleDiffers() {                          // mode=1x・現在 2x なら等倍にする
        let s = Decision.select(displays: [virtual(factor: 2)], learned: [], portSession: true)
        XCTAssertEqual(Decision.action(mode: .x1, selection: s)?.factor, 1)
    }
    func testNothingWhenAlreadyRight() {                          // 既に希望どおりなら何もしない
        let s = Decision.select(displays: [virtual(factor: 2)], learned: [], portSession: true)
        XCTAssertNil(Decision.action(mode: .x2, selection: s))
    }
    func testNothingWhenOff() {                                   // mode=off なら何もしない
        let s = Decision.select(displays: [virtual(factor: 2)], learned: [], portSession: true)
        XCTAssertNil(Decision.action(mode: .off, selection: s))
    }
    func testNothingWhenAmbiguous() {
        let s = Decision.select(displays: [virtual(), virtual(VIRT2)], learned: [], portSession: true)
        XCTAssertNil(Decision.action(mode: .x1, selection: s))
    }
    func testParsesMode() {                                       // 不正なモードは拒否
        XCTAssertEqual(ScaleMode(rawValue: "1x"), .x1)
        XCTAssertNil(ScaleMode(rawValue: "3x"))
    }
}

final class RateLimitTests: XCTestCase {
    // macOS が倍率を戻し続ける場合に、互いに切り替え合って画面が点滅し続けるのを防ぐ
    func testStopsAfterTooManyAppliesInWindow() {
        var limiter = ApplyLimiter(maxApplies: 4, window: 20)
        let t0: TimeInterval = 0   // 単調な時計の秒
        for i in 0..<4 { XCTAssertTrue(limiter.allow(at: t0 + Double(i))) }
        XCTAssertFalse(limiter.allow(at: t0 + 5))
        XCTAssertTrue(limiter.allow(at: t0 + 25), "時間が経てば再開する")
    }
}

// 【誤学習の防止】画面共有していない同じ構成が 10 秒以上続いた時だけ学習する
// （切断直後に数秒残る仮想ディスプレイを物理モニタとして覚えないように）
final class StableLearningTests: XCTestCase {
    let ids: Set<String> = [PHYS]
    let c = LearnCandidate(ids: [PHYS], since: 1000)
    func step(_ o: Set<String>?, _ c: LearnCandidate?, _ t: TimeInterval) -> (candidate: LearnCandidate?, learn: Set<String>?) {
        Decision.stableLearn(observed: o, candidate: c, now: t, minInterval: 10)
    }
    func testSeenOnceIsNotLearned() {
        let r = step(ids, nil, 1000)
        XCTAssertNil(r.learn); XCTAssertEqual(r.candidate, c)
    }
    func testSeenAgainWithin10sIsNotLearned() {
        let r = step(ids, c, 1009.9)
        XCTAssertNil(r.learn); XCTAssertEqual(r.candidate, c, "最初に見た時刻のまま")
    }
    func testSeenAgainAfter10sIsLearned() {
        let r = step(ids, c, 1010)
        XCTAssertEqual(r.learn, ids); XCTAssertEqual(r.candidate, c)
    }
    func testDifferentSetRestarts() {                              // 残っていた仮想ディスプレイが消えたら数え直す
        let r = step([PHYS, VIRT], c, 1020)
        XCTAssertNil(r.learn); XCTAssertEqual(r.candidate, LearnCandidate(ids: [PHYS, VIRT], since: 1020))
    }
    func testSessionClears() {                                     // 画面共有中（学習できない時）は候補を捨てる
        let r = step(nil, c, 1020)
        XCTAssertNil(r.learn); XCTAssertNil(r.candidate)
    }
    func testCorruptedTimeRestarts() {                             // 壊れた時刻（-inf・nan）ですぐ学習しない
        for bad in [-TimeInterval.infinity, .nan] {
            let r = step(ids, LearnCandidate(ids: ids, since: bad), 1000)
            XCTAssertNil(r.learn); XCTAssertEqual(r.candidate, LearnCandidate(ids: ids, since: 1000))
        }
    }
    func testDifferentBootRestarts() {                             // 再起動をまたいだ候補は使わない
        let old = LearnCandidate(ids: ids, since: 1000, boot: 111)
        let r = Decision.stableLearn(observed: ids, candidate: old, now: 5000, minInterval: 10, boot: 222)
        XCTAssertNil(r.learn); XCTAssertEqual(r.candidate, LearnCandidate(ids: ids, since: 5000, boot: 222))
        XCTAssertEqual(Decision.stableLearn(observed: ids, candidate: r.candidate, now: 5010, minInterval: 10, boot: 222).learn, ids)
    }
    func testClockBehindCandidateRestarts() {                      // 再起動で単調な時計が戻った
        let r = step(ids, c, 5)
        XCTAssertNil(r.learn); XCTAssertEqual(r.candidate, LearnCandidate(ids: ids, since: 5))
    }
}

// 常駐エージェントが、待っている判定に後から来た通知をまとめる
final class PendingEvaluationTests: XCTestCase {
    func testModeChangeReasonKeptWhenRetryRequestArrives() {
        let m = PendingEvaluation(reason: "mode changed to 2x")
            .merged(with: PendingEvaluation(reason: "retry requested", retryRequested: true))
        XCTAssertEqual(m.reason, "mode changed to 2x"); XCTAssertTrue(m.retryRequested)
    }
    func testNewerModeChangeWins() {
        let m = PendingEvaluation(reason: "mode changed to 1x").merged(with: PendingEvaluation(reason: "mode changed to 2x"))
        XCTAssertEqual(m.reason, "mode changed to 2x")
    }
    func testRetryKeptOverLaterCheck() {
        let m = PendingEvaluation(reason: "retry requested", retryRequested: true)
            .merged(with: PendingEvaluation(reason: "check", portMaxAge: 10))
        XCTAssertEqual(m.reason, "retry requested"); XCTAssertTrue(m.retryRequested)
        XCTAssertEqual(m.portMaxAge, 0, "netstat は新しい結果を求める方に合わせる")
    }
    func testLaterReasonOtherwise() {
        let m = PendingEvaluation(reason: "check", portMaxAge: 10).merged(with: PendingEvaluation(reason: "display changed"))
        XCTAssertEqual(m.reason, "display changed"); XCTAssertFalse(m.retryRequested)
    }
}

final class LimitMessageTests: XCTestCase {
    // 利用者がもう一度押して上限に当たった時は、「macOS が戻し続けている」とは言わない
    func testRetryRequestGetsAccurateMessage() {
        XCTAssertEqual(Decision.limitMessage(retryRequested: true), "too many attempts; try again in a few seconds")
        XCTAssertEqual(Decision.limitMessage(retryRequested: false), "paused: switched too often (something keeps changing the scale back)")
    }
}
