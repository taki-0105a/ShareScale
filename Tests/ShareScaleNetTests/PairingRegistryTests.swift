import XCTest
@testable import ShareScaleNet
import ShareScaleProtocol

final class PairingRegistryTests: XCTestCase {
    var base: URL!
    var changes: Locked<[RegistryChange]>!
    override func setUp() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("reg-\(UUID().uuidString)", isDirectory: true)
        changes = Locked([])
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }
    func make() -> PairingRegistry {
        let c = changes!
        let r = PairingRegistry(store: SecretStore(base: base, role: .host, machine: "MAC-1"))
        r.observe { e in c.update { $0.append(e) } }
        return r
    }
    var roleDir: String { base.appendingPathComponent("pairings/host").path }
    func keyFileExists(_ id: PairingID) -> Bool { FileManager.default.fileExists(atPath: roleDir + "/" + id.hex + ".key") }
    /// 役割のフォルダの権限を緩めて、保管の読み書きを失敗させる（`prepareFolders` が緩いフォルダを使わない）
    func breakStore(_ broken: Bool) { chmod(roleDir, broken ? 0o755 : 0o700) }
    let now = ContinuousClock.now

    func testIssueLookupConsumeComplete() throws {
        let r = make(); r.load(now: now)
        let code = try XCTUnwrap(r.issueCode(now: now, wallNow: Date(timeIntervalSince1970: 1_000)))
        XCTAssertEqual(code.wallExpiry, 1_600)
        XCTAssertEqual(changes.value, [.codeIssued])
        XCTAssertEqual(r.pskSet, [code.id: code.secret], "受け側の PSK にはコードも入る")
        XCTAssertEqual(r.lookup(code.id, now: now)?.kind, .code)
        XCTAssertNil(r.completePairing(codeID: code.id, name: "Mac", now: now), "使用済みにする前は承認できない")
        XCTAssertTrue(r.consumeCode(code.id, now: now))
        XCTAssertFalse(r.consumeCode(code.id, now: now), "コードは 1 回だけ")
        let secret = try XCTUnwrap(r.completePairing(codeID: code.id, name: "MacBook", now: now))
        XCTAssertNotEqual(secret, code.secret, "新しい秘密に取り替える")
        XCTAssertEqual(r.lookup(code.id, now: now)?.kind, .registered)
        XCTAssertEqual(r.lookup(code.id, now: now)?.secret, secret)
        XCTAssertNil(r.currentCode, "コードは役目を終える")
        XCTAssertEqual(r.pendingIDs, [code.id])
        XCTAssertEqual(changes.value.last, .paired(code.id, name: "MacBook"), "名前は変化に載せる（保存は 2c の .meta）")
        XCTAssertEqual(SecretStore(base: base, role: .host, machine: "MAC-1").loadAll().pairings, [StoredPairing(id: code.id, secret: secret)], "保管にも書かれる")
    }
    func testNewCodeInvalidatesPreviousAndExpires() throws {
        let r = make(); r.load(now: now)
        let c1 = try XCTUnwrap(r.issueCode(now: now)); let c2 = try XCTUnwrap(r.issueCode(now: now))
        XCTAssertNil(r.lookup(c1.id, now: now), "前のコードは無効")
        XCTAssertEqual(r.pskSet.count, 1)
        XCTAssertNotNil(r.lookup(c2.id, now: now + .seconds(599)))
        XCTAssertNil(r.lookup(c2.id, now: now + .seconds(600)), "10 分で期限切れ（単調な時計）")
        XCTAssertFalse(r.consumeCode(c2.id, now: now + .seconds(600)))
        XCTAssertEqual(r.sweep(now: now + .seconds(600)), [.codeExpired])
        XCTAssertNil(r.currentCode)
        r.revokeCode(); XCTAssertEqual(changes.value.filter { $0 == .codeRevoked }.count, 0, "無いものの取り消しは知らせない")
        _ = r.issueCode(now: now); r.revokeCode()
        XCTAssertEqual(changes.value.last, .codeRevoked)
    }
    func testAbandonedCodeIsDropped() throws {
        let r = make(); r.load(now: now)
        let c = try XCTUnwrap(r.issueCode(now: now))
        r.abandonCode(c.id); XCTAssertNotNil(r.currentCode, "使用済みでなければ捨てない")
        XCTAssertTrue(r.consumeCode(c.id, now: now))
        r.abandonCode(c.id)
        XCTAssertNil(r.currentCode); XCTAssertEqual(changes.value.last, .codeAbandoned)
        XCTAssertNil(r.completePairing(codeID: c.id, name: "x", now: now))
    }
    func testConsumedCodeIsNotSweptAtExpiry() throws {
        let r = make(); r.load(now: now)
        let c = try XCTUnwrap(r.issueCode(now: now))
        XCTAssertTrue(r.consumeCode(c.id, now: now + .seconds(599)))
        XCTAssertEqual(r.sweep(now: now + .seconds(600)), [], "使用済みのコードは期限が来ても捨てない（その接続の結末が片付ける）")
        XCTAssertNotNil(r.currentCode)
        XCTAssertNotNil(r.completePairing(codeID: c.id, name: "MacBook", now: now + .seconds(601)), "承認でペアリングが完了する")
        XCTAssertNil(r.currentCode)
        XCTAssertEqual(r.registeredIDs, [c.id])
    }
    func testPendingExpiresUnlessSeen() throws {
        let r = make(); r.load(now: now)
        let c1 = try XCTUnwrap(r.issueCode(now: now)); _ = r.consumeCode(c1.id, now: now); _ = r.completePairing(codeID: c1.id, name: "A", now: now)
        let c2 = try XCTUnwrap(r.issueCode(now: now)); _ = r.consumeCode(c2.id, now: now); _ = r.completePairing(codeID: c2.id, name: "B", now: now)
        r.markSeen(c1.id, now: now + .seconds(5))
        XCTAssertEqual(changes.value.last, .confirmed(c1.id)); XCTAssertEqual(changes.value.last?.changesPSKSet, false)
        r.markSeen(c1.id, now: now + .seconds(6))
        XCTAssertEqual(changes.value.last, .seen(c1.id), "確定済みなら最終接続の更新だけ"); XCTAssertEqual(changes.value.last?.changesPSKSet, false)
        XCTAssertEqual(r.sweep(now: now + .seconds(599)), [])
        XCTAssertEqual(r.sweep(now: now + .seconds(600)), [.pendingExpired(c2.id)], "確定されなかった方だけ自動で解除")
        XCTAssertEqual(r.registeredIDs, [c1.id])
        XCTAssertEqual(r.store.loadAll().pairings.map(\.id), [c1.id], "秘密のファイルも消える")
        r.markSeen(c2.id, now: now); XCTAssertEqual(changes.value.last, .pendingExpired(c2.id), "無いものは確定できない")
    }
    func testSeenAfterPendingDeadlineDoesNotConfirm() throws {
        let r = make(); r.load(now: now)
        let c = try XCTUnwrap(r.issueCode(now: now)); _ = r.consumeCode(c.id, now: now); _ = r.completePairing(codeID: c.id, name: "A", now: now)
        let before = changes.value.count
        r.markSeen(c.id, now: now + .seconds(600))
        XCTAssertEqual(changes.value.count, before, "期限を過ぎた照合では確定しない（事象も出さない）")
        XCTAssertEqual(r.pendingIDs, [c.id])
        XCTAssertEqual(r.sweep(now: now + .seconds(601)), [.pendingExpired(c.id)], "次の片付けで解除される")
    }
    func testLoadRecountsUnconfirmedFromStartup() throws {
        let store = SecretStore(base: base, role: .host, machine: "MAC-1")
        try store.save(StoredPairing(id: pid(1), secret: secret(1))); try store.save(StoredPairing(id: pid(2), secret: secret(2)))
        let r = make()
        r.load(unconfirmed: [pid(2), pid(9)], now: now)
        XCTAssertEqual(r.registeredIDs, [pid(1), pid(2)]); XCTAssertEqual(r.pendingIDs, [pid(2)])
        XCTAssertEqual(r.lookup(pid(1), now: now)?.kind, .registered)
        XCTAssertEqual(r.sweep(now: now + .seconds(600)), [.pendingExpired(pid(2))], "起動した時点から 10 分を数え直す")
    }
    func testUnpairAndLimit() throws {
        let r = make(); r.load(now: now)
        for _ in 0..<Limits.maxPairings {
            let c = try XCTUnwrap(r.issueCode(now: now)); XCTAssertTrue(r.consumeCode(c.id, now: now))
            XCTAssertNotNil(r.completePairing(codeID: c.id, name: "x", now: now))
        }
        XCTAssertTrue(r.isFull); XCTAssertNil(r.issueCode(now: now), "上限に達したらコードを出せない")
        let some = try XCTUnwrap(r.registeredIDs.first)
        try r.unpair(some)
        XCTAssertEqual(changes.value.last, .unpaired(some)); XCTAssertFalse(r.isFull); XCTAssertNil(r.lookup(some, now: now))
        XCTAssertEqual(r.store.loadAll().pairings.count, Limits.maxPairings - 1)
        XCTAssertNotNil(r.issueCode(now: now))
    }
    func testLoadedPairingsSurviveNewCodes() throws {
        let store = SecretStore(base: base, role: .host, machine: "MAC-1")
        try store.save(StoredPairing(id: pid(1), secret: secret(1)))
        let r = make(); r.load(now: now)
        let c = try XCTUnwrap(r.issueCode(now: now))
        XCTAssertEqual(r.pskSet, [pid(1): secret(1), c.id: c.secret])
    }

    func testCompletePairingDropsTheSaveWhenTheCodeChangedMeanwhile() throws {
        // 保存（ロックの外）の間にコードが発行し直された・取り消された: 保存したファイルを消し、表に入れない
        for replace in [true, false] {
            let r = make(); r.load(now: now); changes.value = []
            let c = try XCTUnwrap(r.issueCode(now: now)); XCTAssertTrue(r.consumeCode(c.id, now: now))
            let t = now
            r.afterSaveHook = { _ in if replace { _ = r.issueCode(now: t) } else { r.revokeCode() } }
            XCTAssertTrue(r.completePairing(codeID: c.id, name: "MacBook", now: now) == nil, "変わっていれば nil（結末は .saveFailed）")
            r.afterSaveHook = nil
            XCTAssertFalse(keyFileExists(c.id), "保存したファイルを消す")
            XCTAssertEqual(r.registeredIDs, []); XCTAssertEqual(r.pendingIDs, [])
            XCTAssertFalse(changes.value.contains { if case .paired = $0 { return true }; return false })
            if replace {
                let next = try XCTUnwrap(r.currentCode); XCTAssertNotEqual(next.id, c.id)
                r.abandonCode(c.id)
                XCTAssertEqual(r.currentCode, next, "結末の abandonCode は、id が違うので新しいコードを捨てない")
            } else {
                XCTAssertNil(r.currentCode)
            }
        }
    }
    func testCompletePairingKeepsTheCodeWhenSavingFails() throws {
        let r = make(); r.load(now: now)
        let c = try XCTUnwrap(r.issueCode(now: now)); XCTAssertTrue(r.consumeCode(c.id, now: now))
        breakStore(true); defer { breakStore(false) }
        XCTAssertNil(r.completePairing(codeID: c.id, name: "MacBook", now: now), "保存できなければ nil")
        XCTAssertEqual(r.currentCode?.id, c.id, "コードは残す（結末の abandonCode が捨てる）")
        XCTAssertEqual(r.registeredIDs, [])
        r.abandonCode(c.id); XCTAssertNil(r.currentCode)
    }
    func testSweepRetriesDeletesThatFailed() throws {
        let r = make(); r.load(now: now)
        let c = try XCTUnwrap(r.issueCode(now: now)); _ = r.consumeCode(c.id, now: now)
        XCTAssertNotNil(r.completePairing(codeID: c.id, name: "A", now: now))
        breakStore(true)
        XCTAssertEqual(r.sweep(now: now + .seconds(600)), [.pendingExpired(c.id)], "消せなくても表からは外し、変化を知らせる")
        XCTAssertEqual(r.registeredIDs, []); XCTAssertNil(r.lookup(c.id, now: now), "照合には使わない")
        XCTAssertEqual(r.pendingDeletes, [c.id])
        XCTAssertTrue(keyFileExists(c.id))
        breakStore(false)
        r.load(now: now)
        XCTAssertEqual(r.registeredIDs, [], "読み直しても、消し直し待ちのものは表に入れない")
        let before = changes.value.count
        XCTAssertEqual(r.sweep(now: now + .seconds(601)), [], "消し直しでは変化を知らせない")
        XCTAssertEqual(changes.value.count, before)
        XCTAssertFalse(keyFileExists(c.id), "次の sweep で消し直す")
        XCTAssertEqual(r.pendingDeletes, [])
    }
    func testUnpairKeepsTheTableWhenDeleteFailsAndToleratesRepeats() throws {
        let store = SecretStore(base: base, role: .host, machine: "MAC-1")
        try store.save(StoredPairing(id: pid(1), secret: secret(1))); try store.save(StoredPairing(id: pid(2), secret: secret(2)))
        let r = make(); r.load(now: now)
        breakStore(true)
        XCTAssertThrowsError(try r.unpair(pid(1)), "消せなければ throw（応答は busy）")
        XCTAssertEqual(r.registeredIDs, [pid(1), pid(2)], "表はそのまま")
        breakStore(false)
        // 同じ id の解除が同時に 2 つ
        let errors = Counter()
        DispatchQueue.concurrentPerform(iterations: 2) { _ in if (try? r.unpair(pid(1))) == nil { errors.add() } }
        XCTAssertEqual(errors.value, 0, "2 回目はファイルが無いので消せたものとみなす")
        XCTAssertEqual(changes.value.filter { $0 == .unpaired(pid(1)) }.count, 1, "知らせるのは表から外した 1 回だけ")
        XCTAssertEqual(r.registeredIDs, [pid(2)]); XCTAssertFalse(keyFileExists(pid(1)))
    }
    func testReloadKeepsPendingDeadlines() throws {
        let r = make(); r.load(now: now)
        let c = try XCTUnwrap(r.issueCode(now: now)); _ = r.consumeCode(c.id, now: now)
        XCTAssertNotNil(r.completePairing(codeID: c.id, name: "A", now: now))
        r.load(now: now + .seconds(300))   // stop の後の start など（未確定を渡し忘れても確定扱いにしない）
        XCTAssertEqual(r.pendingIDs, [c.id])
        r.load(unconfirmed: [c.id], now: now + .seconds(400))   // 2c は .meta の未確定の組を渡す（すでに確定待ちの id も入る）
        XCTAssertEqual(r.pendingIDs, [c.id])
        XCTAssertEqual(r.sweep(now: now + .seconds(599)), [])
        XCTAssertEqual(r.sweep(now: now + .seconds(600)), [.pendingExpired(c.id)], "期限は延ばさない")
    }
    func testReloadDoesNotRependConfirmedHere() throws {
        let r = make(); r.load(now: now)
        let c = try XCTUnwrap(r.issueCode(now: now)); _ = r.consumeCode(c.id, now: now)
        XCTAssertNotNil(r.completePairing(codeID: c.id, name: "A", now: now))
        r.markSeen(c.id, now: now + .seconds(1))
        XCTAssertEqual(r.pendingIDs, [])
        r.load(unconfirmed: [c.id], now: now + .seconds(2))   // .meta の確定の保存が遅れていても
        XCTAssertEqual(r.pendingIDs, [], "この Host の中で確定したものは確定待ちに戻さない")
        let fresh = make(); fresh.load(unconfirmed: [c.id], now: now)
        XCTAssertEqual(fresh.pendingIDs, [c.id], "起動し直した時（表が空）は .meta に従う")
    }
    func testUnpairThatCannotDeleteRestoresTheEntry() throws {
        let r = make(); r.load(now: now)
        let c = try XCTUnwrap(r.issueCode(now: now)); _ = r.consumeCode(c.id, now: now)
        let secret = try XCTUnwrap(r.completePairing(codeID: c.id, name: "A", now: now))
        let dir = r.store.roleDir.path
        XCTAssertEqual(chmod(dir, 0o500), 0)   // ファイルを消せなくする
        defer { chmod(dir, 0o700) }
        let before = changes.value.count
        XCTAssertThrowsError(try r.unpair(c.id))
        XCTAssertEqual(changes.value.count, before, "消せなければ知らせない")
        XCTAssertEqual(r.lookup(c.id, now: now)?.secret, secret, "表に戻る（照合に使える）")
        XCTAssertEqual(r.pendingIDs, [c.id], "確定待ちの期限も戻る")
        chmod(dir, 0o700)
        XCTAssertNoThrow(try r.unpair(c.id))
        XCTAssertEqual(changes.value.last, .unpaired(c.id))
        XCTAssertNil(r.lookup(c.id, now: now))
        XCTAssertEqual(r.store.loadAll().pairings, [])
    }
    func testChangesPSKSetCoversEveryCase() {
        let psk: [RegistryChange] = [.codeIssued, .codeRevoked, .codeExpired, .codeAbandoned, .paired(pid(1), name: "A"), .unpaired(pid(1)), .pendingExpired(pid(1))]
        XCTAssertTrue(psk.allSatisfy(\.changesPSKSet))
        XCTAssertFalse(RegistryChange.confirmed(pid(1)).changesPSKSet); XCTAssertFalse(RegistryChange.seen(pid(1)).changesPSKSet)
    }
}
