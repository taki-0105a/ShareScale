import Foundation

public enum Mode: String, Equatable, Sendable { case oneX = "1x", twoX = "2x", off }

public enum ErrorCode: String, Equatable, Sendable {
    case badRequest = "bad_request", unsupportedVersion = "unsupported_version", paused, busy, notPaired = "not_paired"
}

/// 接続の最初の指示に付ける照合用の値
public struct Auth: Equatable, Sendable {
    public let id: PairingID
    public let proof: Bytes32
    public init(id: PairingID, proof: Bytes32) { self.id = id; self.proof = proof }
}

public enum Request: Equatable, Sendable {
    case hello(name: String, commitment: Bytes32)   // 最初の指示
    case reveal(random: Bytes32)                     // 名乗りの 2 つ目の指示（id・proof なし）
    case status, set(Mode), log, unpair           // 最初の指示

    var op: String {
        switch self {
        case .hello: return "hello"
        case .reveal: return "reveal"
        case .status: return "status"
        case .set: return "set"
        case .log: return "log"
        case .unpair: return "unpair"
        }
    }

    /// 接続の最初の指示として送る 1 行（改行で終わる。照合用の値を付ける）。次の時は nil
    /// - `.reveal`（最初の指示にできない）
    /// - `.hello` の名前が `NameRules.validate` を通らない（Host が拒否するため）。名前は送る前に `NameRules.sanitize` を通すこと。
    ///   ここでは整えない（整えると前後の空白が変わり、読んだ指示を書き出し直すと同じになる性質が崩れるため）
    public func encodedAsFirst(auth: Auth) -> Data? {
        switch self {
        case .reveal: return nil
        case let .hello(name, _) where NameRules.validate(name) == nil: return nil
        default: return line(auth: auth)
        }
    }

    /// 名乗りと同じ接続で続けて送る 1 行（照合用の値は付けない）。`.reveal` 以外は nil
    public func encodedAsReveal() -> Data? {
        guard case .reveal = self else { return nil }
        return line(auth: nil)
    }

    private func line(auth: Auth?) -> Data {
        var m: [(String, JSONValue)] = [("v", .integer(1)), ("op", .string(op))]
        switch self {
        case let .hello(name, c): m += [("name", .string(name)), ("c", .string(c.base64URL))]
        case let .reveal(r): m += [("r", .string(r.base64URL))]
        case let .set(mode): m += [("mode", .string(mode.rawValue))]
        case .status, .log, .unpair: break
        }
        if let a = auth { m += [("id", .string(a.id.hex)), ("proof", .string(a.proof.base64URL))] }
        return Data((JSONWriter.write(.object(m)) + "\n").utf8)
    }
}

/// 指示の種類（記録と結末に使う。名前は `op` と同じ）
extension Request {
    public enum Kind: String, Sendable { case hello, reveal, status, set, log, unpair }
    public var kind: Kind {
        switch self {
        case .hello: return .hello
        case .reveal: return .reveal
        case .status: return .status
        case .set: return .set
        case .log: return .log
        case .unpair: return .unpair
        }
    }
}

/// Host の読み取り（2 段）。1 段目で切断・版違い・照合用の値を決め、照合に成功した後で 2 段目の中身を確かめる
public enum RequestReader: Sendable {
    /// 応答せずに切断する理由（記録に使う）
    public enum DropReason: String, Equatable, Sendable {
        case badJSON = "bad_json", notObject = "not_object", noVersion = "no_version"
    }

    public enum Envelope: Equatable, Sendable {
        case drop(DropReason)        // 応答せずに切断する
        case unsupportedVersion      // `unsupported_version` を返す
        case notPaired               // 最初の指示なのに照合用の値が無い・形が違う
        case ready(auth: Auth?, body: JSONValue)
    }

