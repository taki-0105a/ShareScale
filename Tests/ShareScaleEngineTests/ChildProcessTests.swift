import XCTest
@testable import ShareScaleEngine

/// 子プロセスの起動と打ち切り、`ChildProcessDisplayProvider` の一覧・適用・netstat（/bin/sh で作った偽物を起動する。
/// 実際のディスプレイの倍率は変えない。CoreGraphics の一覧も差し替える）
final class ChildProcessTests: TempDirTestCase {
    let sh = URL(fileURLWithPath: "/bin/sh")

    func testCapturesOutputAndStatus() {
        let r = ChildProcess.run(sh, ["-c", "printf 'hello'; exit 3"], timeout: 5)
        XCTAssertEqual(r.output, "hello"); XCTAssertEqual(r.status, 3); XCTAssertFalse(r.timedOut); XCTAssertNil(r.launchError)
    }
    func testTimeoutStopsTheChild() {
        let t0 = ContinuousClock.now
        let r = ChildProcess.run(sh, ["-c", "trap '' TERM; exec sleep 30"], timeout: 0.3)
        XCTAssertTrue(r.timedOut); XCTAssertNil(r.status)
        XCTAssertLessThan((ContinuousClock.now - t0).components.seconds, 5, "SIGTERM を無視しても SIGKILL で止める")
    }
    func testMissingExecutable() {
        let r = ChildProcess.run(dir.appendingPathComponent("nope"), [], timeout: 1)
        XCTAssertNotNil(r.launchError); XCTAssertNil(r.status)
    }

    func provider(probe: String, apply: String = "exit 0", netstat: String = "true", inProcess: [DisplaySnapshot] = [],
                  applyTimeout: TimeInterval = 8) -> ChildProcessDisplayProvider {
        let cmd = ChildCommand(executable: sh, probeArguments: ["-c", probe], applyArguments: { _, _ in ["-c", apply] })
        return ChildProcessDisplayProvider(command: cmd, probeTimeout: 2, applyTimeout: applyTimeout, netstat: (sh, ["-c", netstat]),
                                 inProcessList: { inProcess })
    }
    func testListFreshReadsProbeOutput() {
        let text = ProbeOutput.format([virtual(factor: 2), physical()])
        let p = provider(probe: "printf '\(text.replacingOccurrences(of: "\t", with: "\\t").replacingOccurrences(of: "\n", with: "\\n"))'")
        XCTAssertEqual(p.listFresh(), DisplayReading(displays: [virtual(factor: 2), physical()]))
    }
    func testListFreshFallsBackWithReason() {
        XCTAssertEqual(provider(probe: "exit 3", inProcess: [physical()]).listFresh(),
                       DisplayReading(displays: [physical()], fallbackReason: "probe exited 3"))
        XCTAssertEqual(provider(probe: "echo error=usage").listFresh().fallbackReason, "probe output unreadable")
        XCTAssertEqual(provider(probe: "exec sleep 30").listFresh().fallbackReason, "probe timed out after 2s")
    }
    func testApplyReportsChildFailures() {
        XCTAssertNil(provider(probe: "true").apply(uuid: VIRT, factor: 2))
        XCTAssertEqual(provider(probe: "true", apply: "echo 'no 2x mode for 1920x997'; exit 1").apply(uuid: VIRT, factor: 2),
                       "no 2x mode for 1920x997")
        XCTAssertEqual(provider(probe: "true", apply: "exit 4").apply(uuid: VIRT, factor: 2), "apply failed (exit 4)")
        XCTAssertEqual(provider(probe: "true", apply: "exec sleep 30", applyTimeout: 0.3).apply(uuid: VIRT, factor: 2),
                       "apply timed out after 0s (macOS did not complete the display change)")
    }
    func testApplyOutputIsClippedTo256BytesWithoutControls() {
        let long = "bad\u{1B}[31m " + String(repeating: "x", count: 400)
        let out = provider(probe: "true", apply: "printf '%s' '\(long)'; exit 1").apply(uuid: VIRT, factor: 2)
        XCTAssertEqual(out?.utf8.count, 256)
        XCTAssertEqual(out?.prefix(8), "bad[31m ", "制御文字は除く")
    }
    // 版か CDHash の違う子（入れ替えの途中）は何もせずに 75 で終わる。Host は倍率を変えずに待つ（`.updating` を立ててもらう）
    func testApplyExitCode75MeansUpdatingAndDoesNotCountAsAPlainFailure() {
        let seen = Lines()
        let cmd = ChildCommand(executable: sh, probeArguments: ["-c", "true"], applyArguments: { _, _ in ["-c", "exit 75"] })
        let p = ChildProcessDisplayProvider(command: cmd, netstat: (sh, ["-c", "true"]), inProcessList: { [] },
                                            onUpdating: { seen.append("updating") })
        XCTAssertEqual(ChildProcessDisplayProvider.updatingExitCode, 75)
        XCTAssertEqual(p.apply(uuid: VIRT, factor: 2), "ShareScale is being updated; not changing the scale until the new Host starts")
        XCTAssertEqual(seen.all.count, 1)
        XCTAssertEqual(p.apply(uuid: VIRT, factor: 2), "ShareScale is being updated; not changing the scale until the new Host starts")
        XCTAssertEqual(seen.all.count, 2, "見るたびに知らせる（受け手が重複を捨てる）")
        XCTAssertEqual(provider(probe: "true", apply: "exit 4").apply(uuid: VIRT, factor: 2), "apply failed (exit 4)", "ほかの終了コードは今までどおり")
        // probe の 75 も同じ（一覧はプロセスの中のものに切り替える）
        let probeCmd = ChildCommand(executable: sh, probeArguments: ["-c", "exit 75"], applyArguments: { _, _ in ["-c", "true"] })
        let q = ChildProcessDisplayProvider(command: probeCmd, netstat: (sh, ["-c", "true"]), inProcessList: { [physical()] }, onUpdating: { seen.append("probe") })
        XCTAssertEqual(q.listFresh(), DisplayReading(displays: [physical()], fallbackReason: "probe is a different version or build (update in progress)"))
        XCTAssertEqual(seen.all, ["updating", "updating", "probe"])
    }
    func testApplyPassesUUIDAndFactor() {
        let out = dir.appendingPathComponent("args")
        let cmd = ChildCommand(executable: sh, probeArguments: ["-c", "true"],
                               applyArguments: { u, f in ["-c", "echo \"$0 $1\" > '\(out.path)'", u, String(f)] })
        XCTAssertNil(ChildProcessDisplayProvider(command: cmd).apply(uuid: VIRT, factor: 2))
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "\(VIRT) 2\n")
    }
    func testPortSessionIsCachedForMaxAge() {
        let count = dir.appendingPathComponent("count")
        let line = "tcp4       0      0  100.101.77.7.5900     100.101.88.8.56162    ESTABLISHED"
        let p = provider(probe: "true", netstat: "echo x >> '\(count.path)'; echo '\(line)'")
        XCTAssertTrue(p.portSession(maxAge: 0))
        XCTAssertTrue(p.portSession(maxAge: 60))
        XCTAssertEqual(try String(contentsOf: count, encoding: .utf8), "x\n", "60 秒以内は使い回す")
        XCTAssertTrue(p.portSession(maxAge: 0))
        XCTAssertEqual(try String(contentsOf: count, encoding: .utf8), "x\nx\n")
    }
}
