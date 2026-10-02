import ColorSync
import CoreGraphics
import Foundation

/// CoreGraphics でディスプレイを読み書きする。
/// Host の実行体（計画 2c-2）が `--probe`・`--apply-once` の子プロセスの中で呼ぶ。常駐のプロセスの中では呼ばない
/// （常駐のプロセスの中の一覧は古いことがあり、同じプロセスで倍率を変えると画面構成の変化の通知を待って止まるため）
public enum CoreGraphicsDisplays {
    private static func onlineIDs() -> [CGDirectDisplayID] {
        var n: UInt32 = 0; CGGetOnlineDisplayList(0, nil, &n)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n)); CGGetOnlineDisplayList(n, &ids, &n)
        return Array(ids.prefix(Int(n)))
    }
    private static func uuid(_ id: CGDirectDisplayID) -> String? {
        guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, u) as String
    }
    /// 今のディスプレイの一覧（読み取りだけ）
    public static func list() -> [DisplaySnapshot] {
        onlineIDs().compactMap { id in
            guard let u = uuid(id), let m = CGDisplayCopyDisplayMode(id) else { return nil }
            return DisplaySnapshot(uuid: u, vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                                   serial: CGDisplaySerialNumber(id), width: m.width, height: m.height,
                                   pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight)
        }
    }
    /// 同じ作業領域・同じリフレッシュレートで、実画素だけ factor 倍のモードにする。失敗なら理由
    public static func apply(uuid target: String, factor: Int) -> String? {
        guard let id = onlineIDs().first(where: { uuid($0) == target }), let cur = CGDisplayCopyDisplayMode(id)
        else { return "display not found" }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
        let same = modes.filter { $0.width == cur.width && $0.height == cur.height &&
                                  $0.pixelWidth == cur.width * factor && $0.isUsableForDesktopGUI() }
        guard let mode = same.first(where: { $0.refreshRate == cur.refreshRate }) ?? same.first
        else { return "no \(factor)x mode for \(cur.width)x\(cur.height)" }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return "begin configuration failed" }
        CGConfigureDisplayWithDisplayMode(cfg, id, mode, nil)
        let err = CGCompleteDisplayConfiguration(cfg, .forSession)
        return err == .success ? nil : "apply failed (CGError \(err.rawValue))"
    }
}

/// 子プロセスを 1 つ動かして終わりを待つ（打ち切りあり）
public enum ChildProcess {
    public struct Result: Equatable, Sendable {
        public var status: Int32?         // 終了コード（起動できない・打ち切った時は nil）
        public var output: String         // 標準出力
        public var timedOut = false
        public var launchError: String?
    }

    /// 出力は別のスレッドで先に読み切る（終了待ちを先にすると、出力が大きい時に互いに待ち合って止まる）。
    /// `timeout` 秒で終わらなければ SIGTERM、0.5 秒後も残っていれば SIGKILL で止め、終わるのを待ってから返す（出力は読めた分だけ）
    public static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval,
                           environment: [String: String]? = nil) -> Result {
        let p = Process()
        p.executableURL = executable; p.arguments = arguments
        if let environment { p.environment = environment }
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Result(status: nil, output: "", launchError: ErrorText.readable(error)) }
        let data = Collected()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { data.set(pipe.fileHandleForReading.readDataToEndOfFile()); done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            if done.wait(timeout: .now() + 0.5) == .timedOut, p.isRunning { kill(p.processIdentifier, SIGKILL) }
            p.waitUntilExit()
            // 孫のプロセスが出力の管を持ち続けていると読み終わらないので、1 秒待って読み終わらなければ管を閉じる（読み取りのスレッドはそこで終わる）
            if done.wait(timeout: .now() + 1) == .timedOut { try? pipe.fileHandleForReading.close() }
            return Result(status: nil, output: String(decoding: data.value, as: UTF8.self), timedOut: true)
        }
        p.waitUntilExit()
        return Result(status: p.terminationStatus, output: String(decoding: data.value, as: UTF8.self))
    }

    private final class Collected: @unchecked Sendable {   // 読み取りのスレッドから 1 回だけ書く（lock で守る）
        private let lock = NSLock()
        private var d = Data()
        func set(_ x: Data) { lock.withLock { d = x } }
        var value: Data { lock.withLock { d } }
    }
}

/// 子プロセスの起動の仕方（計画 2c-2 の実行体が自分のパスと `--probe`・`--apply-once` の引数を渡す）
public struct ChildCommand: Sendable {
    public var executable: URL
    public var probeArguments: [String]
    public var applyArguments: @Sendable (_ uuid: String, _ factor: Int) -> [String]
    public var environment: [String: String]?
    public init(executable: URL, probeArguments: [String], applyArguments: @escaping @Sendable (String, Int) -> [String],
                environment: [String: String]? = nil) {
        self.executable = executable; self.probeArguments = probeArguments; self.applyArguments = applyArguments; self.environment = environment
    }
}

