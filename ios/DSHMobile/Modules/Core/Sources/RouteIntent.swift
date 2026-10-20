import Foundation

/// 跨单元路由意图（纯数据，不含任何界面概念）。
///
/// 设计（025 架构 v2）：功能单元只产意图，导航状态与 View 映射归 App 装配层。
/// 当前落地形态：`SessionRouter` 是它的存储与「取走即拥有」通道（通知点击、
/// 冷启动、深链都经它）；App 侧 RootView 消费意图后驱动 NavigationPath。
public enum RouteIntent: Equatable, Sendable {
    /// 打开某个会话的转写页。
    case openSession(String)
}
