import Foundation

/// 本地缓存被清空时广播一次。
///
/// 设置页只能清磁盘；屏幕上那个正在打开的会话还握着内存里的记录，下一次节流落盘
/// 就会把文件写回去——用户会看到"清完又回来了"。所以清理必须广播出去，
/// 由持有内存副本的地方（会话模型、图片缓存）一起放手。
extension Notification.Name {
    static let localCachesCleared = Notification.Name("dsh.localCachesCleared")
}
