import XCTest
@testable import ShareScaleHostCore
import ShareScaleNet
import ShareScaleProtocol

final class HostMetaTests: XCTestCase {
    func testRoundTripAndShape() {
        let m = HostMeta(name: "MacBook Air", created: 100, lastSeen: 200, confirmed: true, noticeSnoozedUntil: 300)
        XCTAssertEqual(HostMeta.decode(m.encoded()), m)
        let text = String(decoding: HostMeta(name: "A", created: 1, confirmed: false).encoded(), as: UTF8.self)
        XCTAssertEqual(text, #"{"format":1,"name":"A","created":1,"last_seen":null,"confirmed":false,"notice_snoozed_until":null}"# + "\n")
    }
    // 時刻は 0...2^40 だけ読む（極端な値・壊れた値で引き算があふれないように）
    func testTimesOutOfRangeAreRejected() {
        func meta(created: String = "1", lastSeen: String = "null", snoozed: String = "null") -> Data {
            Data(#"{"format":1,"name":"A","created":\#(created),"last_seen":\#(lastSeen),"confirmed":true,"notice_snoozed_until":\#(snoozed)}"#.utf8)
        }
        XCTAssertNotNil(HostMeta.decode(meta(created: "0", lastSeen: "\(Int64(1) << 40)")))
        XCTAssertNil(HostMeta.decode(meta(created: "-1")))
        XCTAssertNil(HostMeta.decode(meta(created: "\((Int64(1) << 40) + 1)")))
        XCTAssertNil(HostMeta.decode(meta(lastSeen: "\(Int64.min)")))
        XCTAssertNil(HostMeta.decode(meta(snoozed: "\(Int64.max)")))
    }
    func testRejectsWrongShapes() {
        for bad in [#"{"format":1,"name":"A","created":1,"last_seen":null,"confirmed":false}"#,                                   // 足りない
                    #"{"format":2,"name":"A","created":1,"last_seen":null,"confirmed":false,"notice_snoozed_until":null}"#,
                    #"{"format":1,"name":"","created":1,"last_seen":null,"confirmed":false,"notice_snoozed_until":null}"#,       // 名前の規則
                    #"{"format":1,"name":"A","created":1,"last_seen":"2","confirmed":false,"notice_snoozed_until":null}"#,
                    #"{"format":1,"name":"A","created":1,"last_seen":null,"confirmed":1,"notice_snoozed_until":null}"#,
                    #"{"format":1,"name":"A","created":1,"last_seen":null,"confirmed":false,"notice_snoozed_until":null,"x":1}"#] {
            XCTAssertNil(HostMeta.decode(Data(bad.utf8)), bad)
        }
    }
}

final class MetaBookTests: TempDirTestCase {
    let registered = Locked<Set<PairingID>>([])
    let problems = Locked<[String]>([])
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func book() -> MetaBook {
        let r = registered, p = problems
        return MetaBook(store: hostStore(), isRegistered: { r.value.contains($0) }, problem: { e in p.update { $0.append(e) } })
    }
    func onDisk(_ id: PairingID) -> HostMeta? { hostStore().loadMetas().metas[id].flatMap(HostMeta.decode) }

    func testPairedConfirmedAndSeen() {
        let b = book()
        registered.value = [pid(1)]
        b.handle(.paired(pid(1), name: "MacBook"), now: t0)
        XCTAssertEqual(onDisk(pid(1)), HostMeta(name: "MacBook", created: 1_800_000_000, confirmed: false))
        b.handle(.confirmed(pid(1)), now: t0 + 60)
        XCTAssertEqual(onDisk(pid(1))?.confirmed, true)
        XCTAssertEqual(onDisk(pid(1))?.lastSeen, 1_800_000_060)
        b.handle(.seen(pid(1)), now: t0 + 60 + 3599)
        XCTAssertEqual(onDisk(pid(1))?.lastSeen, 1_800_000_060, "1 時間に 1 回に間引く")
        b.handle(.seen(pid(1)), now: t0 + 60 + 3600)
        XCTAssertEqual(onDisk(pid(1))?.lastSeen, 1_800_003_660)
        b.handle(.seen(pid(1)), now: t0 - 7200)
        XCTAssertEqual(onDisk(pid(1))?.lastSeen, 1_799_992_800, "時計が戻って last_seen が 1 時間以上未来なら書き直す")
    }
    // 極端な壁時計（Int64 の端）でも `.seen` の引き算で落ちない（守りの確かめ。実際には到達しない）
    func testSeenWithExtremeClockDoesNotCrash() {
        let b = book()
        registered.value = [pid(1)]
        b.handle(.paired(pid(1), name: "MacBook"), now: t0)
        b.handle(.confirmed(pid(1)), now: t0)
        let farPast = Date(timeIntervalSince1970: -9.2e18)   // Int64 に収まる極端な値（t - last があふれる）
        b.handle(.seen(pid(1)), now: farPast)
        XCTAssertEqual(b.meta(pid(1))?.lastSeen, Int64(-9.2e18), "あふれれば「離れている」として書き直す")
        b.handle(.seen(pid(1)), now: Date(timeIntervalSince1970: 9.2e18))
        XCTAssertEqual(b.meta(pid(1))?.lastSeen, Int64(9.2e18))
    }
    func testUnpairedDropsAndDeletesMeta() {
        let b = book()
        registered.value = [pid(1)]
        b.handle(.paired(pid(1), name: "MacBook"), now: t0)
        registered.value = []
        b.handle(.unpaired(pid(1)), now: t0)
        XCTAssertNil(b.meta(pid(1))); XCTAssertNil(onDisk(pid(1)))
    }
    // 知らせは起きた順に届くとは限らない: 解除の後に届いた照合・名乗りの知らせで .meta を作り直さない
    func testNoticesArrivingAfterUnpairDoNotRecreateMeta() {
        let b = book()
        registered.value = [pid(1)]
        b.handle(.paired(pid(1), name: "MacBook"), now: t0)
        b.handle(.confirmed(pid(1)), now: t0)
        registered.value = []                                   // 別のスレッドで解除された
        b.handle(.unpaired(pid(1)), now: t0)
        b.handle(.seen(pid(1)), now: t0 + 7200)                 // 入れ違いで後から届いた
        b.handle(.confirmed(pid(1)), now: t0 + 7200)
        XCTAssertNil(onDisk(pid(1))); XCTAssertNil(b.meta(pid(1)))
        b.handle(.paired(pid(2), name: "Late"), now: t0)        // 名乗りの知らせが解除の後に届いた
        XCTAssertNil(onDisk(pid(2)))
    }
    // 確かめた直後に解除が割り込んで .meta が残っても、後から届く解除の知らせが消す
    func testUnpairNoticeCleansUpAMetaWrittenInTheRace() throws {
        let b = book()
        try hostStore().saveMeta(pid(3), HostMeta(name: "Race", created: 1, confirmed: true).encoded())
        b.handle(.unpaired(pid(3)), now: t0)
        XCTAssertNil(onDisk(pid(3)))
    }
    func testLoadAndReconcile() throws {
        let s = hostStore()
        try s.save(StoredPairing(id: pid(1), secret: Bytes32(Data(repeating: 1, count: 32))!))
        try s.save(StoredPairing(id: pid(2), secret: Bytes32(Data(repeating: 2, count: 32))!))
        try s.saveMeta(pid(1), HostMeta(name: "Pending", created: 1, confirmed: false).encoded())
        try s.saveMeta(pid(9), Data("broken".utf8))
        let b = book()
        let r = b.load()
        XCTAssertEqual(r.unconfirmed, [pid(1)])
        XCTAssertEqual(r.problems.map(\.reason), [.badFormat])
        b.reconcile(registered: [pid(1), pid(2)], now: t0)
        XCTAssertEqual(b.meta(pid(2)), HostMeta(name: MetaBook.unknownName, created: 1_800_000_000, confirmed: true), ".meta が無い .key は確定扱い")
        XCTAssertEqual(onDisk(pid(2)), b.meta(pid(2)), ".meta を書く（起動のたびに created が今にならないように）")
        XCTAssertNil(b.meta(pid(9)), "登録表に無いものは写しに入れない")
        XCTAssertEqual(problems.value.count, 1)
        let again = book()
        _ = again.load(); again.reconcile(registered: [pid(1), pid(2)], now: t0 + 86_400)
        XCTAssertEqual(again.meta(pid(2))?.created, 1_800_000_000)
    }
    func testSnoozeIsSaved() {
        let b = book()
        registered.value = [pid(1)]
        b.handle(.paired(pid(1), name: "MacBook"), now: t0)
        b.snooze(pid(1), until: t0 + 86_400)
        XCTAssertEqual(onDisk(pid(1))?.noticeSnoozedUntil, 1_800_086_400)
    }
}
