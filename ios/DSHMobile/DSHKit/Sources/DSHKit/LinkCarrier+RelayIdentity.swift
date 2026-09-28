import Foundation

extension LinkCarrier {
    /// Relay identity this carrier is using, when it is a relay connection.
    ///
    /// Device management is a relay call, so the UI needs the relay origin and
    /// this phone's device token. Exposing them here keeps the transport details
    /// inside the carrier instead of spreading them into the view layer.
    ///
    /// Only the identity lives here. The device-administration client itself is
    /// in `RelayKit`, which depends on this module — so this module cannot build
    /// one without a cycle. Callers construct `RelayDeviceAdmin(url:deviceToken:)`
    /// from this tuple; see `SettingsModel`.
    public nonisolated var relay: (url: URL, deviceToken: String, agentId: String)? {
        (configuration.relayURL, configuration.deviceToken, configuration.agentId)
    }
}
