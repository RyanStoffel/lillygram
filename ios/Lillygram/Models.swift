import Foundation

struct Account: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        case active
        case verificationRequired = "verification_required"
        case challengeRequired = "challenge_required"
        case reauthRequired = "reauth_required"
    }

    let id: String
    let username: String
    let status: Status
    let createdAt: Date
    let writesEnabledAt: Date
    let challengeMessage: String?
    let proxyConfigured: Bool
}

struct LoginResponse: Codable {
    let token: String
    let account: Account
}

struct ProfileSummary: Codable, Identifiable, Hashable {
    let username: String
    let fullName: String
    let avatarUrl: String?
    let isVerified: Bool

    var id: String { username.lowercased() }
    var avatar: URL? { avatarUrl.flatMap(URL.init(string:)) }
}

struct Profile: Codable, Identifiable {
    let username: String
    let fullName: String
    let avatarUrl: String?
    let isVerified: Bool
    let biography: String
    let followerCount: Int
    let followingCount: Int
    let mediaCount: Int

    var id: String { username.lowercased() }
    var avatar: URL? { avatarUrl.flatMap(URL.init(string:)) }
}

enum MediaKind: String, Codable {
    case photo
    case video
    case carousel
    case reel
}

struct MediaAsset: Codable {
    let kind: MediaKind
    let thumbnailUrl: String?
    let mediaUrl: String?

    var thumbnail: URL? { thumbnailUrl.flatMap(URL.init(string:)) }
    var media: URL? { mediaUrl.flatMap(URL.init(string:)) }
}

struct InstagramMedia: Codable, Identifiable {
    let id: String
    let code: String?
    let kind: MediaKind
    let caption: String
    let takenAt: Date?
    let user: ProfileSummary
    let thumbnailUrl: String?
    let mediaUrl: String?
    let carouselItems: [MediaAsset]
    let likeCount: Int
    let commentCount: Int
    let sharedReel: Bool

    var thumbnail: URL? { thumbnailUrl.flatMap(URL.init(string:)) }
    var media: URL? { mediaUrl.flatMap(URL.init(string:)) }
}

struct StoryTray: Codable, Identifiable {
    let user: ProfileSummary
    let items: [InstagramMedia]

    var id: String { user.id }
}

struct DirectMessage: Codable, Identifiable {
    let id: String
    let senderId: String
    let text: String
    let timestamp: Date?
    let media: InstagramMedia?
}

struct DirectThread: Codable, Identifiable {
    let id: String
    let title: String
    let users: [ProfileSummary]
    let messages: [DirectMessage]
}

struct Page<Item: Codable>: Codable {
    let items: [Item]
    let nextCursor: String?
}

struct BackendSettings: Codable {
    let account: Account
    let readLimitPerHour: Int
    let writeLimitPerHour: Int
    let warmupDays: Int
}

struct UploadResponse: Codable {
    let media: InstagramMedia
}

struct APIErrorEnvelope: Codable {
    struct Detail: Codable {
        let code: String
        let message: String
    }

    let error: Detail
}
