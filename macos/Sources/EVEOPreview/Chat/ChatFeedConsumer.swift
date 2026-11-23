// SPDX-License-Identifier: GPL-3.0-or-later
//
// 预警与翻译两个功能控制器的共同接口（docs/macos/design-intel-translate.md 9.2 节）。ChatFeatureController 只通过
// 这个协议调用它们：把配置与运行时状态交给它们，把属于它们的日志事件交给它们，再向它们要浮窗的内容。
// 两个功能（IntelFeedController、TranslationController）彼此不引用，也不引用浮窗面板与跟踪服务。
// 时钟：日志里的时间与「多久以前」用墙上时钟（1970 年以来的秒数）。

import EVEOPreviewCore

/// 交给功能控制器的上下文。任何一项变了都会再调一次 `update(context:)`。
struct ChatFeedContext {
    /// 当前配置方案（含 intel 与 translation 的设置）。
    var profile: Profile
    /// 全局设置（日志目录、模型服务的接口设置）。
    var general: GeneralSettings
    /// 星图数据；还没读完、缺失或无效时为 nil。
    var staticData: EVEStaticData?
    /// 活动角色；没有时为 nil。
    var activeCharacter: String?
    /// 聊天日志跟踪服务的状态。
    var chatLogStatus: ChatLogStatus
    /// 正在跟踪的聊天日志文件的收听者与频道；跟踪服务还没扫描完时为 nil。
    var followedChannels: [FollowedChatChannel]? = nil
}

/// 一个聊天功能（预警或翻译）。全部方法在主线程调用。
@MainActor protocol ChatFeedConsumer: AnyObject {
    /// 这个功能对应的浮窗。
    var kind: OverlayKind { get }
    /// 内容或状态变了，请求刷新浮窗与设置窗口。
    var onChange: (@MainActor () -> Void)? { get set }
    /// 配置、星图数据、活动角色、聊天日志状态或界面语言变了。
    func update(context: ChatFeedContext)
    /// 属于本功能的事件，按日志里的先后顺序。
    func ingest(_ events: [ChatLogEvent])
    /// 浮窗当前的内容。now 是墙上时钟的秒数。
    func content(now: Double) -> OverlayContent
    /// 下一次要按时间刷新的时刻（墙上时钟）；不用时返回 nil。
    func nextRefresh(now: Double) -> Double?
    /// 清空某个角色的缓冲；character 为 nil 时清空全部角色的。
    func clear(character: String?)
    /// 停止：取消定时与在途的请求。应用退出时调用。
    func stop()
}
