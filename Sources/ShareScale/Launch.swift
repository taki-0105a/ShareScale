import AppKit
import Darwin
import Foundation
import ShareScaleCore
import ShareScaleHostCore

/// 起動の入り口。見る側の窓（SwiftUI）を作る前に、起動した場所で役を決める（仕様「`~/Applications` への複製と引き渡し」）。
/// - Homebrew 側: 引き渡しの条件を確かめ、複製を作る・置き換える・開くだけを行って終了する（窓を出さない）
/// - それ以外の場所: 案内して終了する（複製を開ける時は、既定のボタンで複製を開いてから終了する。計画 2h）
/// - 複製: 複製元（Homebrew 側）が新しければ、試みを記録してから Homebrew 側を開いて終了する。そうでなければ見る側として動く
/// - 開発の組み立て（`--dev`）・バンドルの外（`swift run`）: 見る側として動く
@main
enum Entry {
    @MainActor static func main() {
        let info = Bundle.main.infoDictionary
        let bundlePath = AppLocation.realPath(Bundle.main.bundlePath) ?? Bundle.main.bundlePath
        let home = AppLocation.realPath(NSHomeDirectory()) ?? NSHomeDirectory()
        // バンドルの外（`swift run ShareScale`）は識別子が無い。開発の組み立てと同じに扱う
        let development = AppLocation.isDevelopmentBuild(info) || Bundle.main.bundleIdentifier == nil
        let role = AppLocation.classify(bundlePath: bundlePath, home: home, isDevelopmentBuild: development)
        switch role {
        case let .homebrew(h):
            LaunchFlow.homebrew(h)
        case .elsewhere:
            LaunchFlow.elsewhere()
        case .copy:
            LaunchContext.copyLaunch = LaunchFlow.copyLaunch()
        case .development:
            break
        }
        LaunchContext.role = role
        ShareScaleApp.main()
    }
}

/// 見る側として動く時に、組み立て（`ViewerApp`）へ渡す起動時の判定
@MainActor
enum LaunchContext {
    static var role: AppRole = .development
    static var copyLaunch: (decision: Handoff.CopyLaunch, stateProblem: String?) = (.nothing, nil)
}

/// 窓を出す前の流れ（AppKit の確かめの窓だけ）
@MainActor
enum LaunchFlow {
    static var ownFacts: BundleFacts {
        BundleFacts(identifier: Bundle.main.bundleIdentifier, version: SelfIdentity.bundleVersion(), cdhash: SelfIdentity.codeHash())
    }

    /// Homebrew 側が開かれた: 条件を確かめ、複製を作る・置き換える・開いて終了する（見る側としては動かない）
    static func homebrew(_ h: HomebrewBundle) -> Never {
        let paths = AppPaths.standard()
        if let p = HandoffSafety.check(bundle: h.realPath, uid: geteuid(), reader: SystemFileFacts()) {
            alert(tr("ShareScale を ~/Applications にコピーできません", "Can’t copy ShareScale to ~/Applications"), HandoffSafety.message, copyable: p.detail)
            exit(1)
        }
        let own = ownFacts
        let plan = Handoff.plan(copy: CopyFacts.read(paths.copy), own: own)
        switch plan {
        case let .abort(problem):
            alert(tr("ShareScale を ~/Applications にコピーできません", "Can’t copy ShareScale to ~/Applications"), problem.message)
            exit(1)
        case .create, .replace:
            let cdhash = own.cdhash ?? ""   // `Handoff.plan` は署名を読めなければ `.abort(.unsigned)` を返すので、ここでは必ずある
            let source = URL(fileURLWithPath: h.realPath, isDirectory: true)
            let result = runBlocking(timeout: 120) {
                await AppInstaller.install(plan, source: source, copy: paths.copy, ownCDHash: cdhash, ports: InstallerPorts(terminateRunningCopy: RunningCopies.terminate))
            }
            switch result {
            case .success?: break
            case let .failure(f)?:
                alert(tr("ShareScale を ~/Applications にコピーできませんでした", "Couldn’t copy ShareScale to ~/Applications"), f.message, copyable: f.detail)
                exit(1)
            case nil:
                alert(tr("ShareScale を ~/Applications にコピーできませんでした", "Couldn’t copy ShareScale to ~/Applications"),
                      tr("時間がかかりすぎたため、中止しました。もう一度開いてください。", "It took too long and was stopped. Open ShareScale again."))
                exit(1)
            }
        case .openCopy:
            break
        }
        // 複製元を記録する（版に依らない場所）。記録できなくても複製は開く（自動の引き渡しが起きないだけ）
        try? AppStateFile(url: paths.appState).update { $0.source = h.optPath }
        // 置き換えなかった複製が動いていれば、開き直しを頼むだけ（もう 1 つ起動しない。点検 C）。動いていなければ新しい実体として開く
        // 見つかれば前に出せたかに依らず終了する（2 つ目の実体を開かない。再点検 軽微 1）
        if plan == .openCopy, !RunningCopies.find(paths.copy).isEmpty {
            _ = RunningCopies.run(AppLocation.reopenRunningCopySteps, paths.copy)
            exit(0)
        }
        guard open(paths.copy) else {
            alert(tr("~/Applications の ShareScale を開けませんでした", "Couldn’t open ShareScale in ~/Applications"),
                  tr("Finder で ~/Applications/ShareScale.app を開いてください。", "Open ~/Applications/ShareScale.app in Finder."))
            exit(1)
        }
        exit(0)
    }

