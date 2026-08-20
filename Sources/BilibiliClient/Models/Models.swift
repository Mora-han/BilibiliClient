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
    let acceptQuality: [Int]?
    let acceptDescription: [String]?

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
        case updateBaseline = "updateBaseline"
        case hasMore = "hasMore"
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
        let mid: Int?
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

// MARK: - 收藏夹

struct FavFolderData: Decodable {
    let count: Int?
    let list: [FavFolder]?
}

struct FavFolder: Decodable, Identifiable {
    let id: Int
    let title: String?
    let mediaCount: Int?
}

struct FavResourceData: Decodable {
    let medias: [FavMedia]
    let hasMore: Bool?

    enum CodingKeys: String, CodingKey {
        case medias
        case hasMore = "hasMore"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        medias = (try? container.decode([Lossy<FavMedia>].self, forKey: .medias))?
            .compactMap { $0.value } ?? []
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore)
    }
}

struct FavMedia: Decodable, Identifiable {
    let id: Int
    let type: Int?
    let title: String?
    let cover: String?
    let intro: String?
    let duration: Int?
    let upper: Owner?
    let cntInfo: CntInfo?
    let bvid: String?
    let favTime: Int?
    let attr: Int?

    struct CntInfo: Decodable {
        let collect: Int?
        let play: Int?
        let danmaku: Int?
    }

    /// 0 = 正常；1/9 = 已失效
    var isUsable: Bool {
        (attr ?? 0) == 0
    }
}

// MARK: - 历史记录

struct HistoryData: Decodable {
    let cursor: HistoryCursor?
    let list: [HistoryItem]

    enum CodingKeys: String, CodingKey {
        case cursor
        case list
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try container.decodeIfPresent(HistoryCursor.self, forKey: .cursor)
        list = (try? container.decode([Lossy<HistoryItem>].self, forKey: .list))?
            .compactMap { $0.value } ?? []
    }
}

struct HistoryCursor: Decodable {
    let max: Int?
    let viewAt: Int?
    let business: String?
    let ps: Int?
}

struct HistoryItem: Decodable, Identifiable {
    let title: String?
    let cover: String?
    let authorName: String?
    let viewAt: Int?
    let progress: Int?
    let duration: Int?
    let badge: String?
    let showTitle: String?
    let tagName: String?
    let history: Detail?

    var id: Int { history?.oid ?? 0 }

    struct Detail: Decodable {
        let oid: Int?
        let bvid: String?
        let page: Int?
        let cid: Int?
    }
}

// MARK: - 稍后再看

struct ToViewData: Decodable {
    let count: Int?
    let list: [ToViewItem]

    enum CodingKeys: String, CodingKey {
        case count
        case list
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        count = try container.decodeIfPresent(Int.self, forKey: .count)
        list = (try? container.decode([Lossy<ToViewItem>].self, forKey: .list))?
            .compactMap { $0.value } ?? []
    }
}

struct ToViewItem: Decodable, Identifiable {
    let aid: Int
    let bvid: String?
    let pic: String?
    let title: String?
    let duration: Int?
    let owner: Owner?
    let stat: Stat?
    let progress: Int?
    let addAt: Int?
    let cid: Int?

    var id: Int { aid }
}

// MARK: - 搜索

struct SearchData: Decodable {
    let numResults: Int?
    let numPages: Int?
    let result: [SearchVideo]

    enum CodingKeys: String, CodingKey {
        case numResults = "numResults"
        case numPages = "numPages"
        case result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        numResults = try container.decodeIfPresent(Int.self, forKey: .numResults)
        numPages = try container.decodeIfPresent(Int.self, forKey: .numPages)
        result = (try? container.decode([Lossy<SearchVideo>].self, forKey: .result))?
            .compactMap { $0.value } ?? []
    }
}

struct SearchVideo: Decodable, Identifiable {
    let id: Int
    let aid: Int?
    let bvid: String?
    let author: String?
    let title: String?
    let description: String?
    let pic: String?
    let play: Int?
    let videoReview: Int?
    let favorites: Int?
    let pubdate: Int?
    let duration: String?
    let typename: String?

