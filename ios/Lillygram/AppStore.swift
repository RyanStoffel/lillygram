import Foundation

@MainActor
final class AppStore: ObservableObject {
    enum Phase: Equatable {
        case restoring
        case signedOut
        case active
        case verificationRequired
        case challengeRequired
        case reauthRequired
    }

    @Published private(set) var phase: Phase = .restoring
    @Published private(set) var account: Account?
    @Published private(set) var feed: [InstagramMedia] = []
    @Published private(set) var stories: [StoryTray] = []
    @Published private(set) var threads: [DirectThread] = []
    @Published private(set) var backendSettings: BackendSettings?
    @Published var errorMessage: String?
    @Published private(set) var isSigningIn = false
    @Published private(set) var isLoadingFeed = false
    @Published private(set) var isLoadingStories = false
    @Published private(set) var isLoadingThreads = false
    @Published private(set) var isUploading = false

    let favorites: FavoritesStore

    private var token: String?
    private var rawFeed: [InstagramMedia] = []
    private var feedCursor: String?
    private var didLoadFeed = false
    private var didLoadStories = false
    private var didLoadThreads = false

    init(favorites: FavoritesStore) {
        self.favorites = favorites
    }

    func restoreSession() async {
        guard let baseURL = BackendConfiguration.serverURL,
              let storedToken = AppTokenStore.load()
        else {
            phase = .signedOut
            return
        }
        token = storedToken
        do {
            let restored = try await APIClient(baseURL: baseURL, token: storedToken).sessionAccount()
            applyAccount(restored)
        } catch {
            if case let APIClientError.rejected(status, _) = error, status == 401 {
                AppTokenStore.clear()
                token = nil
                phase = .signedOut
            } else {
                phase = .signedOut
                errorMessage = error.localizedDescription
            }
        }
    }

    func signIn(
        serverURL: String,
        username: String,
        password: String,
        verificationCode: String,
        proxyURL: String
    ) async {
        guard let parsed = Self.validatedBackendURL(serverURL) else {
            errorMessage = "Use an HTTPS backend URL. HTTP is allowed only for localhost."
            return
        }
        BackendConfiguration.serverURLString = parsed.absoluteString
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }
        do {
            let response = try await APIClient(baseURL: parsed).login(
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password,
                verificationCode: verificationCode,
                proxyURL: proxyURL
            )
            try AppTokenStore.save(response.token)
            token = response.token
            applyAccount(response.account)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveTOTPSeed(_ seed: String?) async -> Bool {
        guard !isSigningIn else { return false }
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }
        do {
            let updated = try await client().setTOTPSeed(seed)
            applyAccount(updated)
            return true
        } catch {
            await handleOperationError(error)
            return false
        }
    }

    func disconnect() {
        AppTokenStore.clear()
        token = nil
        account = nil
        favorites.useAccount(nil)
        rawFeed = []
        feed = []
        stories = []
        threads = []
        backendSettings = nil
        didLoadFeed = false
        didLoadStories = false
        didLoadThreads = false
        phase = .signedOut
    }

    func loadFeed(reset: Bool = false) async {
        guard phase == .active, !isLoadingFeed else { return }
        guard !favorites.usernames.isEmpty else {
            rawFeed = []
            feed = []
            feedCursor = nil
            didLoadFeed = true
            return
        }
        if didLoadFeed && !reset { return }
        if reset {
            rawFeed = []
            feed = []
            feedCursor = nil
        }
        isLoadingFeed = true
        errorMessage = nil
        defer { isLoadingFeed = false }
        do {
            let page = try await client().feed(cursor: feedCursor)
            rawFeed.append(contentsOf: page.items.filter { $0.kind != .reel })
            feedCursor = page.nextCursor
            didLoadFeed = true
            refilterFeed()
        } catch {
            await handleOperationError(error)
        }
    }

