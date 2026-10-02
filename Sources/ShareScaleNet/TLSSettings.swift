import Foundation
import Network
import Security
import ShareScaleProtocol

/// 見る側と Host の両方に当てる TLS の設定（仕様「接続」）
public enum TLSSettings {
    /// TLS 1.2 の ECDHE-PSK（TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256）
    public static let cipherSuite: UInt16 = 0xCCAC
    public static let protocolVersion: UInt16 = 0x0303

    /// PSK の識別子はペアリング ID の hex（32 文字の小文字）の UTF-8
    public static func identity(_ id: PairingID) -> Data { Data(id.hex.utf8) }

    /// Host の受け側: 登録済みのペアリングとコードのすべて。辞書なので同じ識別子を 2 回登録できない
    /// （同じ識別子に 2 つの秘密を登録すると、後の秘密では TLS が通らないため）
    public static func options(psks: [PairingID: Bytes32]) -> NWProtocolTLS.Options {
        make(psks.sorted { $0.key.hex < $1.key.hex }.map { ($0.key, $0.value) })
    }

    /// 見る側: 使う 1 つ
    public static func options(id: PairingID, secret: Bytes32) -> NWProtocolTLS.Options { make([(id, secret)]) }

    public static func parameters(psks: [PairingID: Bytes32]) -> NWParameters { wrap(options(psks: psks)) }
    public static func parameters(id: PairingID, secret: Bytes32) -> NWParameters { wrap(options(id: id, secret: secret)) }

    private static func make(_ psks: [(PairingID, Bytes32)]) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let o = tls.securityProtocolOptions
        for (id, secret) in psks {
            sec_protocol_options_add_pre_shared_key(o, dispatchData(secret.data), dispatchData(identity(id)))
        }
        sec_protocol_options_set_min_tls_protocol_version(o, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(o, .TLSv12)
        // 注意: 受け側では、この設定は受け入れる方式を限らない（試作 7）。つながった後の `SessionCheck` が本当の守り
        sec_protocol_options_append_tls_ciphersuite(o, tls_ciphersuite_t(rawValue: cipherSuite)!)
        // 再開すると PSK の確認を飛ばすため、解除した見る側が TLS を通れてしまう
        sec_protocol_options_set_tls_resumption_enabled(o, false)
        sec_protocol_options_set_tls_tickets_enabled(o, false)
        sec_protocol_options_set_tls_renegotiation_enabled(o, false)
        sec_protocol_options_set_tls_false_start_enabled(o, false)
        return tls
    }

    private static func wrap(_ tls: NWProtocolTLS.Options) -> NWParameters {
        let p = NWParameters(tls: tls)
        p.includePeerToPeer = false
        return p
    }

    static func dispatchData(_ d: Data) -> __DispatchData {
        d.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
    }
}

/// つながった直後（`.ready`）の確かめ。読み書きの前に両側で行う
public enum SessionCheck {
    public enum Failure: Error, Equatable, Sendable {
        case noMetadata
        case unexpected(version: UInt16, suite: UInt16)   // 0xCCAC 以外の方式で成立した（試作 7: 受け側は断れない）
        case noKeyingMaterial
    }

    /// 交渉された版と方式が TLS 1.2（0x0303）・0xCCAC でなければ失敗
    public static func check(version: UInt16, suite: UInt16) -> Failure? {
        version == TLSSettings.protocolVersion && suite == TLSSettings.cipherSuite ? nil : .unexpected(version: version, suite: suite)
    }

    /// 版と方式を確かめ、結び付けの値（ekm）を取り出す
    public static func verify(_ connection: NWConnection) -> Result<Bytes32, Failure> {
        guard let m = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return .failure(.noMetadata) }
        let meta = m.securityProtocolMetadata
        let v = sec_protocol_metadata_get_negotiated_tls_protocol_version(meta).rawValue
        let s = sec_protocol_metadata_get_negotiated_tls_ciphersuite(meta).rawValue
        if let f = check(version: v, suite: s) { return .failure(f) }
        let label = Binding.exporterLabel
        guard let raw = label.withCString({ sec_protocol_metadata_create_secret(meta, label.utf8.count, $0, Binding.ekmLength) }),
              let ekm = Bytes32(Data(raw as DispatchData)) else { return .failure(.noKeyingMaterial) }
        return .success(ekm)
    }
}
