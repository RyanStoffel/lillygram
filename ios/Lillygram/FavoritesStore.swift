import Foundation

struct FavoriteProfile: Codable, Identifiable, Hashable {
    let username: String
    let fullName: String
    let avatar: String

    var id: String { username.lowercased() }
    var avatarURL: URL? { avatar.isEmpty ? nil : URL(string: avatar) }
}

/// Locally persisted favorites selection: which profiles the home feed is
/// limited to, and whether the one-time onboarding picker has already run.
final class FavoritesStore: ObservableObject {
    private static let favoritesKey = "bi.favoriteProfiles"
    private static let onboardedKey = "bi.onboardingCompleted"

    @Published var favorites: [FavoriteProfile] {
        didSet {
            if let data = try? JSONEncoder().encode(favorites) {
                UserDefaults.standard.set(data, forKey: Self.favoritesKey)
            }
        }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: Self.onboardedKey) }
    }

    /// Skipping onboarding (or emptying the list) disables the favorites
    /// filter entirely rather than blanking the feed.
    var isFilterEnabled: Bool { hasCompletedOnboarding && !favorites.isEmpty }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.favoritesKey),
           let saved = try? JSONDecoder().decode([FavoriteProfile].self, from: data) {
            favorites = saved
        } else {
            favorites = []
        }
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: Self.onboardedKey)
    }
}
