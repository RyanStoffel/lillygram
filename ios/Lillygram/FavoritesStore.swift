import Foundation

/// The native favorites filter is local to Lillygram and isolated per Instagram account.
/// Empty selection fails closed: Home shows no algorithmic feed and asks for favorites.
final class FavoritesStore: ObservableObject {
    @Published private(set) var accountID: String?
    @Published var favorites: [ProfileSummary] = [] {
        didSet { persist() }
    }

    var usernames: Set<String> {
        Set(favorites.map { $0.username.lowercased() })
    }

    func useAccount(_ accountID: String?) {
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        guard let accountID,
              let data = UserDefaults.standard.data(forKey: key(for: accountID)),
              let decoded = try? JSONDecoder().decode([ProfileSummary].self, from: data)
        else {
            favorites = []
            return
        }
        favorites = decoded
    }

    func toggle(_ profile: ProfileSummary) {
        if let index = favorites.firstIndex(where: { $0.id == profile.id }) {
            favorites.remove(at: index)
        } else {
            favorites.append(profile)
        }
    }

    func contains(_ profile: ProfileSummary) -> Bool {
        favorites.contains { $0.id == profile.id }
    }

    private func persist() {
        guard let accountID,
              let data = try? JSONEncoder().encode(favorites)
        else { return }
        UserDefaults.standard.set(data, forKey: key(for: accountID))
    }

    private func key(for accountID: String) -> String {
        "lillygram.favoriteProfiles.\(accountID)"
    }
}
