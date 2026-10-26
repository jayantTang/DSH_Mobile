import DSHChatDomain
import DSHKit
import Foundation

/// 概要 v2（`fold: "summary"`）的 JSON 夹具。
///
/// 与连接器 `lib/history/fold-summary.js` 的回包同形：讲话 + `+link/fold`（`v:2`）
/// + 回答 + 轮次边界。工具正文、思考正文、完整 args 都不在页里 —— 步骤只有
/// `name/preview/status/bytes/resultSeq` 元数据，这正是 M6 要投影的东西。
enum FoldSummaryV2Fixtures {

    /// 一轮：两段过程（中间夹一段讲话），三条步骤（含 ok / error），正式回答在末尾。
    static let twoGroupWindow = """
    {"records":[
      {"event":{"type":"turn/start","seq":1,"time":1000,"data":{"turn":1}}},
      {"event":{"type":"user/message","seq":2,"time":1001,"data":{
        "source":{"kind":"user","rpcId":"r-1"},
        "content":[{"type":"text","text":"问题一"}]}}},
      {"event":{"type":"+link/fold","seq":3,"time":1002,"data":{
        "v":2,"turn":1,"startSeq":3,"endSeq":4,"durationMs":139000,"endReason":"completed",
        "activities":{"commands":2},
        "groups":[{"startSeq":3,"endSeq":4,"activities":{"commands":1},"toolCount":1,
          "steps":[
            {"seq":3,"kind":"tools","name":"bash","preview":"swift build","status":"ok","resultSeq":4,"bytes":900},
            {"seq":4,"kind":"reasoning","name":"thinking","preview":"","status":"ok","bytes":1500}]}]}}},
      {"event":{"type":"assistant/message","seq":5,"time":1005,"data":{
        "turn":1,"step":2,
        "message":{"role":"assistant","content":[{"type":"text","text":"中间讲话一"}]}}}},
      {"event":{"type":"+link/fold","seq":6,"time":1006,"data":{
        "v":2,"turn":1,"startSeq":6,"endSeq":7,"durationMs":139000,"endReason":"completed",
        "activities":{"read":1},
        "groups":[{"startSeq":6,"endSeq":7,"activities":{"read":1},"toolCount":1,
          "steps":[
            {"seq":6,"kind":"tools","name":"read","preview":"a.swift","status":"error","resultSeq":7,"bytes":12}]}]}}},
      {"event":{"type":"assistant/message","seq":8,"time":1008,"data":{
        "turn":1,"step":3,
        "message":{"role":"assistant","content":[{"type":"text","text":"最终回答一"}]}}}},
      {"event":{"type":"turn/end","seq":9,"time":1009,"data":{"turn":1,"reason":{"kind":"completed"}}}}
    ],"startSeq":1,"endSeq":9,"hasMore":false}
    """

    /// 完整的一轮用一张图回答：工具段在概要里，回答是 agent 代发的图片。
    static let imageAnswerWindow = """
    {"records":[
      {"event":{"type":"turn/start","seq":1,"time":2000,"data":{"turn":2}}},
      {"event":{"type":"user/message","seq":2,"time":2001,"data":{
        "source":{"kind":"user","rpcId":"r-2"},
        "content":[{"type":"text","text":"截个图"}]}}},
      {"event":{"type":"+link/fold","seq":3,"time":2002,"data":{
        "v":2,"turn":2,"startSeq":3,"endSeq":4,"durationMs":8000,"endReason":"completed",
        "activities":{"commands":1},
        "groups":[{"startSeq":3,"endSeq":4,"activities":{"commands":1},"toolCount":1,
          "steps":[
            {"seq":3,"kind":"tools","name":"bash","preview":"screencapture","status":"ok","resultSeq":4,"bytes":40}]}]}}},
      {"event":{"type":"agent/inbox/spliced","seq":5,"time":2005,"data":{
        "target":"next-turn",
        "inserted":[{"source":{"kind":"user","rpcId":"agent-2"},
          "content":[{"type":"image","attachment":{"attachmentId":"att-9","mediaType":"image/png","bytes":20480,"width":390,"height":844}}]}]}}},
      {"event":{"type":"turn/end","seq":6,"time":2006,"data":{"turn":2,"reason":{"kind":"completed"}}}}
    ],"startSeq":1,"endSeq":6,"hasMore":false}
    """

