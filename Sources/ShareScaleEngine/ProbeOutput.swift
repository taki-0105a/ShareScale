import Foundation

/// probe の出力（1行1台: uuid 製造元 製品 シリアル 幅x高 実画素幅x実画素高。製造元などは16進）を読み戻す。
/// 常駐エージェントは自分のプロセスの中では新しく現れたディスプレイが見えないことがあるので、
/// 毎回 probe を別プロセスで呼んでその出力を読む
public enum ProbeOutput {
    /// 空の出力は「ディスプレイなし」（[]）。読めない行が1つでもあれば nil（呼び出し側が別の方法に切り替える）
    public static func parse(_ text: String) -> [DisplaySnapshot]? {
        var result: [DisplaySnapshot] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).map(String.init)
            if f.isEmpty { continue }
            guard f.count == 6, let v = UInt32(f[1], radix: 16), let m = UInt32(f[2], radix: 16), let s = UInt32(f[3], radix: 16),
                  let (w, h) = size(f[4]), let (pw, ph) = size(f[5]) else { return nil }
            result.append(DisplaySnapshot(uuid: f[0], vendor: v, model: m, serial: s, width: w, height: h, pixelWidth: pw, pixelHeight: ph))
        }
        return result
    }
    /// `--probe` の出力（`parse` で読み戻せる形。1 行 1 台、欄はタブ区切り）
    public static func format(_ displays: [DisplaySnapshot]) -> String {
        displays.map { d in
            String(format: "%@\t%08x\t%08x\t%08x\t%dx%d\t%dx%d", d.uuid, d.vendor, d.model, d.serial,
                   d.width, d.height, d.pixelWidth, d.pixelHeight) + "\n"
        }.joined()
    }
    private static func size(_ s: String) -> (Int, Int)? {
        let p = s.split(separator: "x", omittingEmptySubsequences: false)
        guard p.count == 2, let a = Int(p[0]), let b = Int(p[1]) else { return nil }
        return (a, b)
    }
}