/// 実物の `DisplayProvider`: 一覧は子プロセス（probe）で読み、倍率は子プロセス（apply-once）で変える。
/// netstat の結果は `maxAge` 秒まで使い回す。可変の状態（netstat の結果の写し）は `lock` で守る。
/// `--apply-once` の子が `updatingExitCode`（75）で終わったら（入れ替えの途中で、バンドルのパスにある子が自分と違う版）、
/// `onUpdating` で知らせる（受け手は `ScaleMaintainer.setHold(.updating, true)` を呼ぶ。以後は倍率を変えない）
public final class ChildProcessDisplayProvider: DisplayProvider, @unchecked Sendable {
    /// 版か CDHash が親と違う子が、何もせずに終わる時の終了コード（仕様「入れ替えの途中で動き続ける旧版の Host」。以後の版で変えない）
    public static let updatingExitCode: Int32 = 75
    public let command: ChildCommand
    public let probeTimeout: TimeInterval
    public let applyTimeout: TimeInterval
    private let netstat: (URL, [String])
    private let inProcessList: @Sendable () -> [DisplaySnapshot]
    private let now: @Sendable () -> TimeInterval
    private let onUpdating: @Sendable () -> Void
    private let lock = NSLock()
    private var portCache: (at: TimeInterval, value: Bool)?

    /// - `inProcessList`: 子プロセスで読めない時に使う、プロセスの中の一覧（試験で差し替える）
    /// - `netstat`: 画面共有の接続を調べるコマンド（試験で差し替える）
    /// - `onUpdating`: 子（probe・apply-once のどちらも）が 75 で終わった（見るたびに呼ぶ。`listFresh`・`apply` を呼んだスレッドから）
    public init(command: ChildCommand, probeTimeout: TimeInterval = 3, applyTimeout: TimeInterval = 8,
                netstat: (URL, [String]) = (URL(fileURLWithPath: "/usr/sbin/netstat"), ["-an", "-p", "tcp"]),
                inProcessList: @escaping @Sendable () -> [DisplaySnapshot] = { CoreGraphicsDisplays.list() },
                now: @escaping @Sendable () -> TimeInterval = { ScaleMaintainer.monotonicNow() },
                onUpdating: @escaping @Sendable () -> Void = {}) {
        self.command = command; self.probeTimeout = probeTimeout; self.applyTimeout = applyTimeout
        self.netstat = netstat; self.inProcessList = inProcessList; self.now = now; self.onUpdating = onUpdating
    }

    public func listFresh() -> DisplayReading {
        let r = ChildProcess.run(command.executable, command.probeArguments, timeout: probeTimeout, environment: command.environment)
        let failure: String
        if let e = r.launchError { failure = "could not start probe: \(e)" }
        else if r.timedOut { failure = "probe timed out after \(Int(probeTimeout))s" }
        else if r.status == Self.updatingExitCode { onUpdating(); failure = "probe is a different version or build (update in progress)" }
        else if r.status != 0 { failure = "probe exited \(r.status ?? -1)" }
        else if let d = ProbeOutput.parse(r.output) { return DisplayReading(displays: d) }
        else { failure = "probe output unreadable" }
        return DisplayReading(displays: inProcessList(), fallbackReason: failure)
    }

    public func apply(uuid: String, factor: Int) -> String? {
        let r = ChildProcess.run(command.executable, command.applyArguments(uuid, factor), timeout: applyTimeout, environment: command.environment)
        if let e = r.launchError { return "could not start apply: \(e)" }
        if r.timedOut { return "apply timed out after \(Int(applyTimeout))s (macOS did not complete the display change)" }
        if r.status == 0 { return nil }
        if r.status == Self.updatingExitCode {
            onUpdating()
            return "ShareScale is being updated; not changing the scale until the new Host starts"
        }
        let out = Self.clip(r.output.trimmingCharacters(in: .whitespacesAndNewlines))
        return out.isEmpty ? "apply failed (exit \(r.status ?? -1))" : out
    }

    /// 子プロセスの出力を `last_error` に入れる前に、制御文字（Cc・Cf・Zl・Zp）を除き UTF-8 で 256 バイトに切り詰める
    /// （`ShareScaleProtocol.TextRules.clip` と同じ規則。このターゲットは Protocol に依存しないので写す）
    static func clip(_ s: String, maxBytes: Int = 256) -> String {
        var out = String.UnicodeScalarView()
        var bytes = 0
        for u in s.unicodeScalars {
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: continue
            default: break
            }
            let len = UTF8.width(u)
            guard bytes + len <= maxBytes else { break }
            out.append(u); bytes += len
        }
        return String(out)
    }

    public func portSession(maxAge: TimeInterval) -> Bool {
        if let c = lock.withLock({ portCache }), now() - c.at < maxAge { return c.value }
        let r = ChildProcess.run(netstat.0, netstat.1, timeout: 5)
        let v = ScreenSharingDetector.hasIncomingSession(netstatOutput: r.output)
        lock.withLock { portCache = (now(), v) }
        return v
    }
}
