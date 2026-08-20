import Foundation

// MARK: - 通用响应包装

struct BiliResponse<T: Decodable>: Decodable {
    let code: Int
    let message: String
    let data: T?
    let ttl: Int?
}

// MARK: - 错误

enum APIError: LocalizedError {
    case invalidResponse
    case http(Int)
    case biz(code: Int, message: String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "网络响应无效"
        case .http(let code):
            return "网络请求失败（HTTP \(code)）"
        case .biz(let code, let message):
            return "接口错误 \(code)：\(message)"
        case .decoding:
            return "数据解析失败"
        }
    }
}

// MARK: - 导航栏 / 用户信息

struct NavData: Decodable {
    let isLogin: Bool
    let mid: Int?
    let uname: String?
    let face: String?
    let levelInfo: LevelInfo?
    let coin: Double?
    let following: Int?
    let follower: Int?
    let wbiImg: WbiImg?

    struct LevelInfo: Decodable {
        let currentLevel: Int
    }

    struct WbiImg: Decodable {
        let imgUrl: String
        let subUrl: String
    }
}

// MARK: - 推荐流

struct RecommendItem: Decodable, Identifiable, Hashable {
    let id: Int
    let bvid: String
    let cid: Int
    let title: String
    let pic: String
    let duration: Int
    let owner: Owner?
    let stat: Stat?
    let rcmdReason: RcmdReason?

    struct RcmdReason: Decodable, Hashable {
        let content: String?
    }
}

struct Owner: Decodable, Hashable {
    let mid: Int
    let name: String
    let face: String?
}

struct Stat: Decodable, Hashable {
    let view: Int
    let danmaku: Int
    let like: Int
    let coin: Int?
    let favorite: Int?
    let reply: Int?
}

// MARK: - 视频详情

struct VideoDetailData: Decodable {
    let view: VideoView
    let related: [RelatedVideo]?

    struct VideoView: Decodable {
        let bvid: String
        let aid: Int
        let cid: Int
        let title: String
        let desc: String
        let pic: String
        let pubdate: Int
        let duration: Int
        let owner: Owner
        let stat: Stat
        let pages: [VideoPage]?
    }

    struct RelatedVideo: Decodable, Identifiable, Hashable {
        let id: Int
        let bvid: String
        let title: String
        let pic: String
        let duration: Int
        let owner: Owner?
        let stat: Stat?
    }

    struct VideoPage: Decodable, Identifiable {
        let cid: Int
        let page: Int
        let part: String
        let duration: Int

        var id: Int { page }
    }
}

// MARK: - 播放地址

struct PlayURLData: Decodable {
    let quality: Int?
    let timelength: Int?
    let durl: [DURL]?
    let dash: Dash?

    struct DURL: Decodable {
        let url: String
        let backupUrl: [String]?
        let size: Int
        let length: Int
    }

    struct Dash: Decodable {
        let duration: Int?
        let video: [DashStream]?
        let audio: [DashStream]?
    }

    struct DashStream: Decodable {
        let id: Int
        let baseUrl: String
        let backupUrl: [String]?
        let bandwidth: Int
        let mimeType: String?
        let codecs: String?
        let width: Int?
        let height: Int?
        let frameRate: String?
        let segmentBase: SegmentBase?

        struct SegmentBase: Decodable {
            let initialization: String
            let indexRange: String
        }
    }
}

// MARK: - 动态流

struct DynamicFeedData: Decodable {
    let items: [DynamicItem]
    let offset: String?
    let updateBaseline: String?
    let hasMore: Bool?
}

struct DynamicItem: Decodable, Identifiable {
    let idStr: String
    let type: String
    let modules: Modules

    var id: String { idStr }

    struct Modules: Decodable {
        let moduleAuthor: ModuleAuthor?
        let moduleDynamic: ModuleDynamic?
        let moduleStat: ModuleStat?
    }

    struct ModuleAuthor: Decodable {
        let name: String
        let face: String
        let pubTime: String?
    }

    struct ModuleDynamic: Decodable {
        let desc: Desc?
        let major: Major?

        struct Desc: Decodable {
            let text: String
        }

        struct Major: Decodable {
            let type: String?
            let archive: Archive?
            let draw: Draw?
            let opus: Opus?

            struct Archive: Decodable {
                let aid: String
                let bvid: String
                let title: String
                let cover: String
                let desc: String
                let durationText: String?
            }

            struct Draw: Decodable {
                let items: [DrawItem]?

                struct DrawItem: Decodable, Hashable {
                    let src: String
                    let width: Int?
                    let height: Int?
                }
            }

            struct Opus: Decodable {
                let summary: OpusSummary?

                struct OpusSummary: Decodable {
                    let text: String
                }
            }
        }
    }

    struct ModuleStat: Decodable {
        let like: Int
        let comment: Int
        let forward: Int
    }
}
