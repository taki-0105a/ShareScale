import XCTest
@testable import ShareScaleEngine
@testable import ShareScaleHostCore
import ShareScaleNet
import ShareScaleProtocol

/// host-control の形式と、フォルダの読み書き（一時フォルダ。通知は送らない）
final class HostControlFormatTests: TempDirTestCase {
    var folder: HostControlFolder { HostControlFolder(directory: dir.appendingPathComponent("support/host-control", isDirectory: true)) }
    let now: Int64 = 1_800_000_000

    func testRequestRoundTripAndShape() throws {
        let q = try XCTUnwrap(HostControlRequest(op: .unpair, id: pid(1), at: now))
        XCTAssertEqual(String(decoding: q.encoded(), as: UTF8.self), "{\"format\":1,\"op\":\"unpair\",\"id\":\"\(pid(1).hex)\",\"at\":1800000000}\n")
        XCTAssertEqual(HostControlRequest.decode(q.encoded()), q)
        let s = try XCTUnwrap(HostControlRequest(op: .setAllowGlobal, value: true, at: now))
        XCTAssertEqual(String(decoding: s.encoded(), as: UTF8.self), "{\"format\":1,\"op\":\"set_allow_global\",\"value\":true,\"at\":1800000000}\n")
        XCTAssertEqual(HostControlRequest.decode(s.encoded()), s)
        XCTAssertEqual(HostControlRequest.decode(Data("{\"format\":1,\"op\":\"quit\",\"at\":5}".utf8)), HostControlRequest(op: .quit, at: 5))
    }
    func testRequestRulesAreStrict() {
        XCTAssertNil(HostControlRequest(op: .unpair, at: now), "unpair は id が要る")
        XCTAssertNil(HostControlRequest(op: .pause, id: pid(1), at: now), "pause に id は付けない")
        XCTAssertNil(HostControlRequest(op: .setTailscaleOnly, at: now), "set_* は value が要る")
        XCTAssertNil(HostControlRequest(op: .quit, value: true, at: now))
        XCTAssertNil(HostControlRequest(op: .quit, at: -1)); XCTAssertNil(HostControlRequest(op: .quit, at: HostMeta.maxTime + 1))
        for bad in ["{\"format\":2,\"op\":\"pause\",\"at\":1}", "{\"format\":1,\"op\":\"reboot\",\"at\":1}", "{\"format\":1,\"op\":\"pause\",\"at\":1,\"x\":1}",
                    "{\"format\":1,\"op\":\"pause\",\"at\":\"1\"}", "{\"format\":1,\"op\":\"pause\",\"at\":1.0}", "{\"format\":1,\"op\":\"unpair\",\"id\":\"ZZ\",\"at\":1}",
                    "{\"format\":1,\"op\":\"set_allow_global\",\"value\":1,\"at\":1}", "{\"format\":1,\"op\":\"pause\",\"at\":1}\n{}", "[]", "", "\u{FEFF}{\"format\":1,\"op\":\"pause\",\"at\":1}"] {
            XCTAssertNil(HostControlRequest.decode(Data(bad.utf8)), bad)
        }
    }
    func testRequestFileNames() {
        XCTAssertEqual(HostControlFolder.requestID("request-6ba7b810-9dad-11d1-80b4-00c04fd430c8.json"), "6ba7b810-9dad-11d1-80b4-00c04fd430c8")
        XCTAssertNil(HostControlFolder.requestID("request-6BA7B810-9DAD-11D1-80B4-00C04FD430C8.json"), "小文字だけ")
        XCTAssertNil(HostControlFolder.requestID("state.json")); XCTAssertNil(HostControlFolder.requestID("request-x.json"))
        XCTAssertNil(HostControlFolder.requestID(".request-6ba7b810-9dad-11d1-80b4-00c04fd430c8.tmp"))
    }
    func testWriteReadOrderDropAndLimit() throws {
        let f = folder
        // 順は at の昇順（同じ at は名前の順）。5 分より古い・未来のものは捨てる。1 回に 32 件まで
        try f.writeRequest(HostControlRequest(op: .resume, at: now + HostControlFolder.futureSlack)!)   // 10 秒のゆとりの中は未来でも処理する
        try f.writeRequest(HostControlRequest(op: .pause, at: now - 20)!)
        try f.writeRequest(HostControlRequest(op: .quit, at: now - 301)!)          // 古い
        try f.writeRequest(HostControlRequest(op: .quit, at: now + HostControlFolder.futureSlack + 1)!)   // 未来（10 秒のゆとりの外）
        let names = try FileManager.default.contentsOfDirectory(atPath: f.directory.path)
        XCTAssertEqual(names.filter { HostControlFolder.requestID($0) != nil }.count, 4)
        var st = stat(); XCTAssertEqual(stat(f.directory.path, &st), 0); XCTAssertEqual(st.st_mode & 0o777, 0o700, "フォルダは 700")
        XCTAssertEqual(stat(f.directory.appendingPathComponent(try XCTUnwrap(names.first)).path, &st), 0); XCTAssertEqual(st.st_mode & 0o777, 0o600, "ファイルは 600")
        let r = f.readRequests(now: now)
        XCTAssertEqual(r.requests.map(\.op), [.pause, .resume])
        XCTAssertEqual(r.dropped, 2); XCTAssertEqual(r.problems.count, 2)
        XCTAssertTrue(r.problems.allSatisfy { $0.contains("stale or future") }, r.problems.joined(separator: "\n"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).filter { HostControlFolder.requestID($0) != nil }, [], "処理したものも捨てたものも消す")
        for i in 0..<40 { try f.writeRequest(HostControlRequest(op: .pause, at: now - Int64(40 - i))!) }
        let first = f.readRequests(now: now)
        XCTAssertEqual(first.requests.count, 32); XCTAssertEqual(first.requests.first?.at, now - 40)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.directory.path).filter { HostControlFolder.requestID($0) != nil }.count, 8, "残りは次の読み直しで")
        XCTAssertEqual(f.readRequests(now: now).requests.count, 8)
        XCTAssertEqual(f.readRequests(now: now), HostControlFolder.Read())
    }
    func testUnsafeRequestFilesAreDroppedAndOthersLeftAlone() throws {
        let f = folder
        try f.writeRequest(HostControlRequest(op: .pause, at: now)!)
        let loose = f.directory.appendingPathComponent("request-11111111-1111-1111-1111-111111111111.json")
        try HostControlRequest(op: .quit, at: now)!.encoded().write(to: loose)
        chmod(loose.path, 0o644)
        let link = f.directory.appendingPathComponent("request-22222222-2222-2222-2222-222222222222.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: loose)
        let other = f.directory.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: other)
        let big = f.directory.appendingPathComponent("request-33333333-3333-3333-3333-333333333333.json")
        try Data(repeating: 0x20, count: 5000).write(to: big); chmod(big.path, 0o600)
        let r = f.readRequests(now: now)
        XCTAssertEqual(r.requests.map(\.op), [.pause])
        XCTAssertEqual(r.dropped, 3)
        XCTAssertEqual(Set(r.problems.map { ($0.split(separator: ":").last.map(String.init) ?? "").trimmingCharacters(in: .whitespaces) }), ["loosePermissions", "notRegularFile", "tooLarge"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: loose.path)); XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "形の違う名前は触らない")
    }
    func testLooseFolderIsNotUsed() throws {
        let f = folder
        try f.writeRequest(HostControlRequest(op: .pause, at: now)!)
        chmod(f.directory.path, 0o755)
        let r = f.readRequests(now: now)
        XCTAssertEqual(r.requests, []); XCTAssertEqual(r.problems, ["host-control folder \(f.directory.path): folderLoosePermissions"])
        XCTAssertThrowsError(try f.writeRequest(HostControlRequest(op: .pause, at: now)!))
        XCTAssertNil(f.readState())
        chmod(f.directory.path, 0o700)
    }
    func testStaleTemporariesAreRemovedExceptOwnAndLiving() throws {
        let f = folder
        try f.writeRequest(HostControlRequest(op: .pause, at: now)!)   // フォルダを作る
        let dead = "999999"   // macOS の pid の上限は 99998 なので、動いているプロセスではない
        let names = [".state.\(dead).123.tmp", ".request-6ba7b810-9dad-11d1-80b4-00c04fd430c8.\(dead).tmp",
                     ".state.\(getpid()).1.tmp", ".request-6ba7b810-9dad-11d1-80b4-00c04fd430c9.\(getpid()).tmp", ".state.1.1.tmp", ".other.tmp", "keep.txt"]
        for n in names { try Data("x".utf8).write(to: f.directory.appendingPathComponent(n)) }
        XCTAssertEqual(HostControlFolder.temporaryOwner(".state.\(dead).123.tmp"), .some(pid_t(999999)))
        XCTAssertEqual(HostControlFolder.temporaryOwner(".request-6ba7b810-9dad-11d1-80b4-00c04fd430c8.\(dead).tmp"), .some(pid_t(999999)))
        XCTAssertTrue(HostControlFolder.temporaryOwner(".other.tmp") == nil); XCTAssertTrue(HostControlFolder.temporaryOwner("state.json") == nil)
        f.removeStaleTemporaries()
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: f.directory.path))
        XCTAssertFalse(left.contains(".state.\(dead).123.tmp")); XCTAssertFalse(left.contains(".request-6ba7b810-9dad-11d1-80b4-00c04fd430c8.\(dead).tmp"))
        XCTAssertTrue(left.contains(".state.\(getpid()).1.tmp"), "自分の pid は消さない"); XCTAssertTrue(left.contains(".request-6ba7b810-9dad-11d1-80b4-00c04fd430c9.\(getpid()).tmp"))
        XCTAssertTrue(left.contains(".state.1.1.tmp"), "動いているプロセス（launchd）の pid は消さない")
        XCTAssertTrue(left.contains(".other.tmp")); XCTAssertTrue(left.contains("keep.txt"))
        XCTAssertEqual(f.readRequests(now: now).requests.map(\.op), [.pause], "指示はそのまま")
    }
    func testStateShapeAndRoundTrip() throws {
        var d = HostDiagnostics(); d.listener = .listening(port: 47651); d.staleNotices = [pid(2)]; d.lastError = "x\u{7}y"; d.pairingCount = 2
        d.tailscaleOnly = true; d.updating = true; d.contention = true; d.storeProblems = [StoreProblem(name: "x.key", reason: .unreadable)]
        var s = SystemDiagnostics(); s.firewall = .on(.allowed); s.fileVault = true; s.loginItem = .enabled
        let st = HostControlState(pid: 42, version: "1.1.0", build: 10100, running: true, paused: false, listener: d.listener,
                                  pairings: [HostControlState.Pairing(id: pid(1), name: "Air", lastSeen: 1_800_000_000, confirmed: true, stale: false),
                                             HostControlState.Pairing(id: pid(2), name: "Old", lastSeen: nil, confirmed: false, stale: true)],
                                  codeExpires: 1_800_000_600, host: d, system: s, updated: 1_800_000_001)
        let text = String(decoding: st.encoded(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{\"format\":1,\"pid\":42,\"version\":\"1.1.0\",\"build\":10100,\"running\":true,\"paused\":false,\"listener\":{\"status\":\"listening\",\"port\":47651},\"pairings\":[{\"id\":\"\(pid(1).hex)\",\"name\":\"Air\",\"last_seen\":1800000000,\"confirmed\":true,\"stale\":false},{\"id\":\"\(pid(2).hex)\",\"name\":\"Old\",\"last_seen\":null,\"confirmed\":false,\"stale\":true}],\"code\":{\"expires\":1800000600},\"diagnostics\":{\"tailscale_only\":true,\"allow_global\":false,\"tailscale\":\"none\",\"updating\":true,\"contention\":true,"), text)
        XCTAssertTrue(text.contains("\"last_error\":\"xy\""), "制御文字は除く")
        XCTAssertTrue(text.contains("\"firewall\":\"allowed\",\"filevault\":true,\"login_item\":\"enabled\"}"), text)
        XCTAssertTrue(text.hasSuffix(",\"updated\":1800000001}\n"), text)
        XCTAssertFalse(text.contains("sharescale1:")); XCTAssertFalse(text.contains("\"k\""))
        let sum = try XCTUnwrap(HostControlState.decode(st.encoded()))
        XCTAssertEqual(sum.pid, 42); XCTAssertEqual(sum.build, 10100); XCTAssertEqual(sum.running, true); XCTAssertEqual(sum.listenerStatus, "listening"); XCTAssertEqual(sum.port, 47651)
        XCTAssertEqual(sum.pairings, st.pairings); XCTAssertEqual(sum.codeExpires, 1_800_000_600); XCTAssertEqual(sum.updated, 1_800_000_001)
        XCTAssertTrue(sum.tailscaleOnly); XCTAssertFalse(sum.allowGlobal); XCTAssertTrue(sum.updating)
        XCTAssertEqual(sum.firewall, "allowed"); XCTAssertEqual(sum.loginItem, "enabled"); XCTAssertEqual(sum.fileVault, true); XCTAssertEqual(sum.lastError, "xy")
        XCTAssertTrue(sum.contention); XCTAssertEqual(sum.storeProblems, 1)
        XCTAssertEqual(HostControlState.word(FirewallStatus.on(.notInRules)), "not_in_rules"); XCTAssertEqual(HostControlState.word(FirewallStatus.on(.unknown)), "on")
        XCTAssertEqual(HostControlState.word(LoginItemStatus.notFound), "not_found")
        let f = folder
        try f.writeState(st)
        XCTAssertEqual(f.readState(), sum)
        var stt = stat(); XCTAssertEqual(stat(f.stateURL.path, &stt), 0); XCTAssertEqual(stt.st_mode & 0o777, 0o600)
        var stopped = st; stopped.running = false; stopped.listener = .failed("boom", retryIn: 4)
        XCTAssertTrue(String(decoding: stopped.encoded(), as: UTF8.self).contains("\"listener\":{\"status\":\"failed\",\"detail\":\"boom\",\"retry_in\":4}"))
        XCTAssertNil(HostControlState.decode(Data("{\"format\":1}".utf8)))
        XCTAssertNil(HostControlState.decode(Data(String(decoding: st.encoded(), as: UTF8.self).replacingOccurrences(of: "\"build\":10100,", with: "").utf8)), "build は必須")
    }
}