    func loadMoreFeed() async {
        guard phase == .active, !isLoadingFeed, let feedCursor else { return }
        isLoadingFeed = true
        defer { isLoadingFeed = false }
        do {
            let page = try await client().feed(cursor: feedCursor)
            rawFeed.append(contentsOf: page.items.filter { $0.kind != .reel })
            self.feedCursor = page.nextCursor
            refilterFeed()
        } catch {
            await handleOperationError(error)
        }
    }

    func refilterFeed() {
        let selected = favorites.usernames
        feed = rawFeed.filter { selected.contains($0.user.username.lowercased()) && $0.kind != .reel }
        didLoadFeed = !rawFeed.isEmpty
    }

    var canLoadMoreFeed: Bool { feedCursor != nil }

    func loadStories(reset: Bool = false) async {
        guard phase == .active, !isLoadingStories, reset || !didLoadStories else { return }
        isLoadingStories = true
        defer { isLoadingStories = false }
        do {
            stories = try await client().stories()
            didLoadStories = true
        } catch {
            await handleOperationError(error)
        }
    }

    func searchAccounts(_ query: String) async throws -> [ProfileSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        return try await client().searchAccounts(trimmed)
    }

    func profile(username: String) async throws -> Profile {
        try await client().profile(username: username)
    }

    func profileMedia(username: String, cursor: String? = nil) async throws -> Page<InstagramMedia> {
        try await client().profileMedia(username: username, cursor: cursor)
    }

    func loadThreads(reset: Bool = false) async {
        guard phase == .active, !isLoadingThreads, reset || !didLoadThreads else { return }
        isLoadingThreads = true
        defer { isLoadingThreads = false }
        do {
            threads = try await client().directThreads()
            didLoadThreads = true
        } catch {
            await handleOperationError(error)
        }
    }

    func messages(threadID: String) async throws -> [DirectMessage] {
        try await client().directMessages(threadID: threadID)
    }

    func uploadPost(_ upload: PendingUpload) async -> Bool {
        guard !isUploading else { return false }
        isUploading = true
        defer { isUploading = false }
        do {
            let media = try await client().uploadPost(upload)
            if favorites.usernames.contains(media.user.username.lowercased()) {
                rawFeed.insert(media, at: 0)
                refilterFeed()
            }
            return true
        } catch {
            await handleOperationError(error)
            return false
        }
    }

    func uploadStory(_ upload: PendingUpload) async -> Bool {
        guard !isUploading else { return false }
        isUploading = true
        defer { isUploading = false }
        do {
            _ = try await client().uploadStory(upload)
            didLoadStories = false
            await loadStories(reset: true)
            return true
        } catch {
            await handleOperationError(error)
            return false
        }
    }

    func loadBackendSettings() async {
        do {
            backendSettings = try await client().settings()
            if let account = backendSettings?.account { applyAccount(account) }
        } catch {
            await handleOperationError(error)
        }
    }

    func updateProxy(_ proxyURL: String) async -> Bool {
        do {
            backendSettings = try await client().updateProxy(proxyURL)
            if let account = backendSettings?.account { applyAccount(account) }
            return true
        } catch {
            await handleOperationError(error)
            return false
        }
    }

    private func client() throws -> APIClient {
        guard let baseURL = BackendConfiguration.serverURL else {
            throw APIClientError.backendNotConfigured
        }
        return APIClient(baseURL: baseURL, token: token)
    }

    private func applyAccount(_ account: Account) {
        self.account = account
        favorites.useAccount(account.id)
        switch account.status {
        case .active:
            phase = .active
        case .verificationRequired:
            phase = .verificationRequired
        case .challengeRequired:
            phase = .challengeRequired
        case .reauthRequired:
            phase = .reauthRequired
        }
    }

    private func handleOperationError(_ error: Error) async {
        errorMessage = error.localizedDescription
        if case let APIClientError.rejected(status, _) = error, status == 409 {
            do {
                let refreshed = try await client().sessionAccount()
                applyAccount(refreshed)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func validatedBackendURL(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host))
        else { return nil }
        return url
    }
}
