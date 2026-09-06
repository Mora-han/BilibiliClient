import Foundation

/// 直播相关接口：列表 / 房间详情 / 播放流 / 弹幕服务器配置。
struct LiveService {
    private static let base = URL(string: "https://api.live.bilibili.com")!

    /// 直播推荐流（热门直播，按页返回，data 直接是房间数组）
    func recommend(page: Int, pageSize: Int = 50) async throws -> [LiveRoomCard] {
        try await APIClient.shared.get("/room/v1/room/get_user_recommend",
                                       base: Self.base,
                                       query: [
                                           "page": "\(page)",
                                           "page_size": "\(pageSize)",
                                       ])
    }

    /// 直播间详情：标题 / 在线人数 / 分区 / 开播状态等
    func roomInfo(roomId: Int) async throws -> LiveRoomDetail {
        try await APIClient.shared.get("/room/v1/Room/get_info",
                                       base: Self.base,
                                       query: ["room_id": "\(roomId)"])
    }

    /// 主播名片（房间信息不含主播昵称/头像，用于详情页补充展示）
    func anchorInfo(uid: Int) async throws -> LiveAnchorData {
        try await APIClient.shared.get("/live_user/v1/Master/info",
                                       base: Self.base,
                                       query: ["uid": "\(uid)"])
    }

    /// 播放流：HLS（ts / fmp4）直链
    func playInfo(roomId: Int) async throws -> LivePlayInfoData {
        try await APIClient.shared.get("/xlive/web-room/v2/index/getRoomPlayInfo",
                                       base: Self.base,
                                       query: [
                                           "room_id": "\(roomId)",
                                           "protocol": "0,1",
                                           "format": "0,1,2",
                                           "codec": "0,1",
                                           "qn": "10000",
                                           "platform": "web",
                                           "ptype": "8",
                                       ])
    }

    /// 弹幕服务器配置（WebSocket host 列表 + 认证 token）
    func danmuConf(roomId: Int) async throws -> LiveDanmuConf {
        try await APIClient.shared.get("/room/v1/Danmu/getConf",
                                       base: Self.base,
                                       query: [
                                           "room_id": "\(roomId)",
                                           "platform": "pc",
                                           "player": "web",
                                       ])
    }
}