/// host-control を `HostRuntime` に当てる（127.0.0.1 だけで待ち受け。偽のディスプレイ。通知は送らない）
final class HostControlServiceTests: TempDirTestCase {
    var runtime: HostRuntime?
    let shown = Locked<[PairingCode]>([])
    let windows = Locked<[HostControlWindow]>([])
    let health = Locked<[Bool]>([])
    let settings = Locked<[(HostControlOp, Bool)]>([])
    let quits = Locked(0)
    let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))

    override func tearDown() { runtime?.stop(); runtime = nil; super.tearDown() }

    func make() -> (HostRuntime, HostControlService) {
        var c = HostRuntime.Configuration(supportDirectory: dir.appendingPathComponent("support", isDirectory: true), logDirectory: nil, machine: "MAC-TEST")
        c.port = listenPortForTests(); c.listenScope = .loopbackOnly; c.engine.coalesceDelay = 0.02; c.engine.checkInterval = 3600
        let clock = clock
        let r = HostRuntime(configuration: c, displays: FakeDisplays([virtualDisplay(factor: 2)]), approver: FakeApprover(),
                            identity: HostIdentity(name: { "Mac Studio" }, model: { "Mac Studio (2025)" }),
                            readAddresses: { [] }, localHostName: { "studio" }, wallClock: { clock.value })
        runtime = r
        let folder = HostControlFolder(directory: dir.appendingPathComponent("support/host-control", isDirectory: true))
        let shown = shown, windows = windows, settings = settings, quits = quits, health = health
        let s = HostControlService(folder: folder, runtime: r, version: "1.1.0", build: 10100, pollInterval: 3600, wallClock: { clock.value },
                                   onShowCode: { c in shown.update { $0.append(c) } }, onShow: { w in windows.update { $0.append(w) } },
                                   onSetting: { op, v in settings.update { $0.append((op, v)) } }, onQuit: { quits.update { $0 += 1 } },
                                   onStateHealth: { ok in health.update { $0.append(ok) } })
        return (r, s)
    }
    var now: Int64 { Int64(clock.value.timeIntervalSince1970) }
    func put(_ s: HostControlService, _ op: HostControlOp, id: PairingID? = nil, value: Bool? = nil, at: Int64? = nil) throws {
        try s.folder.writeRequest(XCTUnwrap(HostControlRequest(op: op, id: id, value: value, at: at ?? now)))
    }

    func testPauseResumeSettingsAndStateFile() async throws {
        let (r, s) = make()
        try r.store.save(StoredPairing(id: pid(1), secret: Bytes32(Data(repeating: 1, count: 32))!))
        r.start()
        await waitFor(5) { if case .listening = r.diagnostics.listener { return true }; return false }
        try put(s, .pause, at: now - 3)
        try put(s, .setTailscaleOnly, value: true, at: now - 2)
        try put(s, .setAllowGlobal, value: true, at: now - 1)
        s.poll()
        XCTAssertTrue(r.diagnostics.paused); XCTAssertTrue(r.diagnostics.tailscaleOnly); XCTAssertTrue(r.diagnostics.allowGlobal)
        XCTAssertEqual(settings.value.map(\.0), [.setTailscaleOnly, .setAllowGlobal]); XCTAssertEqual(settings.value.map(\.1), [true, true])
        let st = try XCTUnwrap(s.folder.readState())
        XCTAssertEqual(st.running, true); XCTAssertEqual(st.paused, true); XCTAssertEqual(st.version, "1.1.0"); XCTAssertEqual(st.build, 10100); XCTAssertEqual(st.pid, Int64(getpid()))
        XCTAssertEqual(st.pairings.map(\.id), [pid(1)]); XCTAssertEqual(st.pairings.first?.name, MetaBook.unknownName); XCTAssertEqual(st.updated, now)
        try put(s, .resume); try put(s, .setTailscaleOnly, value: false)
        s.poll()
        XCTAssertFalse(r.diagnostics.paused); XCTAssertFalse(r.diagnostics.tailscaleOnly)
        XCTAssertEqual(s.folder.readState()?.paused, false)
        XCTAssertEqual(quits.value, 0)
        let log = r.log.recentAll().joined(separator: "\n")
        XCTAssertTrue(log.contains("host-control: pause"), log); XCTAssertTrue(log.contains("host-control: set_allow_global"), log)
    }
    func testIssueCodeShowsTheCodeInTheHostWindowAndNotInTheFile() async throws {
        let (r, s) = make()
        r.start()
        await waitFor(5) { if case .listening = r.diagnostics.listener { return true }; return false }
        try put(s, .issueCode)
        s.poll()
        XCTAssertEqual(shown.value.count, 1)
        let code = try XCTUnwrap(shown.value.first)
        XCTAssertEqual(r.currentCode?.text, code.encoded())
        let raw = try String(contentsOf: s.folder.stateURL, encoding: .utf8)
        XCTAssertFalse(raw.contains(code.secret.base64URL)); XCTAssertFalse(raw.contains("sharescale1:"))
        XCTAssertEqual(s.folder.readState()?.codeExpires, code.expiresAt, "期限だけを載せる")
    }
    // ShareScale.app のメニューの「接続コードを表示…」「診断…」（計画 2f-2）: Host の窓を出すだけで、コードは出し直さない
    func testShowCodeAndShowDiagnosticsAskForHostWindows() async throws {
        let (r, s) = make()
        r.start()
        await waitFor(5) { if case .listening = r.diagnostics.listener { return true }; return false }
        clock.value = clock.value.addingTimeInterval(2)   // 起動より後に置く（起動より前の窓を出す指示は捨てる）
        try put(s, .showCode, at: now - 1)
        try put(s, .showDiagnostics, at: now)
        s.poll()
        XCTAssertEqual(windows.value, [.diagnostics], "発行中のコードが無ければ、コードの窓は出さない")
        let before = try XCTUnwrap(r.issueCode())
        try put(s, .showCode)
        s.poll()
        XCTAssertEqual(windows.value, [.diagnostics, .currentCode])
        XCTAssertEqual(r.currentCode?.text, before.encoded(), "コードは作り直さない")
        XCTAssertEqual(shown.value.count, 0)
        let log = r.log.recentAll().joined(separator: "\n")
        XCTAssertTrue(log.contains("host-control: show_code failed: no code is being shown"), log)
        XCTAssertTrue(log.contains("host-control: show_diagnostics"), log)
        XCTAssertTrue(HostControlOp.showCode.presentsWindow); XCTAssertTrue(HostControlOp.showDiagnostics.presentsWindow)
        XCTAssertFalse(HostControlOp.pause.presentsWindow)
        XCTAssertEqual(HostControlRequest.decode(HostControlRequest(op: .showDiagnostics, at: now)!.encoded())?.op, .showDiagnostics)
    }
    func testUnpairSnoozeAndUnknownIDs() async throws {
        let (r, s) = make()
        try r.store.save(StoredPairing(id: pid(1), secret: Bytes32(Data(repeating: 1, count: 32))!))
        try r.store.save(StoredPairing(id: pid(2), secret: Bytes32(Data(repeating: 2, count: 32))!))
        try r.store.saveMeta(pid(2), HostMeta(name: "Old", created: now - 100 * 86_400, lastSeen: now - 90 * 86_400, confirmed: true).encoded())
        r.start()
        await waitFor(5) { if case .listening = r.diagnostics.listener { return true }; return false }
        await waitFor(3) { r.diagnostics.staleNotices == [pid(2)] }
        XCTAssertEqual(r.diagnostics.staleNotices, [pid(2)])
        try put(s, .unpair, id: pid(1), at: now - 3)
        try put(s, .snooze, id: pid(2), at: now - 2)
        try put(s, .unpair, id: pid(9), at: now - 1)
        s.poll()
        await waitFor(3) { r.pairings[pid(1)] == nil && r.diagnostics.staleNotices.isEmpty }
        XCTAssertNil(r.pairings[pid(1)]); XCTAssertEqual(r.diagnostics.pairingCount, 1)
        XCTAssertEqual(r.diagnostics.staleNotices, [], "「あとで」で知らせが消える")
        XCTAssertEqual(r.pairings[pid(2)]?.noticeSnoozedUntil, now + StaleNotice.snoozeFor)
        let log = r.log.recentAll().joined(separator: "\n")
        XCTAssertTrue(log.contains("host-control: unpair failed: not paired"), log)
        XCTAssertEqual(HostControlService.apply(HostControlRequest(op: .snooze, id: pid(9), at: now)!, to: r), .failed("not paired"))
    }
    // Host が止まっていた間に置かれた quit・issue_code は、次の起動で行わない（ほかの指示は当てる。計画 2d-2）
    func testQuitAndIssueCodePlacedBeforeStartAreIgnored() async throws {
        let (r, s) = make()
        r.start()
        await waitFor(5) { if case .listening = r.diagnostics.listener { return true }; return false }
        XCTAssertEqual(s.startedAt, now)
        try put(s, .quit, at: now - 3)
        try put(s, .issueCode, at: now - 2)
        try put(s, .showDiagnostics, at: now - 2)
        try put(s, .pause, at: now - 1)
        s.poll()
        XCTAssertEqual(quits.value, 0, "起動より前の quit は捨てる"); XCTAssertEqual(shown.value.count, 0, "起動より前の issue_code は捨てる")
        XCTAssertEqual(windows.value, [], "起動より前の show_diagnostics も捨てる（計画 2f-2）")
        XCTAssertTrue(r.diagnostics.paused, "設定の指示は当てる")
        XCTAssertEqual(s.folder.readRequests(now: now).requests, [], "捨てた指示も消える")
        let log = r.log.recentAll().joined(separator: "\n")
        XCTAssertTrue(log.contains("host-control: quit ignored (placed before this Host started)"), log)
        XCTAssertTrue(log.contains("host-control: issue_code ignored (placed before this Host started)"), log)
        XCTAssertTrue(HostControlService.placedBeforeStart(HostControlRequest(op: .quit, at: now - 1)!, startedAt: now))
        XCTAssertFalse(HostControlService.placedBeforeStart(HostControlRequest(op: .quit, at: now)!, startedAt: now))
        XCTAssertFalse(HostControlService.placedBeforeStart(HostControlRequest(op: .resume, at: now - 1)!, startedAt: now))
    }
    func testQuitStopsTheRuntimeAndIgnoresLaterRequests() async throws {
        let (r, s) = make()
        r.start()
        await waitFor(5) { if case .listening = r.diagnostics.listener { return true }; return false }
        clock.value = clock.value.addingTimeInterval(10)   // Host の起動より後に置いた指示（起動より前の quit は捨てる。計画 2d-2）
        try put(s, .quit, at: now - 2)
        try put(s, .pause, at: now - 1)
        s.poll()
        XCTAssertEqual(quits.value, 1)
        await waitFor(3) { r.diagnostics.listener == .stopped }
        XCTAssertEqual(r.diagnostics.listener, .stopped)
        XCTAssertFalse(r.diagnostics.paused, "quit の後の指示は処理しない")
        XCTAssertEqual(s.folder.readState()?.running, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.folder.directory.path))
        try put(s, .pause)
        s.poll()
        XCTAssertEqual(quits.value, 1, "止めた後の読み直しは何もしない")
    }
    func testStartPollsAndStopWritesNotRunning() async throws {
        let (r, s) = make()
        r.start()
        await waitFor(5) { if case .listening = r.diagnostics.listener { return true }; return false }
        try put(s, .pause)
        s.start(); s.start()
        XCTAssertTrue(s.isRunning)
        await waitFor(3) { r.diagnostics.paused }
        XCTAssertTrue(r.diagnostics.paused, "start は最初の読み直しをする")
        await waitFor(3) { s.folder.readState() != nil }   // 一時停止を反映してから state.json を書くまでの間に読まない（計画 2d-2 で見つけた揺れ）
        XCTAssertEqual(s.folder.readState()?.running, true)
        r.setPaused(false)
        s.noteChanged(); s.noteChanged()
        await waitFor(3) { s.folder.readState()?.paused == false }
        XCTAssertEqual(s.folder.readState()?.paused, false, "onChange からの書き込みはまとめて 0.5 秒後")
        s.stop()
        XCTAssertFalse(s.isRunning)
        XCTAssertEqual(s.folder.readState()?.running, false)
        s.stop()
        // 点検 B: 止めた後の読み直しは何もしない（指示は残る）。`start` は 1 回限り
        s.start()
        XCTAssertFalse(s.isRunning, "stop の後の start は何もしない")
        try put(s, .pause)
        s.poll()
        XCTAssertFalse(r.diagnostics.paused, "止めた後は処理しない")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: s.folder.directory.path).filter { HostControlFolder.requestID($0) != nil }.count, 1)
    }
    // 点検 C: 通知の乱発は読み直しの予約にまとまり、同じ中身の state.json は書き直さない
    func testNotificationsAreCoalescedAndUnchangedStateIsNotRewritten() async throws {
        let (r, s) = make()
        r.start()
        await waitFor(5) { if case .listening = r.diagnostics.listener { return true }; return false }
        s.start()
        await waitFor(10) { s.stateWritten }   // 最初の読み直しが書き終えるまで（回数は読み直しの始めに増える。書く前に数を控えると、書き込みが 1 回多く見える。計画 2g）
        let before = s.counts
        for _ in 0..<100 { s.requestPoll() }
        await waitFor(2) { s.counts.polls >= before.polls + 1 }
        try? await Task.sleep(nanoseconds: 500_000_000)   // 予約が全部さばけるのを待つ（乱発が 1〜2 回にまとまることの確かめ）
        let after = s.counts
        XCTAssertLessThanOrEqual(after.polls - before.polls, 3, "100 回の通知で読み直しは数回に収まる: \(after.polls - before.polls)")
        XCTAssertEqual(after.writes, before.writes, "何も変わっていなければ state.json は書き直さない")
        let mtime = try FileManager.default.attributesOfItem(atPath: s.folder.stateURL.path)[.modificationDate] as? Date
        // 変化 → poll の書き込み 1 回。同じ変化を知らせる onChange（noteChanged）は同じ中身なので書かない
        try put(s, .pause)
        s.poll()
        let afterPause = s.counts
        XCTAssertEqual(afterPause.writes, after.writes + 1)
        s.noteChanged(); s.noteChanged()
        try? await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(s.counts.writes, afterPause.writes, "同じ中身の二重の書き込みは止まる")
        XCTAssertNotEqual(try FileManager.default.attributesOfItem(atPath: s.folder.stateURL.path)[.modificationDate] as? Date, mtime)
        s.stop()
    }
    // 点検 N: フォルダの問題は、同じものが続く間は 1 回だけ記録する。再点検 1: 書けなかった state.json は直った後の読み直しで書き直す
    func testRepeatedFolderProblemsAreLoggedOnce() async throws {
        let (r, s) = make()
        r.start()
        s.poll()   // フォルダを作り、state.json（paused: false）を書く
        XCTAssertEqual(s.folder.readState()?.paused, false)
        chmod(s.folder.directory.path, 0o755)
        r.setPaused(true)   // 中身が変わるので書こうとするが、フォルダが緩いので書けない
        s.poll(); s.poll(); s.poll()
        let folderLines = r.log.recentAll().filter { $0.contains("host-control folder") }
        XCTAssertEqual(folderLines.count, 1, folderLines.joined(separator: "\n"))
        let writeLines = r.log.recentAll().filter { $0.contains("state not written") }
        XCTAssertEqual(writeLines.count, 1, "書き込みの失敗も同じ文言は 1 回だけ: " + writeLines.joined(separator: "\n"))
        XCTAssertEqual(s.lastProblems.count, 1)
        XCTAssertFalse(s.stateWritten); XCTAssertEqual(s.stateHealth, false); XCTAssertEqual(health.value, [true, false], "書けなくなったことを 1 回だけ知らせる（Host のアイコンを出す。点検 2f-2）")
        chmod(s.folder.directory.path, 0o700)
        s.poll()   // 指示は置かない
        XCTAssertEqual(s.lastProblems, [], "直ればすぐ戻る")
        XCTAssertTrue(s.stateWritten); XCTAssertEqual(health.value, [true, false, true])
        XCTAssertEqual(s.folder.readState()?.paused, true, "書けなかった中身は直った後の読み直しで書き直す")
        try put(s, .resume)
        s.poll()
        XCTAssertEqual(s.folder.readState()?.paused, false)
    }
}