    /// `line` は `LineFraming` で取り出した改行なしの 1 行
    public static func open(_ line: Data, first: Bool) -> Envelope {
        guard let v = try? StrictJSON.parse(line) else { return .drop(.badJSON) }
        guard let m = v.members() else { return .drop(.notObject) }
        guard case let .integer(version)? = m["v"] else { return .drop(.noVersion) }
        guard version == 1 else { return .unsupportedVersion }
        guard first else { return .ready(auth: nil, body: v) }
        guard case let .string(hex)? = m["id"], let id = PairingID(hex: hex),
              case let .string(p)? = m["proof"], let proof = Bytes32(base64URL: p) else { return .notPaired }
        return .ready(auth: Auth(id: id, proof: proof), body: v)
    }

    /// 照合に成功した後に呼ぶ。規則に合わなければ nil（`bad_request`）
    public static func request(_ body: JSONValue, first: Bool) -> Request? {
        guard case let .string(op)? = body.members()?["op"] else { return nil }
        // 決まったキー（v・op と、最初の指示なら id・proof）に、指示ごとの項目を足した集合とちょうど一致すること
        let envelope: Set<String> = first ? ["v", "op", "id", "proof"] : ["v", "op"]
        func fields(_ keys: Set<String>) -> [String: JSONValue]? { body.exactKeys(envelope.union(keys)) }
        func bytes32(_ v: JSONValue?) -> Bytes32? {
            guard case let .string(s)? = v else { return nil }
            return Bytes32(base64URL: s)
        }
        switch (op, first) {
        case ("hello", true):
            guard let m = fields(["name", "c"]), case let .string(raw)? = m["name"], let name = NameRules.validate(raw),
                  let c = bytes32(m["c"]) else { return nil }
            return .hello(name: name, commitment: c)
        case ("reveal", false):
            guard let m = fields(["r"]), let r = bytes32(m["r"]) else { return nil }
            return .reveal(random: r)
        case ("status", true): return fields([]) != nil ? .status : nil
        case ("log", true): return fields([]) != nil ? .log : nil
        case ("unpair", true): return fields([]) != nil ? .unpair : nil
        case ("set", true):
            guard let m = fields(["mode"]), case let .string(s)? = m["mode"], let mode = Mode(rawValue: s) else { return nil }
            return .set(mode)
        default: return nil
        }
    }
}

public struct StatusPayload: Equatable, Sendable {
    public struct VirtualDisplay: Equatable, Sendable {
        public enum Scaling: String, Equatable, Sendable { case oneX = "1x", twoX = "2x" }
        /// 仮想ディスプレイをどう見分けたか（識別情報・予備の方法）
        public enum DisplaySource: String, Equatable, Sendable { case signature, learned }

        public let resolution: String   // 例 "1920x997"（`^[0-9]{1,5}x[0-9]{1,5}$`。StatusPayload を作る時に確かめる）
        public let scaling: Scaling
        public let source: DisplaySource
        public init(resolution: String, scaling: Scaling, source: DisplaySource) { self.resolution = resolution; self.scaling = scaling; self.source = source }
    }
    public struct SetBy: Equatable, Sendable {
        public let byYou: Bool
        public let at: Int64   // UNIX 秒（0 以上。StatusPayload を作る時に確かめる）
        public init(byYou: Bool, at: Int64) { self.byYou = byYou; self.at = at }
    }
    public let name: String, model: String
    public let paused: Bool, session: Bool
    public let mode: Mode
    public let virtualDisplay: VirtualDisplay?
    public let ambiguous: Bool
    public let lastError: String?
    public let setBy: SetBy?
    public let port: Int
    public let addresses: [String]

    /// 見る側の検査を通るものだけ作れる: 通信口は 1〜65535、候補アドレスは 1〜8 件でそれぞれ `CandidateAddress.isValid`、
    /// `setBy.at` は 0 以上、解像度は `^[0-9]{1,5}x[0-9]{1,5}$`。
    /// 文字列（name・model・lastError）は拒否せず、書き出す時に制御文字を除いて 256 バイトに切り詰める
    public init?(name: String, model: String, paused: Bool, session: Bool, mode: Mode, virtualDisplay: VirtualDisplay?,
                 ambiguous: Bool, lastError: String?, setBy: SetBy?, port: Int, addresses: [String]) {
        guard Limits.portRange.contains(port), CandidateAddress.isValidList(addresses), (setBy?.at ?? 0) >= 0,
              virtualDisplay.map({ Self.isResolution($0.resolution) }) ?? true else { return nil }
        self.name = name; self.model = model; self.paused = paused; self.session = session; self.mode = mode
        self.virtualDisplay = virtualDisplay; self.ambiguous = ambiguous; self.lastError = lastError; self.setBy = setBy
        self.port = port; self.addresses = addresses
    }