    /// それ以外の場所（組み立て用のフォルダなど）から開かれた: 案内して終了する（見る側としては動かない）。
    /// 複製を開ける時（`AppLocation.canOpenCopy`）は、既定のボタン「~/Applications の ShareScale を開く」で複製を開いてから終了する（計画 2h）。
    /// 判断（ボタンを付けるか・押した後に何をするか・押した時の確かめ直し）は `AppLocation` の純粋な関数で、ここは並べるだけ。
    /// 複製を作る・置き換える・記録を書くことはしない
    static func elsewhere() -> Never {
        let copy = AppPaths.standard().copy
        let home = AppLocation.realPath(NSHomeDirectory()) ?? NSHomeDirectory()
        let g = AppLocation.elsewhereGuidance(copy: CopySnapshot.read(copy), home: home, ownVersion: SelfIdentity.bundleVersion())
        let pressed = alert(g.title, g.detail, primary: g.openCopyTitle)
        let action = AppLocation.elsewhereAction(pressed: pressed, home: home, recheck: { CopySnapshot.read(copy) },
                                                 copyRunning: { !RunningCopies.find(copy).isEmpty })
        switch action {
        case .quit:
            exit(0)
        case .reopenRunningCopy, .launchCopy:
            // 開き方の並びは `AppLocation.openAttempts`（開き直しを頼めなければ、新しく開く。どれも駄目なら下の案内）
            for steps in AppLocation.openAttempts(for: action) where RunningCopies.run(steps, copy) { exit(0) }
            fallthrough
        case .cannotOpen:
            alert(tr("~/Applications の ShareScale を開けませんでした", "Couldn’t open ShareScale in ~/Applications"),
                  tr("Finder で ~/Applications/ShareScale.app を開いてください。", "Open ~/Applications/ShareScale.app in Finder."))
            exit(1)
        }
    }

    /// 複製が起動した: 複製元の様子から、引き渡すか・問いかけるか・診断に出すかを決める。引き渡すなら試みを記録してから開いて終了する
    static func copyLaunch() -> (decision: Handoff.CopyLaunch, stateProblem: String?) {
        let file = AppStateFile(url: AppPaths.standard().appState)
        let loaded = file.load()
        // 複製元は 1 回だけ解決し、Homebrew の形か・条件を確かめたその実体のパスを開く（点検 D）
        let source = loaded.state.source.map(Handoff.readSource)
        let decision = Handoff.copyLaunch(state: loaded.state, source: source, own: ownFacts) { real in
            HandoffSafety.check(bundle: real, uid: geteuid(), reader: SystemFileFacts())
        }
        if case let .handoff(attempt, real) = decision {
            // 試みをディスクに記録してから開く（同じものへは 1 回だけ）。記録できなければ引き渡さない（繰り返しを防げないため）
            do {
                try file.update { $0.attemptedHandoff = attempt }
                if open(URL(fileURLWithPath: real, isDirectory: true)) { exit(0) }
            } catch {}
            return (.alreadyAttempted, loaded.problem)
        }
        return (decision, loaded.problem)
    }