    /// 接口返回的标题带 <em class="keyword"> 高亮标签，去掉后用于展示。
    var cleanTitle: String {
        guard let title else { return "" }
        return title.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}

// MARK: - 分区（官方主分区，tid 来自视频分区一览文档）

struct BiliZone: Identifiable, Hashable {
    let id: Int
    let name: String
    let icon: String
}

enum BiliZones {
    static let main: [BiliZone] = [
        BiliZone(id: 1, name: "动画", icon: "tv"),
        BiliZone(id: 13, name: "番剧", icon: "play.tv"),
        BiliZone(id: 167, name: "国创", icon: "flag"),
        BiliZone(id: 3, name: "音乐", icon: "music.note"),
        BiliZone(id: 129, name: "舞蹈", icon: "figure.dance"),
        BiliZone(id: 4, name: "游戏", icon: "gamecontroller"),
        BiliZone(id: 36, name: "知识", icon: "books.vertical"),
        BiliZone(id: 188, name: "科技", icon: "gearshape.2"),
        BiliZone(id: 234, name: "运动", icon: "figure.run"),
        BiliZone(id: 223, name: "汽车", icon: "car"),
        BiliZone(id: 160, name: "生活", icon: "house"),
        BiliZone(id: 211, name: "美食", icon: "fork.knife"),
        BiliZone(id: 217, name: "动物", icon: "pawprint"),
        BiliZone(id: 119, name: "鬼畜", icon: "face.smiling.inverse"),
        BiliZone(id: 5, name: "娱乐", icon: "star"),
        BiliZone(id: 181, name: "影视", icon: "film"),
        BiliZone(id: 177, name: "纪录片", icon: "camera"),
    ]
}

// MARK: - 热门视频 / 排行榜

struct PopularData: Decodable {
    let list: [PopularVideo]
    let noMore: Bool?

    enum CodingKeys: String, CodingKey {
        case list
        case noMore = "noMore"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        list = (try? container.decode([Lossy<PopularVideo>].self, forKey: .list))?
            .compactMap { $0.value } ?? []
        noMore = try container.decodeIfPresent(Bool.self, forKey: .noMore)
    }
}

struct RankingData: Decodable {
    let list: [PopularVideo]

    enum CodingKeys: String, CodingKey {
        case list
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        list = (try? container.decode([Lossy<PopularVideo>].self, forKey: .list))?
            .compactMap { $0.value } ?? []
    }
}

struct PopularVideo: Decodable, Identifiable, Hashable {
    let aid: Int?
    let bvid: String?
    let cid: Int?
    let title: String?
    let pic: String?
    let duration: Int?
    let pubdate: Int?
    let owner: Owner?
    let stat: Stat?
    let tname: String?

    var id: Int { aid ?? 0 }
}

// MARK: - 热门搜索（首页热门标签）

struct HotSearchData: Decodable {
    let trending: Trending?

    struct Trending: Decodable {
        let list: [HotItem]?
    }

    struct HotItem: Decodable, Hashable {
        let keyword: String?
    }
}

// MARK: - 关注列表

struct FollowingsData: Decodable {
    let list: [FollowedUser]
    let total: Int?

    enum CodingKeys: String, CodingKey {
        case list
        case total
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        list = (try? container.decode([Lossy<FollowedUser>].self, forKey: .list))?
            .compactMap { $0.value } ?? []
        total = try container.decodeIfPresent(Int.self, forKey: .total)
    }
}

struct FollowedUser: Decodable, Identifiable, Hashable {
    let mid: Int
    let uname: String?
    let face: String?

    var id: Int { mid }
}

// MARK: - UP 主页

/// 用户名片（/x/web-interface/card），不需要 WBI 和特殊 Cookie
struct UpCardData: Decodable {
    let card: Card?
    let follower: Int?

    struct Card: Decodable {
        let mid: String?
        let name: String?
        let face: String?
        let sign: String?
        let fans: Int?
        let attention: Int?
        let levelInfo: LevelInfo?
        let official: Official?

        struct LevelInfo: Decodable {
            let currentLevel: Int?
        }

        struct Official: Decodable {
            let title: String?
            let role: Int?
        }

        enum CodingKeys: String, CodingKey {
            case mid
            case name
            case face
            case sign
            case fans
            case attention
            case levelInfo = "levelInfo"
            case official = "Official"
        }
    }
}

struct UpVideosData: Decodable {
    let list: UpList?

    struct UpList: Decodable {
        let vlist: [UpVideo]?
    }
}

struct UpVideo: Decodable, Identifiable, Hashable {
    let aid: Int?
    let bvid: String?
    let pic: String?
    let title: String?
    let description: String?
    let play: Int?
    let duration: Int?
    let created: Int?
    let length: String?

    var id: Int { aid ?? 0 }
}
