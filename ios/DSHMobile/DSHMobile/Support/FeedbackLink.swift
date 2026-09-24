import DSHKit
import Foundation
import UIKit

/// Where the in-app feedback entry sends people.
///
/// A GitHub issue form on purpose: reports end up where the code lives, the
/// answers are useful to other users, and nothing is collected silently — the
/// form shows every field before it is submitted. The app fills in only what a
/// maintainer would otherwise have to ask for (build, device, iOS version), and
/// the user can edit or ignore all of it.
enum FeedbackLink {

    static let repository = "https://github.com/jayantTang/DSH_Mobile"

    /// The issue form, pre-filled with the technical facts that make a report
    /// actionable. Field ids match `.github/ISSUE_TEMPLATE/feedback.yml`.
    static var issueURL: URL {
        var items = [
            URLQueryItem(name: "template", value: "feedback.yml"),
            URLQueryItem(name: "title", value: "[反馈/Feedback] \(appVersion) · \(deviceModel)"),
            URLQueryItem(name: "version", value: appVersion),
            URLQueryItem(name: "device", value: "\(deviceModel) · iOS \(systemVersion)"),
        ]
        items = items.filter { !($0.value ?? "").isEmpty }
        var components = URLComponents(string: "\(repository)/issues/new")!
        components.queryItems = items
        return components.url ?? URL(string: "\(repository)/issues/new")!
    }

    static var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) \(build)"
    }

    /// `iPhone15,4`-style model, the same string the relay stores.
    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            guard let base = bytes.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
    }

    static var systemVersion: String {
        UIDevice.current.systemVersion
    }
}
