import AVFoundation
import Foundation
import Observation

/// Holds the app awake in the background while a run is worth being told about.
///
/// A phone client for a desktop agent exists so the user can walk away, and that
/// only works if the phone speaks up when a run ends or a question arrives. It
/// cannot: iOS suspends a backgrounded app within seconds, and a suspended app
/// has no sockets, receives no events and posts no notifications. The alerts
/// were working perfectly — for a foreground app nobody was looking at.
///
/// iOS gives an app that is playing audio a reason to stay scheduled, so while
/// there is work in flight the app plays silence. That is the whole trick, and
/// it is deliberate:
///
/// - It runs **only** while something is running or waiting on the user, and
///   stops the moment the workspace is quiet, so idle drain is zero.
/// - It is not a substitute for push. A run that starts on the computer *after*
///   the phone was backgrounded still cannot wake the app; that needs APNs, which
///   needs a push key and a server that sends it. This covers the common case:
///   the user sent a task from the phone and put it down.
///
/// `UIBackgroundModes: audio` in Info.plist is what makes the session legal; the
/// audio is inaudible (a zero-filled buffer), so nothing is heard.
@MainActor
@Observable
final class RunKeepAlive {

    /// Whether the app is currently being held awake.
    private(set) var isHolding = false

    private var player: AVAudioPlayer?
    private var isBackground = false
    private var hasWork = false

    /// Re-evaluates whether the app should be held awake.
    ///
    /// Called on every scene-phase and running-count change rather than being
    /// polled: the answer is a pure function of those two facts.
    func sync(isBackground: Bool, hasWorkInFlight: Bool) {
        self.isBackground = isBackground
        hasWork = hasWorkInFlight
        let wanted = isBackground && hasWorkInFlight
        if wanted == isHolding { return }
        wanted ? start() : stop()
    }

    private func start() {
        #if canImport(UIKit)
        do {
            let session = AVAudioSession.sharedInstance()
            // `.mixWithOthers` so the user's music keeps playing: this is not
            // audio, it is a scheduling argument.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            // No session, no keep-alive. The notifications still work while the
            // app is in front, so this degrades to the old behaviour rather than
            // breaking anything.
            return
        }
        guard let player = try? AVAudioPlayer(data: Self.silence) else { return }
        player.numberOfLoops = -1
        player.volume = 0
        player.prepareToPlay()
        player.play()
        self.player = player
        isHolding = true
        #endif
    }

    private func stop() {
        player?.stop()
        player = nil
        isHolding = false
        #if canImport(UIKit)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    /// One second of silence as a WAV, built in memory.
    ///
    /// A generated buffer rather than a bundled file: there is nothing to ship,
    /// nothing to lose, and the format is small enough to read in one go.
    private static let silence: Data = {
        let sampleRate = 8_000
        let frames = sampleRate  // one second
        let channels = 1
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8

        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + frames * channels * bitsPerSample / 8))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))                 // PCM header size
        append(UInt16(1))                  // PCM
        append(UInt16(channels))
        append(UInt32(sampleRate))
        append(UInt32(byteRate))
        append(UInt16(channels * bitsPerSample / 8))  // block align
        append(UInt16(bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(frames * channels * bitsPerSample / 8))
        data.append(Data(count: frames * channels * bitsPerSample / 8))
        return data
    }()
}