    /// 运行中的一轮：没有轮次结束边界，最后一段概要有在跑的步骤，还有一句中间讲话。
    static let runningWindow = """
    {"records":[
      {"event":{"type":"turn/start","seq":1,"time":3000,"data":{"turn":3}}},
      {"event":{"type":"user/message","seq":2,"time":3001,"data":{
        "source":{"kind":"user","rpcId":"r-3"},
        "content":[{"type":"text","text":"跑一下靶向用例"}]}}},
      {"event":{"type":"+link/fold","seq":3,"time":3002,"data":{
        "v":2,"turn":3,"startSeq":3,"endSeq":4,"durationMs":null,"endReason":null,
        "activities":{"commands":1},
        "groups":[{"startSeq":3,"endSeq":4,"activities":{"commands":1},"toolCount":1,
          "steps":[
            {"seq":3,"kind":"tools","name":"bash","preview":"swift test --filter DSHChatDomainTests","status":"running"},
            {"seq":4,"kind":"reasoning","name":"thinking","preview":"","status":"ok","bytes":99}]}]}}},
      {"event":{"type":"assistant/message","seq":5,"time":3005,"data":{
        "turn":3,"step":2,
        "message":{"role":"assistant","content":[{"type":"text","text":"先把靶向用例跑起来"}]}}}}
    ],"startSeq":1,"endSeq":5,"hasMore":false}
    """

    /// 轮次号缺失（连接器给 `null`）的概要：只能按 startSeq 落在哪一段来认领。
    static let nullTurnWindow = """
    {"records":[
      {"event":{"type":"turn/start","seq":1,"time":4000,"data":{"turn":0}}},
      {"event":{"type":"user/message","seq":2,"time":4001,"data":{
        "source":{"kind":"user","rpcId":"r-4"},
        "content":[{"type":"text","text":"没有轮次号的一句"}]}}},
      {"event":{"type":"+link/fold","seq":3,"time":4002,"data":{
        "v":2,"turn":null,"startSeq":3,"endSeq":3,"durationMs":2000,"endReason":"completed",
        "activities":{"search":1},
        "groups":[{"startSeq":3,"endSeq":3,"activities":{"search":1},"toolCount":1,
          "steps":[
            {"seq":3,"kind":"tools","name":"grep","preview":"needle","status":"ok","resultSeq":3,"bytes":7}]}]}}},
      {"event":{"type":"assistant/message","seq":4,"time":4004,"data":{
        "turn":0,"step":2,
        "message":{"role":"assistant","content":[{"type":"text","text":"找到了"}]}}}},
      {"event":{"type":"turn/end","seq":5,"time":4005,"data":{"turn":0,"reason":{"kind":"completed"}}}}
    ],"startSeq":1,"endSeq":5,"hasMore":false}
    """

    static func timeline(_ json: String) throws -> ChatTimeline {
        let value = try JSONDecoder().decode(HistoryWindowValue.self, from: Data(json.utf8))
        var timeline = ChatTimeline()
        timeline.reset(with: value.records)
        return timeline
    }

    /// 概要 v2 的时间线必须把概要交给投影，才有分组与步骤。
    static func plan(_ timeline: ChatTimeline) -> TranscriptProcessFold.Plan {
        TranscriptProcessFold.plan(
            items: timeline.items,
            isTurnOpen: timeline.isTurnOpen,
            currentTurn: timeline.currentTurn,
            summaries: timeline.foldSummaries)
    }
}
