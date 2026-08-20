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
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "网络响应无效"
        case .http(let code):
            return "网络请求失败（HTTP \(code)）"
        case .biz(let code, let message):
            return "接口错误 \(code)：\(message)"
        case .decoding(let detail):
            return detail.isEmpty ? "数据解析失败" : "数据解析失败：\(detail)"
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
    /// nav 接口的硬币字段名是 money
    let money: Double?
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

    // 接口返回键是 "View" / "Related"，convertFromSnakeCase 对无下划线的单词不做大小写转换
    enum CodingKeys: String, CodingKey {
        case view = "View"
        case related = "Related"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        view = try container.decode(VideoView.self, forKey: .view)
        related = (try? container.decode([Lossy<RelatedVideo>].self, forKey: .related))?
            .compactMap { $0.value }
    }

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
        let aid: Int
        let bvid: String
        let title: String
        let pic: String
        let duration: Int
        let owner: Owner?
        let stat: Stat?

        var id: Int { aid }
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

    enum CodingKeys: String, CodingKey {
        case items
        case offset
        case updateBaseline = "update_baseline"
        case hasMore = "has_more"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 逐条容错：个别动态结构异常不影响整页
        items = (try? container.decode([Lossy<DynamicItem>].self, forKey: .items))?
            .compactMap { $0.value } ?? []
        offset = try container.decodeIfPresent(String.self, forKey: .offset)
        updateBaseline = try container.decodeIfPresent(String.self, forKey: .updateBaseline)
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore)
    }
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
        let name: String?
        let face: String?
        let pubTime: String?
    }

    struct ModuleDynamic: Decodable {
        let desc: Desc?
        let major: Major?

        struct Desc: Decodable {
            let text: String?
        }

        struct Major: Decodable {
            let type: String?
            let archive: Archive?
            let draw: Draw?
            let opus: Opus?

            struct Archive: Decodable {
                let aid: String?
                let bvid: String?
                let title: String?
                let cover: String?
                let desc: String?
                let durationText: String?
            }

            struct Draw: Decodable {
                let items: [DrawItem]?

                struct DrawItem: Decodable, Hashable {
                    let src: String?
                    let width: Int?
                    let height: Int?
                }
            }

            struct Opus: Decodable {
                let summary: OpusSummary?

                struct OpusSummary: Decodable {
                    let text: String?
                }
            }
        }
    }

    struct ModuleStat: Decodable {
        let like: StatValue?
        let comment: StatValue?
        let forward: StatValue?

        struct StatValue: Decodable {
            let count: Int?
            let forbidden: Bool?
            let status: Bool?
        }
    }
}

/// 容错解码包装：单个元素解析失败时返回 nil，而不是让整个数组解码失败。
struct Lossy<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

// MARK: - 评论

struct CommentData: Decodable {
    let replies: [CommentItem]
    let hots: [CommentItem]
    let page: Page?

    struct Page: Decodable {
        let count: Int?
        let acount: Int?
    }

    enum CodingKeys: String, CodingKey {
        case replies
        case hots
        case page
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 逐条容错：个别评论结构异常不影响整页
        replies = (try? container.decode([Lossy<CommentItem>].self, forKey: .replies))?
            .compactMap { $0.value } ?? []
        hots = (try? container.decode([Lossy<CommentItem>].self, forKey: .hots))?
            .compactMap { $0.value } ?? []
        page = try container.decodeIfPresent(Page.self, forKey: .page)
    }
}

struct CommentRepliesData: Decodable {
    let replies: [CommentItem]
    let page: CommentData.Page?

    enum CodingKeys: String, CodingKey {
        case replies
        case page
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        replies = (try? container.decode([Lossy<CommentItem>].self, forKey: .replies))?
            .compactMap { $0.value } ?? []
        page = try container.decodeIfPresent(CommentData.Page.self, forKey: .page)
    }
}

struct CommentItem: Decodable, Identifiable {
    let rpid: Int
    let rcount: Int?
    let ctime: Int?
    let like: Int?
    let member: Member?
    let content: Content?
    let replies: [CommentItem]?
    let upAction: UpAction?

    var id: Int { rpid }

    struct Member: Decodable {
        let mid: String
        let uname: String
        let avatar: String
        let levelInfo: LevelInfo?

        struct LevelInfo: Decodable {
            let currentLevel: Int?
        }
    }

    struct Content: Decodable {
        let message: String
    }

    struct UpAction: Decodable {
        let like: Bool?
    }
}