    static func isResolution(_ s: String) -> Bool {
        s.range(of: #"^[0-9]{1,5}x[0-9]{1,5}$"#, options: .regularExpression) != nil
    }

    var json: JSONValue {
        .object([
            ("name", .string(TextRules.clip(name))), ("model", .string(TextRules.clip(model))), ("paused", .bool(paused)), ("session", .bool(session)),
            ("mode", .string(mode.rawValue)),
            ("vd", virtualDisplay.map { .object([("res", .string($0.resolution)), ("scaling", .string($0.scaling.rawValue)), ("source", .string($0.source.rawValue))]) } ?? .null),
            ("ambiguous", .bool(ambiguous)), ("last_error", lastError.map { .string(TextRules.clip($0)) } ?? .null),
            ("set_by", setBy.map { .object([("who", .string($0.byYou ? "you" : "other")), ("at", .integer($0.at))]) } ?? .null),
            ("addrs", .object([("p", .integer(Int64(port))), ("a", .array(addresses.map { .string($0) }))])),
        ])
    }

    static func from(_ v: JSONValue) -> StatusPayload? {
        guard let m = v.exactKeys(["name", "model", "paused", "session", "mode", "vd", "ambiguous", "last_error", "set_by", "addrs"])
        else { return nil }
        func text(_ v: JSONValue?) -> String? {
            guard case let .string(s)? = v, s.utf8.count <= Limits.textMaxBytes else { return nil }
            return s
        }
        guard let name = text(m["name"]), let model = text(m["model"]),
              case let .bool(paused)? = m["paused"], case let .bool(session)? = m["session"],
              case let .string(ms)? = m["mode"], let mode = Mode(rawValue: ms),
              case let .bool(ambiguous)? = m["ambiguous"] else { return nil }
        var vd: VirtualDisplay?
        if m["vd"] != .null {
            guard let d = m["vd"]?.exactKeys(["res", "scaling", "source"]), case let .string(res)? = d["res"],
                  case let .string(sc)? = d["scaling"], let scaling = VirtualDisplay.Scaling(rawValue: sc),
                  case let .string(src)? = d["source"], let source = VirtualDisplay.DisplaySource(rawValue: src) else { return nil }
            vd = VirtualDisplay(resolution: res, scaling: scaling, source: source)
        }
        var lastError: String?
        if m["last_error"] != .null {
            guard let s = text(m["last_error"]) else { return nil }
            lastError = s
        }
        var setBy: SetBy?
        if m["set_by"] != .null {
            guard let d = m["set_by"]?.exactKeys(["who", "at"]),
                  case let .string(who)? = d["who"], ["you", "other"].contains(who), case let .integer(at)? = d["at"] else { return nil }
            setBy = SetBy(byYou: who == "you", at: at)
        }
        guard let ad = m["addrs"]?.exactKeys(["p", "a"]),
              case let .integer(p)? = ad["p"], let port = Int(exactly: p), case let .array(items)? = ad["a"] else { return nil }
        var addrs: [String] = []
        for i in items {
            guard case let .string(a) = i else { return nil }
            addrs.append(a)
        }
        // 通信口・件数・各アドレス・at・解像度の検査は init? と同じ規則
        return StatusPayload(name: name, model: model, paused: paused, session: session, mode: mode, virtualDisplay: vd,
                             ambiguous: ambiguous, lastError: lastError, setBy: setBy, port: port, addresses: addrs)
    }
}

public enum Response: Equatable, Sendable {
    case helloChallenge(hostRandom: Bytes32)   // hello への応答 {"v":1,"ok":true,"r":…}
    case paired(newSecret: Bytes32)            // reveal への応答（承認後）{"v":1,"ok":true,"k":…}
    case status(StatusPayload)              // status・set への応答
    case log([String])                      // log への応答
    case ok                                 // unpair への応答
    case error(ErrorCode)

