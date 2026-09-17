import DSHKit
import Foundation

/// A connection request encoded as a URL.
///
/// This is the payload a QR code carries. The desktop client shows a code, the
/// phone scans it, and onboarding completes without anyone typing a token —
/// which is also the only realistic way to onboard someone who is not the
/// person running the server.
///
/// Two shapes are accepted:
///
/// - `dsh://pair?relay=https://relay.example&code=ABCD-1234`
/// - `dsh://direct?host=192.0.2.20&port=54499&token=<launchToken>`
enum ConnectLink: Equatable {
    case pair(relay: URL, code: String)
    case direct(baseURL: URL, launchToken: String)
    #if DEBUG
    /// A relay link whose device credential has already been claimed.
    ///
    /// Only the automated run uses this shape. A pairing code is one-time, so
    /// whoever claims it is the only party that learns the device id — and the
    /// run needs that id to revoke the device when it finishes, which is what
    /// keeps simulator runs from leaving paired devices on the relay. The
    /// product's own pairing still trades the code (`case pair`).
    ///
    /// Debug only, and parsed only from a launch argument: a shipping build must
    /// not be steerable onto a stranger's relay by a link.
    case claimedRelay(relayURL: URL, agentId: String, deviceToken: String, name: String?)
    #endif

    /// Parses an incoming URL, returning nil for anything unrecognized.
    init?(url: URL) {
        guard url.scheme?.lowercased() == "dsh" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // The action is carried either as the host or the path, so both
        // `dsh://pair?...` and `dsh:///pair?...` work.
        let action = (url.host() ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()

        switch action {
        case "pair":
            guard let relayString = value("relay"), let relay = URL(string: relayString),
                  let normalized = Self.normalizedRelayURL(relay),
                  let code = value("code"), !code.isEmpty
            else { return nil }
            self = .pair(relay: normalized, code: code)

        case "direct":
            guard let host = value("host"), !host.isEmpty,
                  let token = value("token"), !token.isEmpty
            else { return nil }
            let port = value("port") ?? "54499"
            guard let baseURL = URL(string: "http://\(host):\(port)") else { return nil }
            self = .direct(baseURL: baseURL, launchToken: token)

        #if DEBUG
        case "relay":
            guard let relayString = value("relay"), let relay = URL(string: relayString),
                  let normalized = Self.normalizedRelayURL(relay),
                  let agentId = value("agent"), !agentId.isEmpty,
                  let token = value("token"), !token.isEmpty
            else { return nil }
            self = .claimedRelay(relayURL: normalized, agentId: agentId,
                                 deviceToken: token, name: value("name"))
        #endif

        default:
            return nil
        }
    }

    /// Stores a relay address in its HTTP form.
    ///
    /// The relay hands out its WebSocket origin (`wss://…`) because that is what
    /// the connector dials, but the phone also has to reach `/pair/claim` over
    /// HTTP. Normalising once here means the profile holds a single address that
    /// both paths derive from — `LinkConfiguration` maps it back to `wss` for
    /// the socket.
    static func normalizedRelayURL(_ url: URL) -> URL? {
        LinkConfiguration.normalizedRelayURL(url)
    }

    /// The URL a QR code should encode for a relay pairing.
    static func pairingURL(relay: URL, code: String) -> URL? {
        var components = URLComponents()
        components.scheme = "dsh"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "relay", value: relay.absoluteString),
            URLQueryItem(name: "code", value: code),
        ]
        return components.url
    }
}
