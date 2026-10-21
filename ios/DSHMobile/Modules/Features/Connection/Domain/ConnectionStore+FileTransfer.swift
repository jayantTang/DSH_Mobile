import DSHKit
import Foundation
import RelayKit

/// 文件传输目标与上传：连接适配器只负责回答“从这里能不能传、传到哪”，
/// 具体传输由 RelayKit 的后台任务完成。
extension ConnectionStore {

    public func uploadFile(
        fileURL: URL,
        name: String,
        sessionId: String
    ) async throws -> StagedFile {
        let target = try fileTransferTarget()
        return try await RelayFileTransfer(
            relayURL: target.relayURL, deviceToken: target.deviceToken
        ).upload(fileURL: fileURL, name: name, sessionId: sessionId).asStaged
    }

    /// The target of a file transfer — relay origin plus device credential — or
    /// the reason there is no route from here.
    ///
    /// **Shared by both directions on purpose.** Upload and download must agree
    /// on what "cannot transfer" means, and a second copy of this policy is
    /// exactly how the two directions drifted apart before. The four ways it can
    /// fail are statements about the *connection*, not a choice between
    /// transports: none of them falls through to another route, because there
    /// isn't one.
    ///
    /// `throws` rather than returning `nil`: a `nil` is what made the old code
    /// silently take the WSS path.
    public func fileTransferTarget() throws -> (relayURL: URL, deviceToken: String) {
        guard case .relay(let relayURL, _)? = activeProfile?.transport else {
            // `.direct` (`dsh://direct`) is the DEBUG-only test channel; the
            // product has exactly one connection method. It stays usable, but it
            // cannot carry file bytes — and saying so beats quietly using a
            // different path than the product does.
            throw RelayFileTransfer.Unavailable.noRelay
        }
        guard supports(RelayFileTransfer.capability) else {
            throw RelayFileTransfer.Unavailable.connectorTooOld
        }
        guard let httpRelay = ConnectLink.normalizedRelayURL(relayURL) else {
            throw RelayFileTransfer.Unavailable.relayAddressInvalid
        }
        guard let profile = activeProfile, let secret = Keychain.get(profile.secretAccount) else {
            throw RelayFileTransfer.Unavailable.credentialMissing
        }
        return (httpRelay, secret)
    }
}