    /// Host が送る 1 行（改行で終わる）
    public func encoded() -> Data {
        var m: [(String, JSONValue)] = [("v", .integer(1))]
        switch self {
        case let .helloChallenge(r): m += [("ok", .bool(true)), ("r", .string(r.base64URL))]
        case let .paired(k): m += [("ok", .bool(true)), ("k", .string(k.base64URL))]
        case let .status(s): m += [("ok", .bool(true)), ("status", s.json)]
        case let .log(lines):
            // 新しい 50 行を 1 行 256 バイトに切り詰め、応答全体が 16 KiB に収まるまで古い行から除く（見る側の検査を必ず通るように）
            var kept = lines.suffix(Limits.logMaxLines).map { TextRules.clip($0) }
            func size(_ ls: [String]) -> Int {
                JSONWriter.write(.object(m + [("ok", .bool(true)), ("lines", .array(ls.map { .string($0) }))])).utf8.count + 1
            }
            while !kept.isEmpty && size(kept) > Limits.responseMaxBytes { kept.removeFirst() }
            m += [("ok", .bool(true)), ("lines", .array(kept.map { .string($0) }))]
        case .ok: m += [("ok", .bool(true))]
        case let .error(e):
            m += [("ok", .bool(false)), ("error", .string(e.rawValue))]
            if e == .unsupportedVersion { m += [("supported", .array([.integer(1)]))] }
        }
        return Data((JSONWriter.write(.object(m)) + "\n").utf8)
    }

    /// 見る側がどの指示を送ったか（応答の形を決める）
    public enum Expectation: Sendable { case hello, reveal, status, set, log, unpair }

    public enum Invalid: Error, Equatable, Sendable { case malformed }

    /// 見る側の検査。`line` は `LineFraming`（上限 16 KiB）で取り出した改行なしの 1 行
    public static func decode(_ line: Data, expecting: Expectation) throws -> Response {
        guard let m = (try? StrictJSON.parse(line))?.members() else { throw Invalid.malformed }
        let keys = Set(m.keys)
        guard case .integer(1)? = m["v"], case let .bool(ok)? = m["ok"] else { throw Invalid.malformed }
        if !ok {
            guard case let .string(e)? = m["error"], let code = ErrorCode(rawValue: e) else { throw Invalid.malformed }
            if code == .unsupportedVersion {
                guard keys == ["v", "ok", "error", "supported"], case let .array(sup)? = m["supported"],
                      sup.allSatisfy({ if case .integer = $0 { return true } else { return false } }) else { throw Invalid.malformed }
            } else {
                guard keys == ["v", "ok", "error"] else { throw Invalid.malformed }
            }
            return .error(code)
        }
        switch expecting {
        case .hello:
            guard keys == ["v", "ok", "r"], case let .string(r)? = m["r"], let d = Bytes32(base64URL: r) else { throw Invalid.malformed }
            return .helloChallenge(hostRandom: d)
        case .reveal:
            guard keys == ["v", "ok", "k"], case let .string(k)? = m["k"], let d = Bytes32(base64URL: k) else { throw Invalid.malformed }
            return .paired(newSecret: d)
        case .status, .set:
            guard keys == ["v", "ok", "status"], let s = m["status"].flatMap(StatusPayload.from) else { throw Invalid.malformed }
            return .status(s)
        case .log:
            guard keys == ["v", "ok", "lines"], case let .array(items)? = m["lines"], items.count <= Limits.logMaxLines else { throw Invalid.malformed }
            var lines: [String] = []
            for i in items {
                guard case let .string(s) = i, s.utf8.count <= Limits.textMaxBytes else { throw Invalid.malformed }
                lines.append(s)
            }
            return .log(lines)
        case .unpair:
            guard keys == ["v", "ok"] else { throw Invalid.malformed }
            return .ok
        }
    }
}
