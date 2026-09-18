import XCTest

/// The one Swift file a test case never changes.
///
/// Cases live in `test/cases/**/*.md` as structured prose; `test/run.sh` turns
/// them into a JSON plan and hands it over as `DSH_PLAN`. This file executes the
/// plan and reports one verdict per step, so adding or editing a case costs no
/// compilation — the expensive part of the first UI suite this project had.
///
/// Screenshots are requested, not taken: a step asks for one and `run.sh`
/// answers with `simctl io screenshot`. That keeps this engine free of image
/// handling and makes the evidence exactly what a person looking at the
/// simulator would see.
final class Engine: XCTestCase {

    /// Marks an attachment as a screenshot for the case, so exporting can tell
    /// the evidence apart from anything XCTest decides to attach on its own.
    private let EVIDENCE_PREFIX = "shot"

    /// Where the run's plan and event stream live.
    ///
    /// Inside this process's own container, never on the Mac: a UI test runner
    /// is a process inside the simulator and cannot see the host's filesystem,
    /// which is why a path under /Users is refused. `run.sh` finds the container
    /// with `simctl get_app_container` and writes the files there.
    ///
    /// `Documents`, `tmp` and the container root are all tried, because
    /// `xcodebuild test` reinstalls the runner and a reinstall can hand it a
    /// fresh container: a path captured before the run is not always the path
    /// during it. Explicit `DSH_PLAN` / `DSH_EVENTS` win when they are set.
    private static var planPath: String {
        if let named = ProcessInfo.processInfo.environment["DSH_PLAN"], !named.isEmpty {
            return resolve(named)
        }
        for candidate in candidates("dsh-plan.json") where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return candidates("dsh-plan.json")[0]
    }

    private static var eventsPath: String {
        if let named = ProcessInfo.processInfo.environment["DSH_EVENTS"], !named.isEmpty {
            return resolve(named)
        }
        return (planPath as NSString).deletingLastPathComponent + "/dsh-events.ndjson"
    }

    private static func candidates(_ name: String) -> [String] {
        let home = NSHomeDirectory() as NSString
        return ["Documents", "tmp", ""].map {
            $0.isEmpty ? home.appendingPathComponent(name) : home.appendingPathComponent("\($0)/\(name)")
        }
    }

