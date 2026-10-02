import Darwin
import XCTest
@testable import ShareScaleEngine
@testable import ShareScaleHostCore
import ShareScaleNet
import ShareScaleProtocol

/// host-control の書き手（ShareScale.app 側。一時フォルダ。通知は数えるだけで送らない）
final class HostControlClientTests: TempDirTestCase {
    var folder: HostControlFolder { HostControlFolder(directory: dir.appendingPathComponent("support/host-control", isDirectory: true)) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func client(alive: @escaping @Sendable (pid_t) -> Bool = { _ in true }, notified: Locked<Int> = Locked(0)) -> HostControlClient {
        HostControlClient(folder: folder, notify: { notified.update { $0 += 1 } }, wallClock: { [now] in now }, isAlive: alive)
    }

    func testSendWritesTheRequestAndNotifies() throws {
        let notified = Locked(0)
        let c = client(notified: notified)
        try c.pause(); try c.unpair(pid(1)); try c.setAllowGlobal(true); try c.issueCode(); try c.snooze(pid(2)); try c.setTailscaleOnly(false); try c.resume(); try c.quit()
        try c.showCode(); try c.showDiagnostics()
        XCTAssertEqual(notified.value, 10, "置くたびに通知する")
        let r = folder.readRequests(now: Int64(now.timeIntervalSince1970))
        XCTAssertEqual(r.problems, []); XCTAssertEqual(r.dropped, 0)
        XCTAssertEqual(Set(r.requests.map(\.op)), Set(HostControlOp.allCases), "すべての操作が形どおりに置ける")
        XCTAssertTrue(r.requests.allSatisfy { $0.at == 1_800_000_000 })
        XCTAssertEqual(r.requests.first { $0.op == .unpair }?.id, pid(1)); XCTAssertEqual(r.requests.first { $0.op == .setAllowGlobal }?.value, true)
        var st = stat(); XCTAssertEqual(stat(folder.directory.path, &st), 0); XCTAssertEqual(st.st_mode & 0o777, 0o700, "フォルダは 700")
        XCTAssertThrowsError(try c.send(.unpair)) { XCTAssertEqual($0 as? HostControlClient.Error, .invalidRequest) }
        XCTAssertThrowsError(try c.send(.pause, value: true)) { XCTAssertEqual($0 as? HostControlClient.Error, .invalidRequest) }
        XCTAssertEqual(notified.value, 10, "置けなければ通知しない")
    }

    func testHostStateUsesPidLivenessNotUpdated() throws {
        let alive = Locked<Set<pid_t>>([42])
        let c = client(alive: { alive.value.contains($0) })
        XCTAssertEqual(c.hostState(), .notRunning(last: nil), "state.json が無い")
        XCTAssertNotNil(HostControlClient.notRunningGuidance(.notRunning(last: nil), language: .ja))
        var d = HostDiagnostics(); d.listener = .listening(port: 47651)
        func state(pid: Int64, running: Bool, updated: Int64) -> HostControlState {
            HostControlState(pid: pid, version: "1.1.0", build: 10100, running: running, paused: false, listener: d.listener, pairings: [],
                             codeExpires: nil, host: d, system: SystemDiagnostics(), updated: updated)
        }
        try folder.writeState(state(pid: 42, running: true, updated: 1))
        let s = c.hostState()
        XCTAssertTrue(s.isRunning); XCTAssertEqual(s.summary?.pid, 42); XCTAssertEqual(s.summary?.port, 47651)
        XCTAssertNil(HostControlClient.notRunningGuidance(s, language: .ja), "updated が古くても pid が生きていれば動いている")
        alive.value = []
        let dead = c.hostState()
        XCTAssertEqual(dead.isRunning, false); XCTAssertEqual(dead.summary?.pid, 42, "最後の状態は読める")
        XCTAssertTrue(HostControlClient.notRunningGuidance(dead, language: .en)?.contains("Login Items") == true)
        alive.value = [42]
        try folder.writeState(state(pid: 42, running: false, updated: 2))
        XCTAssertEqual(c.hostState().isRunning, false, "running が偽なら止まっている")
        try folder.writeState(state(pid: -1, running: true, updated: 3))
        XCTAssertEqual(c.hostState().isRunning, false, "形の外の pid は生きていない")
        chmod(folder.stateURL.path, 0o644)
        XCTAssertEqual(c.hostState(), .unknown(problem: "state.json: loosePermissions"), "読めない state.json は理由付きで「分からない」")
        XCTAssertTrue(HostControlClient.notRunningGuidance(.unknown(problem: "x"), language: .ja)!.contains("アクセス権"))
        chmod(folder.stateURL.path, 0o600)
        try Data("{".utf8).write(to: folder.stateURL)
        XCTAssertEqual(c.hostState(), .unknown(problem: "state.json: malformed"))
        unlink(folder.stateURL.path)
        XCTAssertEqual(c.hostState(), .notRunning(last: nil), "無ければ「動いていない」")
    }

    func testRealHostProcessesTheRequest() async throws {
        // 書き手 → フォルダ → Host の受け渡しの本体（通知は送らず、読み直しを直接呼ぶ）
        var conf = HostRuntime.Configuration(supportDirectory: dir.appendingPathComponent("support", isDirectory: true), logDirectory: nil, machine: "MAC-TEST")
        conf.port = listenPortForTests(); conf.listenScope = .loopbackOnly; conf.engine.coalesceDelay = 0.02; conf.engine.checkInterval = 3600
        let runtime = HostRuntime(configuration: conf, displays: FakeDisplays([virtualDisplay(factor: 2)]), approver: FakeApprover(), identity: HostIdentity(name: { "S" }, model: { "M" }),
                                  readAddresses: { [] }, localHostName: { "studio" })
        runtime.start(); defer { runtime.stop() }
        await waitFor(5) { if case .listening = runtime.diagnostics.listener { return true }; return false }
        let service = HostControlService(folder: folder, runtime: runtime, version: "1.1.0", build: 10100, pollInterval: 3600, wallClock: { Date() })
        service.start(); defer { service.stop() }
        // 最初の読み直しが `state.json` を書き終えるのを待つ。読み直しの回数（`counts.polls`）は読み直しの始めに増えるので、
        // それを待つだけだと、負荷の下では書く前に読んで「動いていない」になる（計画 2g）
        await waitFor(10) { service.stateWritten }
        XCTAssertTrue(service.stateWritten, "最初の読み直しで state.json を書く")
        let c = HostControlClient(folder: folder, notify: { service.requestPoll() })
        XCTAssertTrue(c.hostState().isRunning, "動いている Host の state.json は pid が生きている")
        try c.pause()
        await waitFor(10) { runtime.diagnostics.paused }
        XCTAssertTrue(runtime.diagnostics.paused, "通知で読み直され、処理される")
        await waitFor(10) { c.hostState().summary?.paused == true }
        XCTAssertEqual(c.hostState().summary?.paused, true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.directory.path).filter { $0.hasPrefix("request-") }, [], "処理した指示は消える")
    }
}
