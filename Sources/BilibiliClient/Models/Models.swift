import Foundation

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
        let shortLinkV2: String?
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
    let basic: Basic?
    /// 转发动态的“原动态”（仅 DYNAMIC_TYPE_FORWARD 存在）。
    /// 独立类型承载，避免结构体自递归。
    let orig: DynamicOrigin?
    let modules: Modules

    var id: String { idStr }

    enum CodingKeys: String, CodingKey {
        case idStr
        case type
        case basic
        case orig
        case modules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        idStr = try container.decode(String.self, forKey: .idStr)
        type = (try? container.decode(String.self, forKey: .type)) ?? ""
        basic = try container.decodeIfPresent(Basic.self, forKey: .basic)
        // orig 结构异常时降级为无引用内容，不影响整条动态展示
        orig = (try? container.decode(DynamicOrigin.self, forKey: .orig)) ?? nil
        modules = (try? container.decode(Modules.self, forKey: .modules))
            ?? Modules(moduleAuthor: nil, moduleDynamic: nil, moduleStat: nil)
    }

    struct Basic: Decodable {
        /// 评论所属对象 id（带图动态为相簿 id，其余为动态 id）
        let commentIdStr: String?
        /// 评论类型（视频=1，带图动态=11，文字/转发动态=17）
        let commentType: Int?
        let ridStr: String?
    }

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
                let id: Int?
                let items: [DrawItem]?

                enum CodingKeys: String, CodingKey {
                    case id
                    case items
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    id = try container.decodeIfPresent(Int.self, forKey: .id)
                    items = (try? container.decode([Lossy<DrawItem>].self, forKey: .items))?
                        .compactMap(\.value)
                }

                struct DrawItem: Decodable, Hashable {
                    let src: String?
                    let width: Int?
                    let height: Int?
                }
            }

            struct Opus: Decodable {
                let summary: OpusSummary?
                let pics: [OpusPic]?

                enum CodingKeys: String, CodingKey {
                    case summary
                    case pics
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    summary = try container.decodeIfPresent(OpusSummary.self, forKey: .summary)
                    // pics 常见为对象数组；个别接口返回字符串数组，做双格式容错
                    if let objects = (try? container.decode([Lossy<OpusPic>].self, forKey: .pics)) {
                        pics = objects.compactMap(\.value)
                    } else if let strings = try? container.decode([String].self, forKey: .pics) {
                        pics = strings.map { OpusPic(url: $0) }
                    } else {
                        pics = nil
                    }
                }

                struct OpusSummary: Decodable {
                    let text: String?
                }

                struct OpusPic: Decodable, Hashable {
                    /// 新版接口图片字段为 url，旧版为 src
                    let url: String?
                    let src: String?
                    let width: Int?
                    let height: Int?

                    init(src: String? = nil,
                         url: String? = nil,
                         width: Int? = nil,
                         height: Int? = nil) {
                        self.src = src
                        self.url = url
                        self.width = width
                        self.height = height
                    }
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


/// 转发动态中的“原动态”内容（结构与动态主体相同）。
struct DynamicOrigin: Decodable {
    let idStr: String?
    let type: String?
    let basic: DynamicItem.Basic?
    let modules: DynamicItem.Modules?
}

/// 动态详情（/x/polymer/web-dynamic/v1/detail）
struct DynamicDetailData: Decodable {
    let item: DynamicItem?
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
    /// 当前登录用户是否已点赞：0 = 未赞，1 = 已赞（未登录时可能缺失）
    let action: Int?
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

// MARK: - 关注关系

/// /x/relation 返回的关注关系
struct RelationStateData: Decodable {
    let attribute: Int?
    let relation: Relation?

    struct Relation: Decodable {
        /// 0=未关注，1=悄悄关注，2=已关注，3=已互粉，6=已关注（特殊）
        let attribute: Int
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attribute = try container.decodeIfPresent(Int.self, forKey: .attribute)
        relation = try container.decodeIfPresent(Relation.self, forKey: .relation)
    }

    private enum CodingKeys: String, CodingKey {
        case attribute
        case relation
    }

    /// 是否处于“已关注”状态（拉黑等异常关系不计入）
    var isFollowing: Bool {
        let value = attribute ?? relation?.attribute
        return value.map { [1, 2, 3, 6].contains($0) } ?? false
    }
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

/// 按关键词查 UP 投稿（空关键词 = 全部），无风控校验
struct RecArchivesData: Decodable {
    let archives: [SeriesArchive]

    enum CodingKeys: String, CodingKey {
        case archives
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        archives = (try? container.decode([Lossy<SeriesArchive>].self, forKey: .archives))?
            .compactMap { $0.value } ?? []
    }
}

struct SeriesArchive: Decodable, Identifiable, Hashable {
    let aid: Int?
    let bvid: String?
    let title: String?
    let pic: String?
    let duration: Int?
    let pubdate: Int?
    let stat: StatView?

    var id: Int { aid ?? 0 }

    struct StatView: Decodable, Hashable {
        let view: Int?
    }
}

// MARK: - 直播

/// 直播推荐/热门卡片（/room/v1/room/get_user_recommend，data 直接是数组）
struct LiveRoomCard: Decodable, Identifiable, Hashable {
    let roomid: Int
    let uid: Int?
    let uname: String?
    let title: String?
    let online: Int?
    let userCover: String?
    let systemCover: String?
    let face: String?
    let areaName: String?
    let watchedShow: WatchedShow?

    var id: Int { roomid }

    struct WatchedShow: Decodable, Hashable {
        let textSmall: String?
    }

    /// 封面：优先主播自定义封面，其次系统封面（热门榜大图）。
    var cover: String {
        userCover ?? systemCover ?? ""
    }

    /// 观看人数展示文本（如 "5494.3万"）。
    var watchingText: String? {
        if let text = watchedShow?.textSmall, !text.isEmpty { return text }
        guard let online, online > 0 else { return nil }
        return "\(online)"
    }
}

/// 直播间详情（/room/v1/Room/get_info）
struct LiveRoomDetail: Decodable, Hashable {
    let roomId: Int
    let uid: Int
    let title: String?
    let online: Int
    let liveStatus: Int?
    let cover: String?
    let userCover: String?
    let keyframe: String?
    let areaName: String?
    let parentAreaName: String?
    let description: String?
    let liveTime: Int?

    var isLive: Bool { liveStatus == 1 }
}

/// 直播间主播名片（/live_user/v1/Master/info）
struct LiveAnchorData: Decodable {
    let info: Info?
    let followerNum: Int?

    struct Info: Decodable {
        let uid: Int?
        let uname: String?
        let face: String?
        let sign: String?
        let official: Int?
    }
}

/// 播放流（/xlive/web-room/v2/index/getRoomPlayInfo）
struct LivePlayInfoData: Decodable {
    let roomId: Int?
    let uid: Int?
    let liveStatus: Int?
    let playurlInfo: PlayURLInfo?

    struct PlayURLInfo: Decodable {
        let playurl: PlayURL?

        struct PlayURL: Decodable {
            let stream: [Stream]?
            let gQnDesc: [QnDesc]?

            struct QnDesc: Decodable {
                let qn: Int?
                let desc: String?
            }
        }
    }

    struct Stream: Decodable {
        let protocolName: String?
        let format: [Format]?

        struct Format: Decodable {
            let formatName: String?
            let codec: [Codec]?

            struct Codec: Decodable {
                let codecName: String?
                let baseUrl: String?
                let urlInfo: [URLInfo]?

                struct URLInfo: Decodable {
                    let host: String?
                    let extra: String?
                }
            }
        }
    }
}

/// 弹幕服务器配置（/room/v1/Danmu/getConf，无需 WBI/登录）
struct LiveDanmuConf: Decodable {
    let token: String?
    let host: String?
    let port: Int?
    let hostServerList: [Host]?

    struct Host: Decodable, Hashable {
        let host: String?
        let port: Int?
        let wssPort: Int?
    }
}
