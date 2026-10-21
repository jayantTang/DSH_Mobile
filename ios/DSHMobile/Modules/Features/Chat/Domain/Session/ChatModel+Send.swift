import Foundation

/// 发送入口：实现移到 ChatSendService，ChatModel 只保留对外 API。
extension ChatModel {
    public func send() async { await sendService.send() }

    public func sendFile(named name: String, data: Data) async {
        await sendService.sendFile(named: name, data: data)
    }

    public func sendFile(named name: String, fileURL: URL) async {
        await sendService.sendFile(named: name, fileURL: fileURL)
    }
}
