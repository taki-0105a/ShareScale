import XCTest
@testable import ShareScaleProtocol

/// 公開している値型がすべて Sendable であること（Host と見る側で別のタスクに渡すため）。満たさなければ組み立てで失敗する
final class SendableTests: XCTestCase {
    func requireSendable<T: Sendable>(_: T.Type) {}

    func testPublicValueTypesAreSendable() {
        requireSendable(IPAddress.self); requireSendable(IPNetwork.self); requireSendable(CandidateAddress.self)
        requireSendable(Base64URL.self)
        requireSendable(Binding.self); requireSendable(Commitment.self); requireSendable(ConfirmationCode.self)
        requireSendable(ManualEntry.self); requireSendable(ManualEntry.KeyError.self); requireSendable(ManualEntry.AddressError.self)
        requireSendable(Mode.self); requireSendable(ErrorCode.self); requireSendable(Auth.self); requireSendable(Request.self)
        requireSendable(RequestReader.self); requireSendable(RequestReader.DropReason.self); requireSendable(RequestReader.Envelope.self)
        requireSendable(StatusPayload.self); requireSendable(StatusPayload.VirtualDisplay.self)
        requireSendable(StatusPayload.VirtualDisplay.Scaling.self); requireSendable(StatusPayload.VirtualDisplay.DisplaySource.self)
        requireSendable(StatusPayload.SetBy.self)
        requireSendable(Response.self); requireSendable(Response.Expectation.self); requireSendable(Response.Invalid.self)
        requireSendable(NameRules.self)
        requireSendable(Limits.self); requireSendable(PairingCode.self); requireSendable(PairingCode.Invalid.self); requireSendable(PairingID.self); requireSendable(Bytes32.self)
        requireSendable(SourceClass.self); requireSendable(SourceDecision.self); requireSendable(SourceClassifier.self)
        requireSendable(LocalNetworks.self); requireSendable(LocalNetworks.InterfaceKind.self); requireSendable(LocalInterface.self)
        requireSendable(JSONValue.self); requireSendable(StrictJSONError.self); requireSendable(StrictJSON.self); requireSendable(JSONWriter.self)
        requireSendable(LineFraming.self); requireSendable(LineFraming.FrameRejection.self); requireSendable(LineFraming.Result.self)
        requireSendable(AppVersion.self)
    }
}