    /// アプリを新しい実体として開く（同じ識別子のアプリが動いていても、前に出すだけにしない）。開けたら真。
    /// `newInstance` が偽なら、その場所のアプリが動いている時に新しく起動せず、開き直しを頼む（`AppLocation.reopenRunningCopySteps`）
    static func open(_ app: URL, newInstance: Bool = true) -> Bool {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = newInstance
        config.activates = true
        let done = Box<Bool?>(nil)
        NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in done.value = (error == nil) }
        let end = Date().addingTimeInterval(15)
        while done.value == nil, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return done.value == true
    }

    /// 確かめの窓（窓を出す前なので NSAlert）。`copyable` があれば「詳細をコピー」。
    /// `primary` があれば、それを既定のボタン（Return）にして「終了」（Esc）の前に置く。押されたボタンを返す（並びと読み方は `LaunchAlertLayout`。計画 2h）
    @discardableResult
    static func alert(_ title: String, _ detail: String, copyable: String? = nil, primary: String? = nil) -> LaunchAlertButton {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = detail
        let layout = LaunchAlertLayout(hasPrimary: primary != nil, hasCopyable: copyable != nil)
        for button in layout.buttons {
            switch button {
            case .primary: a.addButton(withTitle: primary ?? "")
            case .quit:
                let quit = a.addButton(withTitle: tr("終了", "Quit"))
                if layout.quitTakesEscape { quit.keyEquivalent = "\u{1b}" }
            case .copy: a.addButton(withTitle: tr("詳細をコピー", "Copy Details"))
            }
        }
        bringToFront(a.window)
        let pressed = layout.pressed(a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
        if pressed == .copy, let c = copyable {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(c, forType: .string)
        }
        return pressed
    }

    /// 案内のウインドウを前面に出す（計画 2h。実機確認 A: ほかのアプリのウインドウの後ろに隠れ、利用者が気づかないまま `runModal` で待っていた）。
    /// 起動の入り口では `NSApplication.run` を回していないので、`activate()` だけではアプリが前面にならないことがある。
    /// ウインドウを手前の階層（`.floating`。Host の確認のウインドウと同じ）にして、ほかのアプリの前でも見えるようにし、
    /// モーダルが始まった直後（`runModal` がウインドウを出した後）にも、もう一度手前に出して前面のアプリにする。
    /// 後追いの処理は、ウインドウが見えている時だけ行う（もう閉じたウインドウを出し直さない。点検 2h）
    static func bringToFront(_ window: NSWindow) {
        window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            guard window.isVisible else { return }
            window.level = .floating
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 非同期の処理を、主スレッドの実行ループを回しながら待つ（最大 `timeout` 秒。過ぎたら nil）
    static func runBlocking<T: Sendable>(timeout: Double, _ op: @escaping @Sendable () async -> T) -> T? {
        let box = Box<T?>(nil)
        Task.detached { box.value = await op() }
        let end = Date().addingTimeInterval(timeout)
        while box.value == nil, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return box.value
    }
}

/// 動いている複製（同じ識別子で、自分以外、バンドルの実体が複製のもの）
enum RunningCopies {
    static func find(_ copy: URL) -> [NSRunningApplication] {
        let target = AppLocation.realPath(copy.path) ?? copy.path
        return NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentifiers.app).filter {
            $0.processIdentifier != getpid() && !$0.isTerminated && $0.bundleURL.flatMap { AppLocation.realPath($0.path) } == target
        }
    }

    /// 複製を開く手順（`CopyOpenStep`。並びは `AppLocation` の純粋な値）を、順に行う。開く手が失敗したら偽。
    /// 動いている複製への開き直し（`AppLocation.reopenRunningCopySteps`）: 前に出すだけ（`activate()`）では、複製が主の窓を閉じて
    /// メニューバーにだけ居る時に、何も出ない（点検 2h）。Finder や Dock から開いた時と同じく `NSWorkspace.openApplication(at:)` で、
    /// 新しい実体を作らずに開く: 動いているアプリには「開き直し」の知らせが届き、複製の `applicationShouldHandleReopen` が、窓が無ければ主の窓を開く。
    /// 知らせが届くことは実機でしか確かめられない。届かなくても、前に出すところまでは今までどおり
    @MainActor static func run(_ steps: [CopyOpenStep], _ copy: URL) -> Bool {
        var opened = true
        for step in steps {
            switch step {
            case .activateRunning: find(copy).forEach { _ = $0.activate() }
            case let .open(newInstance): if !LaunchFlow.open(copy, newInstance: newInstance) { opened = false }
            }
        }
        return opened
    }

    /// 終了を頼み、終わるまで待つ（最大 `timeout` 秒）
    @Sendable static func terminate(_ copy: URL, _ timeout: Double) async -> Bool {
        let apps = find(copy)
        let pids = apps.map(\.processIdentifier)
        apps.forEach { _ = $0.terminate() }
        var waited = 0.0
        while pids.contains(where: { kill($0, 0) == 0 || errno == EPERM }) {
            if waited >= timeout { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        return true
    }
}

/// ロックで守った値（起動の流れの中で、別のスレッドの結果を受ける）
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T {
        get { lock.withLock { v } }
        set { lock.withLock { v = newValue } }
    }
}