    private static func resolve(_ path: String) -> String {
        path.hasPrefix("/") ? path : (NSHomeDirectory() as NSString).appendingPathComponent(path)
    }

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        // A single swallowed gesture used to abort the whole run: XCTest
        // records the failure and stops. The engine's own verdicts are what
        // decide a case, and a run that stops early cannot say which steps
        // passed — so keep going and let the final assertion speak.
        continueAfterFailure = true
        try XCTSkipIf(!FileManager.default.fileExists(atPath: Self.planPath),
                      "找不到执行计划 \(Self.planPath)；请用 test/run.sh 运行")
    }

    // MARK: - Plan

    private struct Plan: Decodable {
        let run: String
        let caseId: String
        let bundleId: String
        let screens: [Screen]
        /// A plan with no screens is a one-off capture: see `dsh.mjs shot`.
        let shots: [Shot]?

        enum CodingKeys: String, CodingKey {
            case run, screens, shots, bundleId
            case caseId = "case"
        }
    }

    /// One screen to visit: the launch arguments that select it and the steps
    /// that belong to it. Grouping by screen exists because relaunching is the
    /// only reliable way back to a known state, and doing it per step would
    /// multiply the run time by the number of pages.
    private struct Screen: Decodable {
        let id: String
        /// Selector proving the page arrived; empty means "do not wait".
        let root: String?
        let launch: [String]
        let steps: [Step]
    }

    /// One screenshot to take: `name` becomes the file name, `note` the caption
    /// drawn onto it.
    private struct Shot: Decodable {
        let name: String
        let note: String
        /// Capture after the step's action rather than before it.
        let after: Bool?
    }

    private struct Step: Decodable {
        let seq: Int
        let id: String
        let title: String
        /// `tap`, `type`, `swipe`, `wait`, `assert`, `snapshot`.
        ///
        /// `action`, `target` and `value` are mutable so a step can be re-aimed
        /// in code: `scroll_to` runs the ordinary swipe to do its scrolling.
        var action: String
        var target: String?
        var value: String?
        let timeout: Double?
        /// Screenshots the runner should take once this step is reached.
        let shots: [Shot]?
        /// Pixel-level checks the runner should run on those screenshots.
        let checks: [String]?

        enum CodingKeys: String, CodingKey {
            case seq, id, title, target, value, timeout, shots, checks
            case action = "do"
        }
    }

    // MARK: - Running

    func testPlan() throws {
        let plan = try loadPlan()
        if plan.screens.isEmpty {
            // A capture with nothing to drive: the current screen is the subject.
            for shot in plan.shots ?? [] {
                takeScreenshots(named: shot.name, note: shot.note, step: "shot")
            }
            return
        }
        for screen in plan.screens {
            launch(screen, bundleId: plan.bundleId)
            // A screen is only worth asserting on once its root exists; a fixed
            // sleep either wastes the run or races a slow connect.
            var ready = (try? waitFor(screen.root ?? "", timeout: 25)) != nil
            // A page backed by host data can be slowed down by the connection
            // rather than by anything on screen, and giving up on the first
            // timeout turned a slow list into a wrong verdict. One more window,
            // reported honestly as a retry.
            if !ready {
                ready = (try? waitFor(screen.root ?? "", timeout: 20)) != nil
            }
            emit(seq: -1, id: "screen.\(screen.id)", kind: "screen",
                 status: ready ? "pass" : "fail",
                 detail: ready ? "已进入 \(screen.id)" : "25 秒内没有出现 \(screen.root ?? screen.id)",
                 // Reported by the only party that can see the app: whether it
                 // is still in front decides if the verdict above means anything.
                 app: appState)
            if !ready {
                takeScreenshots(named: "screen-failed", note: "这一屏没有到达预期页面",
                                step: "screen.\(screen.id)")
            }
            // A page backed by host data is still filling in right after it
            // appears. Photographing that moment gives two different steps the
            // same picture and hides whatever arrives next.
            waitUntilStill()
            guard ready else { continue }
            run(steps: screen.steps)
        }
        event(["event": "end", "run": plan.run])
    }

    private func run(steps: [Step]) {
        for (index, step) in steps.enumerated() {
            // Told before it is judged: the runner answers this event by
            // taking the screenshot, which must show the state the step
            // describes rather than whatever the next step produces.
            var announced: [String: Any] = ["event": "step", "seq": step.seq,
                                            "id": step.id, "title": step.title,
                                            "do": step.action]
            if let shots = step.shots {
                announced["shots"] = shots.map { ["name": $0.name, "note": $0.note] }
            }
            if let checks = step.checks { announced["checks"] = checks }
            event(announced)

            let immediate = step.shots?.filter { $0.after != true } ?? []
            let deferred = step.shots?.filter { $0.after == true } ?? []
            if !immediate.isEmpty { takeScreenshots(named: immediate, for: step) }
            let outcome = perform(step)
            if !deferred.isEmpty {
                // Taken here, not only announced: the runner reacts to the event
                // for its own reasons, but the picture that ends up in the
                // report is this one, and the page has to be still for it —
                // otherwise "after the swipe" shows the screen as it was before.
                if outcome?.ok == true { waitUntilStill(timeout: 4) }
                takeScreenshots(named: deferred, for: step)
            }
            guard let outcome else {
                // A step with no judgement of its own still has a state worth
                // reporting, or the screenshot it asked for arrives with no
                // verdict next to it.
                emit(seq: step.seq, id: step.id, kind: step.action,
                     status: "pass", detail: "已到达该状态")
                continue
            }
            emit(seq: step.seq, id: step.id, kind: step.action,
                 status: outcome.ok ? "pass" : "fail", detail: outcome.detail)
            if !outcome.ok {
                // Everything after a failed step is unproven, not broken;
                // calling those failures would invent signal that is not there.
                for blocked in steps[(index + 1)...] {
                    emit(seq: blocked.seq, id: blocked.id, kind: blocked.action,
                         status: "blocked", detail: "前一步未通过")
                }
                return
            }
        }
    }

    // MARK: - One step

    /// Human-readable launch state, for the report.
    private var appState: String {
        switch app?.state {
        case .runningForeground: "runningForeground"
        case .runningBackground: "runningBackground"
        case .notRunning: "notRunning"
        case .unknown: "unknown"
        default: "other"
        }
    }

    private struct Outcome {
        let ok: Bool
        let detail: String
    }

    private func perform(_ step: Step) -> Outcome? {
        switch step.action {
        case "tap":
            guard let element = element(step.target) else {
                return Outcome(ok: false, detail: "找不到元素 \(step.target ?? "（未填）")")
            }
            if element.isHittable {
                element.tap()
                return Outcome(ok: true, detail: "已点击 \(step.target ?? "")")
            }
            // No coordinate fallback: synthesising a touch at app-level
            // coordinates raises "Pointer events are not supported for this
            // device", which ends the whole run. Bring it on screen instead,
            // and if that does not work, say so as a failed step.
            if let container = mainScrollableContainer() ?? identifiedContainer() {
                for _ in 0..<3 where !element.isHittable {
                    container.swipeUp()
                    Thread.sleep(forTimeInterval: 0.4)
                }
            }
            guard element.isHittable else {
                return Outcome(ok: false, detail: "元素存在但不可点击：\(step.target ?? "")")
            }
            element.tap()
            return Outcome(ok: true, detail: "已点击 \(step.target ?? "")")

        case "background":
            // Home, then wait: this is the trip to the background that used to
            // cost the connection.
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: step.timeout ?? 3)
            return Outcome(ok: true, detail: "已切到后台 \(Int(step.timeout ?? 3)) 秒")

        case "foreground":
            app.activate()
            Thread.sleep(forTimeInterval: 2)
            return Outcome(ok: true, detail: "已切回前台")

        case "tap_where":
            // A tap at a fraction of the screen. The bluntest tool here, and the
            // right one for a control that is visible and fixed but reports no
            // hit target — a button in a web view's chrome, for instance.
            let parts = (step.value ?? "0.5,0.5").split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0.5 }
            let fx = parts.count > 0 ? parts[0] : 0.5
            let fy = parts.count > 1 ? parts[1] : 0.5
            app.coordinate(withNormalizedOffset: CGVector(dx: fx, dy: fy)).tap()
            return Outcome(ok: true, detail: "已点击屏幕 \(Int(fx * 100))% / \(Int(fy * 100))% 处")

        case "tap_at":
            guard let element = element(step.target) else {
                return Outcome(ok: false, detail: "找不到元素 \(step.target ?? "（未填）")")
            }
            // Deliberately no `isHittable` check: a control inside a toolbar or
            // a web view's chrome reports itself unhittable while sitting
            // exactly where it looks, and tapping its coordinates works. The
            // frame is what has to be real.
            let frame = element.frame
            guard frame.height > 1, frame.width > 1 else {
                return Outcome(ok: false, detail: "元素没有可点的尺寸：\(step.target ?? "")")
            }
            let where_ = step.value ?? "center"
            let point: CGVector = switch where_ {
            case "left": CGVector(dx: 0.25, dy: 0.5)
            case "right": CGVector(dx: 0.75, dy: 0.5)
            default: CGVector(dx: 0.5, dy: 0.5)
            }
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.minX + frame.width * point.dx,
                                     dy: frame.minY + frame.height * point.dy))
                .tap()
            return Outcome(ok: true, detail: "已点击 \(step.target ?? "") 的\(where_)位置")

        case "type":
            // No target means "the field that is focused" — the same thing a
            // person means after tapping one.
            guard let target = step.target else {
                app.typeText(step.value ?? "")
                return Outcome(ok: true, detail: "已输入「\(step.value ?? "")」")
            }
            guard let element = element(target) else {
                return Outcome(ok: false, detail: "找不到输入框 \(target)")
            }
            element.tap()
            element.typeText(step.value ?? "")
            return Outcome(ok: true, detail: "已输入「\(step.value ?? "")」")

        case "swipe", "scroll":
            return swipe(step)

        case "wait":
            guard let target = step.target else { return Outcome(ok: false, detail: "缺少目标") }
            let timeout = step.timeout ?? 15
            do {
                _ = try waitFor(target, timeout: timeout)
                return Outcome(ok: true, detail: "已出现 \(target)")
            } catch {
                return Outcome(ok: false, detail: "\(Int(timeout)) 秒内没有出现 \(target)")
            }

        case "pause":
            // A plain wait, for something that cannot be waited *for*: the
            // system share sheet is hosted outside the app, so no element of
            // its ever appears in this tree, and a picture taken during its
            // animation shows the screen underneath it.
            let seconds = step.timeout ?? 1
            Thread.sleep(forTimeInterval: seconds)
            return Outcome(ok: true, detail: "已等待 \(Int(seconds)) 秒")

        case "assert":
            return assertStep(step)

        case "open_html":
            // Renders raw markup in the system browser. A way to ask "does this
            // CSS work on this platform at all?" without first writing a file
            // and getting it onto the phone.
            guard let html = step.value ?? step.target,
                  let encoded = html.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "data:text/html;charset=utf-8," + encoded)
            else { return Outcome(ok: false, detail: "缺少要渲染的 HTML") }
            let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
            safari.launch()
            safari.open(url)
            Thread.sleep(forTimeInterval: 3)
            return Outcome(ok: true, detail: "已在浏览器渲染 HTML（\(html.count) 字）")

        case "open_url":
            // Opens a URL in the system browser and leaves it there. Safari is a
            // second rendering engine to compare against: if a page that renders
            // here does not render in the app's own web view, the difference is
            // in the app, not in the page.
            guard let target = step.value ?? step.target,
                  let url = URL(string: target)
            else { return Outcome(ok: false, detail: "缺少要打开的地址") }
            let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
            safari.launch()
            safari.open(url)
            Thread.sleep(forTimeInterval: 3)
            return Outcome(ok: true, detail: "已在浏览器打开 \(target.prefix(60))")

        case "wait_gone":
            // Waiting for something to disappear: a sheet that closes after a
            // save, a banner that times out. The mirror of `wait`, and without
            // it a case has to guess how long the round trip takes.
            guard let target = step.target else { return Outcome(ok: false, detail: "缺少目标") }
            let timeout = step.timeout ?? 20
            let query = resolveQuery(target)
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "count == 0"), object: query)
            let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
            return result == .completed
                ? Outcome(ok: true, detail: "\(target) 已消失")
                : Outcome(ok: false, detail: "\(Int(timeout)) 秒内 \(target) 还在")

        case "scroll_to":
            // Swipes until the target is on screen. Assertions cannot see past
            // the fold, so "find it first" has to be its own step; doing it by
            // hand in every case made long lists untestable.
            guard let target = step.target else { return Outcome(ok: false, detail: "缺少目标") }
            let container = mainScrollableContainer() ?? identifiedContainer()
            // "Found" is not enough: a row half under the bottom edge exists in
            // the tree and cannot be tapped. Scroll until it can be used, and
            // only fall back to mere existence when that never happens (a
            // section header pinned at the very bottom, say).
            // "Visible" means on screen, not hittable: a label inside a row is
            // never hittable, and requiring that scrolled straight past the very
            // thing being looked for.
            let screen = app.windows.firstMatch.frame
            for _ in 0..<12 {
                let query = resolveQuery(target)
                if query.count > 0 {
                    let frame = query.element(boundBy: 0).frame
                    let shown = frame.intersection(screen)
                    if !shown.isNull, shown.height >= frame.height * 0.6, frame.height > 0 {
                        return Outcome(ok: true, detail: "已滚动到 \(target)")
                    }
                }
                container?.swipeUp() ?? app.windows.firstMatch.swipeUp()
                Thread.sleep(forTimeInterval: 0.35)
            }
            return resolveQuery(target).count > 0
                ? Outcome(ok: true, detail: "\(target) 在树上但没滚进可视区")
                : Outcome(ok: false, detail: "滚了 12 屏也没找到 \(target)")

        case "probe":
            return probeScrollContainers()

        case "shot", "check", "snapshot":
            // Taken and judged by run.sh from the event stream: the screenshot
            // is captured outside the test process, and pixel comparison is not
            // something a UI test should be doing in the first place.
            return nil

        default:
            return Outcome(ok: false, detail: "未知动作 \(step.action)")
        }
    }

    /// Scrolls the screen, and proves that it did.
    ///
    /// Two attempts, because one gesture does not cover every container. A
    /// SwiftUI `List` in a sheet answers to `swipeUp()` on its own element while
    /// ignoring a coordinate drag, and a plain drag inside a scroll view answers
    /// to coordinates while the element proxy can refuse. Trying the element
    /// first and the coordinates second is what covers both.
    ///
    /// The result is judged by comparing the screen before and after, so a
    /// gesture the container swallowed is reported instead of being handed to
    /// the next assertion as an app problem.
    private func swipe(_ step: Step) -> Outcome {
        let direction = step.value ?? "up"
        let named = step.target.flatMap { $0.isEmpty ? nil : $0 }
        let target = named.flatMap { element($0) } ?? mainScrollableContainer() ?? identifiedContainer()
        let frame = target?.frame ?? app.windows.firstMatch.frame
        // A list row is wide and short: requiring a tall element rejected every
        // row-level swipe, which is how a left swipe on one row is done.
        let horizontal = direction == "left" || direction == "right"
        let enough = horizontal ? frame.width > 80 && frame.height > 16
                                : frame.height > 80 && frame.width > 40
        guard enough else {
            return Outcome(ok: false, detail: "可滑动区域太小（\(Int(frame.width))×\(Int(frame.height))）")
        }
        let what = named ?? (target?.identifier.isEmpty == false ? target!.identifier : "窗口")

        // Movement is measured on a real element's position. Byte-comparing two
        // captures says "something on screen changed", which an animation, a
        // clock tick or a spinner satisfies without anything having scrolled.
        let before = textFingerprint()
        let beforeScreenshot = XCUIScreen.main.screenshot().pngRepresentation
        var moved = false
        var how = ""
        var measurement = ""

        // Each strategy is retried: the first gesture on a freshly presented
        // sheet is regularly absorbed, and repeating it is far cheaper than a
        // false failure.
        // Gestures are element gestures only.
        //
        // A coordinate drag (`press(forDuration:thenDragTo:)`) raises
        // "Pointer events are not supported for this device" on this simulator,
        // and that is a process-level exception: it killed the run instead of
        // reporting a step. Worse, when the named target had gone it dragged
        // across whatever was under the finger — which archived a live session.
        // `swipeLeft()` on the row itself is both supported and aimed.
        if let name = named {
            var performed = false
            for _ in 0..<3 where !performed {
                guard let fresh = element(name), fresh.exists else { break }
                // A row half under the bottom edge cannot take a gesture, and
                // asking for one anyway raises "Pointer events are not supported
                // for this device" — a process-level exception that ends the run.
                // Bring it fully on screen first.
                if !fresh.isHittable, let container = mainScrollableContainer() ?? identifiedContainer() {
                    for _ in 0..<3 where !fresh.isHittable {
                        container.swipeUp()
                        Thread.sleep(forTimeInterval: 0.4)
                    }
                }
                guard fresh.isHittable else {
                    return Outcome(ok: false, detail: "\(name) 没能在屏幕上完整露出，不做滑动")
                }
                switch direction {
                case "down": fresh.swipeDown()
                case "left": fresh.swipeLeft()
                case "right": fresh.swipeRight()
                default: fresh.swipeUp()
                }
                performed = true
                Thread.sleep(forTimeInterval: 0.5)
                (moved, measurement) = pageMoved(from: before)
            }
            guard performed else {
                return Outcome(ok: false, detail: "找不到 \(name)，不做无目标的滑动")
            }
            let screenChanged = changed(beforeScreenshot, XCUIScreen.main.screenshot().pngRepresentation)
            return Outcome(ok: true,
                           detail: screenChanged
                               ? "已在 \(name) 上向\(direction)滑动"
                               : "已在 \(name) 上向\(direction)滑动（画面未变，结果由下一步断言）")
        }

        // Scrolling a page: the element gesture first, then a plain scroll for
        // containers that only answer to that.
        for _ in 0..<3 where !moved {
            // The gesture is only synthesised for a container that can take it:
            // asking an element that is mid-animation or not hittable for a
            // swipe raises a process-level "pointer events" exception, and one
            // unusable scroll is not worth ending a run over.
            guard let container = mainScrollableContainer() ?? identifiedContainer(),
                  container.exists, container.isHittable else { break }
            switch direction {
            case "down": container.swipeDown()
            case "left": container.swipeLeft()
            case "right": container.swipeRight()
            default: container.swipeUp()
            }
            Thread.sleep(forTimeInterval: 0.5)
            (moved, measurement) = pageMoved(from: before)
            how = "元素滑动 \(what)"
        }
        if !moved, let container = mainScrollableContainer() ?? identifiedContainer(), container.exists {
            if #available(iOS 17.0, *) {
                container.scroll(byDeltaX: direction == "left" ? -220 : (direction == "right" ? 220 : 0),
                                 deltaY: direction == "up" ? -220 : (direction == "down" ? 220 : 0))
                Thread.sleep(forTimeInterval: 0.5)
                (moved, measurement) = pageMoved(from: before)
                how = "元素滚动"
            }
        }

        // A swipe with an explicit target is usually a row being dragged aside
        // to reveal its actions: no text moves, so "did the page scroll" is the
        // wrong question. There the gesture only has to land — the step after it
        // asserts what appeared — while a target-less swipe is a scroll and must
        // actually move something.
        if named != nil {
            let screenChanged = changed(beforeScreenshot, XCUIScreen.main.screenshot().pngRepresentation)
            return Outcome(ok: true,
                           detail: screenChanged
                               ? "已向\(direction)滑动 \(what)"
                               : "已向\(direction)滑动 \(what)（画面未变，结果由下一步断言）")
        }
        return Outcome(ok: moved,
                       detail: moved ? "已向\(direction)滑动（\(how)，\(measurement)）"
                                     : "滑动后画面没有变化（\(measurement)）")
    }

    /// Waits for the screen to stop changing, so the next screenshot shows a
    /// settled page rather than a frame of the arrival animation.
    private func waitUntilStill(timeout: Double = 6) {
        var previous = XCUIScreen.main.screenshot().pngRepresentation
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.35)
            let current = XCUIScreen.main.screenshot().pngRepresentation
            if !changed(previous, current) { return }
            previous = current
        }
    }

    /// A cheap "did the screen change" test: exact equality is too strict (a
    /// clock tick or an animation frame counts) and no tolerance at all would
    /// pass a no-op. Compares byte length and a sample of bytes.
    private func changed(_ before: Data, _ after: Data) -> Bool {
        if before == after { return false }
        let smaller = min(before.count, after.count)
        guard smaller > 0 else { return false }
        var differing = 0
        var sampled = 0
        let stride = max(1, smaller / 4000)
        for index in Swift.stride(from: 0, to: smaller, by: stride) {
            sampled += 1
            if before[before.startIndex + index] != after[after.startIndex + index] { differing += 1 }
        }
        return sampled > 0 && Double(differing) / Double(sampled) > 0.02
    }

    /// The Y position of every text currently on screen.
    ///
    /// One element is not enough to tell "the page moved" from "that element
    /// re-laid out": a cell can shift a few points when a spinner beside it
    /// disappears. Several elements moving together in one direction is page
    /// movement, and that is what a scroll is.
    private func textFingerprint() -> [String: CGFloat] {
        var positions: [String: CGFloat] = [:]
        let query = app.staticTexts
        for index in 0..<min(query.count, 40) {
            let element = query.element(boundBy: index)
            guard element.exists else { continue }
            let label = element.label
            guard !label.isEmpty, positions[label] == nil else { continue }
            positions[label] = element.frame.minY
        }
        return positions
    }

    /// True when at least three texts moved by more than a hair, and mostly in
    /// the same direction — the signature of a scroll rather than of a re-layout.
    private func pageMoved(from before: [String: CGFloat]) -> (moved: Bool, detail: String) {
        let after = textFingerprint()
        var deltas: [CGFloat] = []
        for (label, y) in before {
            guard let now = after[label] else { continue }
            let delta = now - y
            if abs(delta) > 6 { deltas.append(delta) }
        }
        guard deltas.count >= 3 else {
            return (false, "只有 \(deltas.count) 项文字移动，判为没滚动")
        }
        let upward = deltas.filter { $0 < 0 }.count
        let downward = deltas.count - upward
        let coherent = Double(max(upward, downward)) / Double(deltas.count) > 0.7
        let median = deltas.sorted()[deltas.count / 2]
        return (coherent, "\(deltas.count) 项文字位移，中位 \(Int(median))pt")
    }

    /// The thing to scroll: the case's target, else the page container, else the
    /// whole window.
    private func scrollTarget(_ named: String?) -> XCUIElement? {
        if let named { return element(named) }
        if let container = mainScrollableContainer() { return container }
        if let identified = identifiedContainer() { return identified }
        return nil
    }

    /// The named container of the current page, when the page has one:
    /// `settings.root`, `session.list`, `chat.transcript` and so on. It is not
    /// reported as a scroll view, but it is the thing that scrolls.
    private func identifiedContainer() -> XCUIElement? {
        for identifier in ["settings.root", "session.list", "chat.transcript", "files.root"] {
            let query = app.descendants(matching: .any).matching(identifier: identifier)
            if query.count > 0 {
                let candidate = query.element(boundBy: 0)
                if candidate.frame.height > 120 { return candidate }
            }
        }
        return nil
    }

    /// Prints what the current screen offers to scroll, for diagnosing a
    /// gesture that silently does nothing.
    private func probeScrollContainers() -> Outcome {
        var lines: [String] = ["scrollViews=\(app.scrollViews.count) "
            + "tables=\(app.tables.count) collections=\(app.collectionViews.count) "
            + "webViews=\(app.webViews.count)"]
        lines.append("命中「已配对的设备」=\(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "已配对")).count)"
            + " 「关于」=\(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "关于")).count)")
        for kind in [XCUIElement.ElementType.scrollView, .table, .collectionView, .other] {
            let query = app.descendants(matching: kind)
            for index in 0..<min(query.count, 3) {
                let element = query.element(boundBy: index)
                lines.append("dump \(kind) [\(index)] " + element.debugDescription.prefix(80))
            }
        }
        for kind in [XCUIElement.ElementType.scrollView, .table, .collectionView, .textView, .other] {
            let query = app.descendants(matching: kind)
            if query.count == 0 { continue }
            lines.append("\(kind) ×\(query.count)")
            for index in 0..<min(query.count, 4) {
                let element = query.element(boundBy: index)
                let frame = element.frame
                guard frame.height > 40 else { continue }
                let identifiable = element.identifier.isEmpty ? "-" : element.identifier
                lines.append("  [\(index)] id=\(identifiable) "
                    + "y=\(Int(frame.minY))–\(Int(frame.maxY)) h=\(Int(frame.height)) "
                    + "hittable=\(element.isHittable)")
            }
        }
        return Outcome(ok: true, detail: lines.joined(separator: " | "))
    }

    /// The largest visible scroll container, which is the one a person would
    /// drag. Tables and collection views are included because that is what
    /// SwiftUI's `List` becomes on iOS.
    private func mainScrollableContainer() -> XCUIElement? {
        var best: (element: XCUIElement, area: CGFloat)?
        for kind in [XCUIElement.ElementType.scrollView, .table, .collectionView, .textView] {
            let query = app.descendants(matching: kind)
            for index in 0..<min(query.count, 6) {
                let candidate = query.element(boundBy: index)
                guard candidate.exists, candidate.frame.height > 120 else { continue }
                let area = candidate.frame.width * candidate.frame.height
                if best == nil || area > best!.area { best = (candidate, area) }
            }
        }
        return best?.element
    }

    private func assertStep(_ step: Step) -> Outcome {
        guard let target = step.target else { return Outcome(ok: false, detail: "缺少目标") }
        let query = resolveQuery(target)

        // `absent`: the check is that nothing matches, which is how the report
        // says "every picture loaded" — the failure banner only exists when one
        // did not.
        if step.value == "absent" {
            return query.count == 0
                ? Outcome(ok: true, detail: "确认没有 \(target)")
                : Outcome(ok: false, detail: "不该出现的东西在屏幕上：\(target)")
        }

        guard query.count > 0 else {
            return Outcome(ok: false, detail: "屏幕上没有 \(target)")
        }
        guard let wanted = step.value else {
            return Outcome(ok: true, detail: "存在 \(target)")
        }
        // A label is often a prefix of a runtime value (a count, a path), so
        // containment is the honest reading of a prose expectation.
        for index in 0..<query.count {
            let element = query.element(boundBy: index)
            let value = element.value as? String
            if element.label.contains(wanted) || value?.contains(wanted) == true {
                return Outcome(ok: true, detail: "\(target) 含「\(wanted)」")
            }
        }
        let seen = (0..<min(query.count, 4)).map { query.element(boundBy: $0).label }
        return Outcome(ok: false,
                       detail: "\(target) 里没有「\(wanted)」，实际：\(seen.joined(separator: " / "))")
    }

    // MARK: - Element lookup

    /// Resolves `id:foo`, `label:文字`, `text:文字`, or a bare identifier.
    private func resolveQuery(_ target: String) -> XCUIElementQuery {
        if let id = target.dropPrefix("id:") {
            return app.descendants(matching: .any).matching(identifier: id)
        }
        if let prefix = target.dropPrefix("id~:") {
            // Any element whose identifier starts with this: "some session row"
            // when the case does not care which one.
            return app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
        }
        if let label = target.dropPrefix("label:") {
            return app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", label))
        }
        if let placeholder = target.dropPrefix("field:") {
            // Search fields are their own element kind: a `text:` lookup finds
            // neither the field nor its placeholder.
            return app.searchFields
                .matching(NSPredicate(format: "label CONTAINS %@ OR placeholderValue CONTAINS %@",
                                      placeholder, placeholder))
        }
        if let text = target.dropPrefix("text:") {
            // Buttons first: a row's text is a child of the row's button, so a
            // tap aimed at the words has to land on the row — tapping the label
            // itself reports "exists but not hittable" and does nothing.
            //
            // Built inline rather than shared: an `NSPredicate` is not `Sendable`
            // and passing one between these main-actor calls is a data race as
            // far as the compiler is concerned.
            let buttons = app.buttons.matching(
                NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text))
            if buttons.count > 0 { return buttons }
            return app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text))
        }
        return app.descendants(matching: .any).matching(identifier: target)
    }

    private func element(_ target: String?) -> XCUIElement? {
        guard let target else { return nil }
        let query = resolveQuery(target)
        guard query.count > 0 else { return nil }
        return query.element(boundBy: 0)
    }

    private func waitFor(_ target: String, timeout: Double) throws -> XCUIElement {
        let query = resolveQuery(target)
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count > 0"), object: query)
        guard XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed else {
            throw EngineError.timeout(target)
        }
        return query.element(boundBy: 0)
    }

    // MARK: - Evidence

    /// Attaches a screenshot of the app to the result bundle.
    ///
    /// Taken here rather than by the runner through `simctl`: an app driven by
    /// XCUITest does not appear on the simulator's own display, so a host-side
    /// capture returns the home screen while every assertion passes. What this
    /// renders is the app's real interface, which is what the design review is
    /// about.
    ///
    /// The attachment names carry the case's own names for the shots, so the
    /// export step can put them back in step order.
    private func takeScreenshots(named shots: [Shot], for step: Step) {
        for shot in shots {
            // Labelled with the step's sequence, not its id: two steps in one
            // case may name a picture the same thing ("settings" twice), and
            // matching evidence by name alone then overwrites one with the
            // other.
            takeScreenshots(named: shot.name, note: shot.note, step: "\(step.seq)")
        }
    }

    private func takeScreenshots(named: String, note: String, step: String) {
        // A capture taken while the interface is still settling shows an
        // animation frame and reads as a layout problem that is not there.
        Thread.sleep(forTimeInterval: 0.45)
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        // `~` and not `|`: XCTest sanitises a pipe out of the exported file
        // name, which would leave the exporter unable to recognise its own
        // evidence.
        attachment.name = [EVIDENCE_PREFIX, step, named, note].joined(separator: "~")
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Launch

    private func launch(_ screen: Screen, bundleId: String) {
        app?.terminate()
        if app != nil {
            // A launch requested while the old process is still going is served
            // by that process, and every launch argument — the screen to open —
            // is silently dropped. The page then never appears and the run
            // blames the app for it.
            let deadline = Date().addingTimeInterval(5)
            while app.state != .notRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        let application = XCUIApplication(bundleIdentifier: bundleId)
        application.launchArguments = screen.launch
        application.launch()
        app = application
        dismissSystemAlertIfNeeded()
        // Announced after the launch returns, not before it starts: the runner
        // answers this event with a screenshot, and one taken during the launch
        // catches the home screen instead of the page.
        event(["event": "screen", "id": screen.id, "launch": screen.launch])
    }

    /// Answers a system dialog if one is up, so it cannot swallow the run.
    ///
    /// A freshly installed app asks for notification permission on its first
    /// launch. That dialog belongs to SpringBoard, not to the app, so no query
    /// rooted at the app can see it, and every following step taps into a modal
    /// — a fresh install then fails the case for a reason that has nothing to do
    /// with the app. Only the affirmative button is pressed: a run must not
    /// answer "don't allow" on the user's behalf.
    private func dismissSystemAlertIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 3), alert.buttons.count > 0 else { return }
        for label in ["允许", "好", "Allow", "OK"] {
            let button = alert.buttons[label]
            if button.exists {
                button.tap()
                return
            }
        }
        // No label matched: the affirmative choice is the trailing one.
        alert.buttons.allElementsBoundByIndex.last?.tap()
    }

    // MARK: - Reporting

    private func emit(seq: Int, id: String, kind: String, status: String, detail: String,
                      shots: [Shot]? = nil, app: String? = nil) {
        var payload: [String: Any] = ["event": "verdict", "seq": seq, "id": id, "kind": kind,
                                      "status": status, "detail": detail]
        if let app { payload["app"] = app }
        if let shots {
            // A failure is the one state worth a picture of even when the case
            // did not ask for one: "did not arrive" is otherwise unreadable.
            payload["shots"] = shots.map { ["name": $0.name, "note": $0.note] }
        }
        event(payload)
    }

    /// Appends one NDJSON line to the events file.
    ///
    /// Each line is flushed on its own so `run.sh` can answer a step while the
    /// test is still running — that is what makes a screenshot land on the
    /// state the step described instead of on whatever came after it.
    private func event(_ payload: [String: Any]) {
        let path = Self.eventsPath
        guard !path.isEmpty else { return }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        var line = payload
        line["t"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: line) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.write(Data("\n".utf8))
        try? handle.close()
    }

    private func loadPlan() throws -> Plan {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.planPath))
        return try JSONDecoder().decode(Plan.self, from: data)
    }
}

private enum EngineError: Error, LocalizedError {
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .timeout(let target): "等待 \(target) 超时"
        }
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
