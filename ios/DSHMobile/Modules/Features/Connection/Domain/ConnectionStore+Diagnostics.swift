import DSHKit
import Foundation

/// 连接适配器的诊断/探针接线：生命周期流水、首个响应耗时、轻量探活。
/// 这些方法只读/写 store 的内部诊断状态，不改变连接状态机。
extension ConnectionStore {

    var probeCapabilities: Set<String> { [HostClientFactory.sessionDigestCapability] }

    /// 记一条前后台切换。**不依赖 carrier**：链路还没建起来时更要记——
    /// "App 回到前台但一直没拨号"正是最需要看见的现场（记录走 store 自己那份流水）。
    public func noteScene(_ scene: AppScene, cold: Bool = false) async {
        await linkDiagnostics.record(kind: "app.scene", detail: [
            "phase": .string(scene.rawValue), "cold": .bool(cold),
        ])
        // 回到前台是"用户主动回来"，退避清零并立刻探一次（spec 022 FR-002）：
        // 用户等着的时候不该还在按退避倒计时。
        if scene == .foreground {
            supervisor.reset()
        }
        // 回到前台顺手把攒下的记录推上去（后台期间可能攒了"挂起—恢复"这一串）。
        if scene == .foreground, let link = carrier as? LinkCarrier { await pushDiagnostics(link) }
    }

    /// 冷启动：进程从零起来并进入前台。与"从后台回来"必须分得开（现场诊断发现的缺口）。
    public func noteColdLaunch() async {
        await noteScene(.foreground, cold: true)
    }

    /// 首个内容真的画出来了（由会话行的 `onAppear` 调用）。一次拨号只记一条。
    public func noteFirstRender() async {
        await linkDiagnostics.markFirstRender()
        if let link = carrier as? LinkCarrier { await pushDiagnostics(link) }
    }

    /// 把 App 攒下的阶段记录增量推给连接器（spec 020 的 FR-011）。
    ///
    /// 三条纪律：
    ///   1. **失败当无事**（旧连接器回 `link/unsupported` 是预期内的），下次 install/回前台再试；
    ///   2. 只推 `pending()`（未推过的），水位按连接器确认的 `lastSeq` 前进——不重发也不漏发；
    ///   3. 绝不因为推送失败改变连接状态。
    func pushDiagnostics(_ link: LinkCarrier) async {
        let pending = await link.diagnostics.pending()
        guard !pending.isEmpty, let client else { return }
        let request = LinkDiagnosticsRequest(
            since: await link.diagnostics.pushedUpTo,
            sentAt: Int(Date().timeIntervalSince1970 * 1000),
            dropped: await link.diagnostics.dropped,
            events: pending,
            client: LinkDiagnosticsClient(name: Self.clientName,
                                          version: Self.clientVersion,
                                          build: Self.clientBuild)
        )
        guard let ack = try? await client.pushDiagnostics(request) else { return }
        await link.diagnostics.markPushed(upTo: ack.lastSeq)
    }

    /// 轻量探活 + 恢复。
    ///
    /// 探活用 `_link/hello`（实测 ~134 ms、几百字节，连接器本地应答），**不**用
    /// `client.sessions()`：那条路会拉整份会话列表，失败时还会回退到 734 KB 的旧通道，
    /// 于是"列表慢"被误判成"链路死"，正是风暴的放大器（research §二①②）。
    func probeHost(client: any HostClient, carrier: any DSHCarrier,
                           profile: ConnectionProfile) async {
        let started = Date()
        do {
            _ = try await client.linkHandshake(client: LinkHandshakeRequest(
                clientName: Self.clientName,
                clientVersion: Self.clientVersion,
                clientBuild: Self.clientBuild
            ))
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            _ = supervisor.noteProbe(ok: true)
            await linkDiagnostics.record(kind: "link.probe", detail: [
                "ok": .bool(true), "ms": .int(ms), "fails": .int(supervisor.consecutiveProbeFailures),
            ])
            if !state.isConnected {
                // Carrier 已经把 socket 自愈回来了：同一个 carrier 重装 client，
                // 不建新 socket（FR-005）。
                await install(carrier: carrier, profile: profile,
                              sampleCount: lastSampleCount, closePrevious: false)
            }
        } catch {
            let verdict = supervisor.noteProbe(ok: false)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            await linkDiagnostics.record(kind: "link.probe", detail: [
                "ok": .bool(false), "ms": .int(ms), "fails": .int(supervisor.consecutiveProbeFailures),
            ])
            // 单次失败不判断开（FR-004）：链路抖一下不该让界面闪"重连中"。
            // "几次才算断"由监管决定（`Policy.failuresToDeclareDown`，默认 2）。
            if verdict == .declareDown, state.isConnected {
                state = .connecting("连接中断，正在重连…")
            }
        }
    }
}
