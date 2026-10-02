import AppKit
import ShareScaleEngine
import ShareScaleHostCore
import ShareScaleHostUI

// ShareScale Host の実行体。引数で分岐する（`ChildArguments`）:
// - 引数なし: 常駐（メニューバー。`LSUIElement`）
// - `--probe --version <n> --cdhash <hex>`: ディスプレイの一覧を書き出して終わる（子プロセス）
// - `--apply-once <uuid> <factor> --version <n> --cdhash <hex>`: 倍率を 1 回変えて終わる（子プロセス。8 秒で親が打ち切る）
// 版か CDHash が自分と違えば（入れ替えの途中）、何もせずに 75 で終わる。倍率の変更は子プロセスの中だけで行う（自己待ちの回避）

let invocation = ChildArguments.parse(Array(CommandLine.arguments.dropFirst()))
switch invocation {
case .resident?:
    // 最上位のコードは、厳格な並行性の検査では main actor、通常の組み立てでは非隔離として扱われる。どちらでも通るよう main で動くと明示する
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let controller = HostAppController()   // `app.delegate` は弱い参照。`run()` は戻らないので、この局所変数が持ち続ける
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        app.run()
    }
case let .probe(version, cdhash)?:
    guard ChildArguments.matchesSelf(version: version, cdhash: cdhash, own: SelfIdentity.current()) else { exit(ChildProcessDisplayProvider.updatingExitCode) }
    FileHandle.standardOutput.write(Data(ProbeOutput.format(CoreGraphicsDisplays.list()).utf8))
    exit(0)
case let .applyOnce(uuid, factor, version, cdhash)?:
    guard ChildArguments.matchesSelf(version: version, cdhash: cdhash, own: SelfIdentity.current()) else { exit(ChildProcessDisplayProvider.updatingExitCode) }
    if let e = CoreGraphicsDisplays.apply(uuid: uuid, factor: factor) {
        FileHandle.standardOutput.write(Data((e + "\n").utf8))
        exit(1)
    }
    exit(0)
case nil:
    FileHandle.standardError.write(Data((ChildArguments.usage + "\n").utf8))
    exit(ChildArguments.usageExitCode)
}
