import SwiftUI

// MARK: - Profile

/// Instagram's profile surface: avatar plus three stats, name and biography,
/// then a tight three-column grid. Pushed onto an existing navigation stack,
/// so it never creates one of its own.
struct ProfileScreen: View {
    @ObservedObject private var store: AppStore
    private let username: String
    private let showsSettings: Bool

    @State private var profile: Profile?
    @State private var posts: [InstagramMedia] = []
    @State private var nextCursor: String?
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var isShowingSettings = false
    @State private var selectedMedia: InstagramMedia?

    init(store: AppStore, username: String, showsSettings: Bool) {
        _store = ObservedObject(wrappedValue: store)
        self.username = username
        self.showsSettings = showsSettings
    }

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: Theme.gridGap),
        count: 3
    )

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if let profile {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header(profile)
                        identity(profile)
                        grid
                        if nextCursor != nil { loadMoreButton }
                    }
                }
            } else if isLoading {
                ProgressView().tint(Theme.secondaryText)
            } else {
                unavailable
            }
        }
        .navigationTitle(username)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsSettings {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(Theme.primaryText)
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
        .task {
            do {
                async let loadedProfile = store.profile(username: username)
                async let loadedPage = store.profileMedia(username: username)
                let fetchedProfile = try await loadedProfile
                let page = try await loadedPage
                profile = fetchedProfile
                posts = page.items.filter { $0.kind != .reel }
                nextCursor = page.nextCursor
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsScreen(store: store)
        }
        .sheet(item: $selectedMedia) { media in
            ProfileMediaDetail(media: media)
        }
    }

    // MARK: Header

    private func header(_ profile: Profile) -> some View {
        HStack(alignment: .center, spacing: Theme.gutter) {
            Avatar(url: profile.avatar, initial: profile.username, size: Theme.avatarProfile)

            HStack(spacing: 0) {
                stat(profile.mediaCount, "posts")
                stat(profile.followerCount, "followers")
                stat(profile.followingCount, "following")
            }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.top, Theme.gutter)
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value.formatted())
                .font(Theme.statValue)
                .foregroundStyle(Theme.primaryText)
            Text(label)
                .font(Theme.secondary)
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }

    private func identity(_ profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(profile.fullName)
                    .font(Theme.username)
                    .foregroundStyle(Theme.primaryText)
                if profile.isVerified {
                    Image(systemName: "checkmark.seal.fill")
                        .font(Theme.timestamp)
                        .foregroundStyle(Theme.accent)
                }
            }
            if !profile.biography.isEmpty {
                Text(profile.biography)
                    .font(Theme.secondary)
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.gutter)
        .padding(.top, 16)
        .padding(.bottom, 20)
    }

    // MARK: Grid

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: Theme.gridGap) {
            ForEach(posts) { media in
                Button {
                    selectedMedia = media
                } label: {
                    RemoteImage(url: media.thumbnail ?? media.media)
                        .overlay(alignment: .topTrailing) { kindGlyph(media.kind) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Instagram marks multi-item and video posts in the grid.
    @ViewBuilder
    private func kindGlyph(_ kind: MediaKind) -> some View {
        switch kind {
        case .carousel:
            Image(systemName: "square.on.square")
                .font(Theme.timestamp)
                .foregroundStyle(Theme.primaryText)
                .padding(6)
        case .video:
            Image(systemName: "play.fill")
                .font(Theme.timestamp)
                .foregroundStyle(Theme.primaryText)
                .padding(6)
        case .photo, .reel:
            EmptyView()
        }
    }

    private var loadMoreButton: some View {
        Button {
            Task { await loadMore() }
        } label: {
            Text("Load More")
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoadingMore)
        .opacity(isLoadingMore ? 0.4 : 1)
    }

    private var unavailable: some View {
        VStack(spacing: 6) {
            Text("Profile unavailable")
                .font(Theme.caption.weight(.semibold))
                .foregroundStyle(Theme.primaryText)
            Text(errorMessage ?? "Try again later.")
                .font(Theme.secondary)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
    }

    private func loadMore() async {
        guard let cursor = nextCursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await store.profileMedia(username: username, cursor: cursor)
            posts.append(contentsOf: page.items.filter { $0.kind != .reel })
            nextCursor = page.nextCursor
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Single post opened from the profile grid.
private struct ProfileMediaDetail: View {
    let media: InstagramMedia

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.gutter) {
                        RemoteImage(url: displayURL)

                        VStack(alignment: .leading, spacing: 6) {
                            if media.likeCount > 0 {
                                Text("\(media.likeCount.formatted()) likes")
                                    .font(Theme.username)
                                    .foregroundStyle(Theme.primaryText)
                            }
                            if !media.caption.isEmpty {
                                caption
                            }
                            if let takenAt = media.takenAt {
                                Text(takenAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(Theme.timestamp)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.gutter)
                    }
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle(media.user.username)
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }

    private var caption: some View {
        Text("\(Text(media.user.username).font(Theme.username)) \(media.caption)")
            .font(Theme.caption)
            .foregroundStyle(Theme.primaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var displayURL: URL? {
        switch media.kind {
        case .photo, .carousel: media.media ?? media.thumbnail
        case .video, .reel: media.thumbnail ?? media.media
        }
    }
}

// MARK: - Search

/// Account search only. Lillygram never surfaces hashtags, places, audio,
/// Reels, or algorithmic suggestions.
struct SearchScreen: View {
    @ObservedObject private var store: AppStore

    @State private var query = ""
    @State private var results: [ProfileSummary] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    init(store: AppStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    /// Instagram's search result avatar; smaller than the feed's story row.
    private let resultAvatar: CGFloat = 44

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    field
                    content
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task(id: query) { await search() }
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText)

            TextField("Search", text: $query)
                .font(Theme.caption)
                .foregroundStyle(Theme.primaryText)
                .tint(Theme.accent)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .fieldBackground()
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if isSearching {
            Spacer()
            ProgressView().tint(Theme.secondaryText)
            Spacer()
        } else if let errorMessage {
            Spacer()
            centred(errorMessage)
            Spacer()
        } else if trimmedQuery.count < 2 {
            Spacer()
            centred("Search finds accounts only.")
            Spacer()
        } else if results.isEmpty {
            Spacer()
            centred("No accounts named \(trimmedQuery).")
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { profile in
                        NavigationLink {
                            ProfileScreen(store: store, username: profile.username, showsSettings: false)
                        } label: {
                            row(profile)
                        }
                        .buttonStyle(.plain)
                        Rectangle()
                            .fill(Theme.separator)
                            .frame(height: 0.5)
                            .padding(.leading, Theme.gutter + resultAvatar + Theme.gutter)
                    }
                }
            }
        }
    }

    private func row(_ profile: ProfileSummary) -> some View {
        HStack(spacing: Theme.gutter) {
            Avatar(profile: profile, size: resultAvatar)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(profile.username)
                        .font(Theme.caption.weight(.semibold))
                        .foregroundStyle(Theme.primaryText)
                    if profile.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(Theme.timestamp)
                            .foregroundStyle(Theme.accent)
                    }
                }
                if !profile.fullName.isEmpty {
                    Text(profile.fullName)
                        .font(Theme.secondary)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func centred(_ text: String) -> some View {
        Text(text)
            .font(Theme.secondary)
            .foregroundStyle(Theme.secondaryText)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
    }

    private func search() async {
        let trimmed = trimmedQuery
        guard trimmed.count >= 2 else {
            results = []
            errorMessage = nil
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(350))
        } catch {
            return  // superseded by a newer keystroke
        }
        isSearching = true
        defer { isSearching = false }
        do {
            results = try await store.searchAccounts(trimmed)
            errorMessage = nil
        } catch {
            results = []
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Settings

struct SettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store: AppStore

    @State private var totpSeed = ""
    @State private var proxyURL = ""
    @State private var proxySaved = false
    @State private var isShowingBugReport = false

    init(store: AppStore) {
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        accountSafety
                        twoFactor
                        connection
                        support
                        backend
                        about
                    }
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(Theme.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .task { await store.loadBackendSettings() }
            .sheet(isPresented: $isShowingBugReport) { BugReportView() }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Sections

    private var accountSafety: some View {
        SettingsSection("Account Safety") {
            if let settings = store.backendSettings {
                SettingsRow("Status", value: settings.account.status.rawValue
                    .replacingOccurrences(of: "_", with: " "))
                SettingsHairline()
                SettingsRow("Read limit", value: "\(settings.readLimitPerHour) per hour")
                SettingsHairline()
                SettingsRow("Write limit", value: "\(settings.writeLimitPerHour) per hour")
                SettingsHairline()
                SettingsRow("Warm-up", value: "\(settings.warmupDays) days")
                SettingsHairline()
                SettingsRow(
                    "Writes available",
                    value: settings.account.writesEnabledAt
                        .formatted(date: .abbreviated, time: .omitted)
                )
            } else {
                ProgressView()
                    .tint(Theme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
        }
    }

    private var twoFactor: some View {
        SettingsSection(
            "Two-Factor",
            footer: "The setup key lives in Instagram's Accounts Center under Password and security, "
                + "Two-factor authentication, Authentication app. Save it once and Lillygram "
                + "generates codes itself."
        ) {
            if store.account?.totpConfigured == true {
                SettingsRow("Authenticator", value: "Saved")
                SettingsHairline()
                destructiveRow("Remove Setup Key", disabled: store.isSigningIn) {
                    Task { _ = await store.saveTOTPSeed(nil) }
                }
            } else {
                SecureField("Authenticator setup key", text: $totpSeed)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.primaryText)
                    .tint(Theme.accent)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .fieldBackground()
                    .padding(.horizontal, Theme.gutter)

                Button("Save Setup Key") {
                    Task {
                        if await store.saveTOTPSeed(totpSeed) { totpSeed = "" }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(totpSeed.isEmpty || store.isSigningIn)
                .opacity(totpSeed.isEmpty || store.isSigningIn ? 0.4 : 1)
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 10)
            }
        }
    }

    private var connection: some View {
        SettingsSection(
            "Connection",
            footer: "Leave it blank and update to remove the proxy. The proxy URL is sent to the "
                + "backend over HTTPS and is not stored on this device."
        ) {
            SecureField("Stable per-account proxy URL", text: $proxyURL)
                .font(Theme.caption)
                .foregroundStyle(Theme.primaryText)
                .tint(Theme.accent)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .fieldBackground()
                .padding(.horizontal, Theme.gutter)

            Button(proxySaved ? "Proxy Updated" : "Update Proxy") {
                Task { proxySaved = await store.updateProxy(proxyURL) }
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 10)
        }
    }

    private var support: some View {
        SettingsSection("Support") {
            actionRow("Report a Bug") { isShowingBugReport = true }
            SettingsHairline()
            linkRow("Privacy Policy", "https://ryanstoffel.github.io/lillygram/privacy.html")
            SettingsHairline()
            linkRow("Terms of Service", "https://ryanstoffel.github.io/lillygram/terms.html")
        }
    }

    private var backend: some View {
        SettingsSection("Backend") {
            Text(BackendConfiguration.serverURLString)
                .font(Theme.timestamp)
                .foregroundStyle(Theme.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, 10)
            SettingsHairline()
            destructiveRow("Disconnect Account") {
                dismiss()
                store.disconnect()
            }
        }
    }

    private var about: some View {
        SettingsSection("About") {
            SettingsRow("Version", value: appVersionString)
            SettingsHairline()
            SettingsRow("Status", value: "Private beta")
        }
    }

    // MARK: Rows

    private func actionRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            rowLabel(title, tint: Theme.primaryText)
        }
        .buttonStyle(.plain)
    }

    private func destructiveRow(
        _ title: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            rowLabel(title, tint: Theme.destructive)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    private func linkRow(_ title: String, _ urlString: String) -> some View {
        Group {
            if let url = URL(string: urlString) {
                Link(destination: url) {
                    HStack {
                        rowLabel(title, tint: Theme.primaryText)
                        Image(systemName: "chevron.right")
                            .font(Theme.timestamp)
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.trailing, Theme.gutter)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func rowLabel(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(Theme.caption)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
    }
}

// MARK: - Settings primitives

private struct SettingsSection<Content: View>: View {
    private let title: String
    private let footer: String?
    private let content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Theme.username)
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, Theme.gutter)
                .padding(.top, 24)
                .padding(.bottom, 8)

            content

            if let footer {
                Text(footer)
                    .font(Theme.timestamp)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.gutter)
                    .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsRow: View {
    private let label: String
    private let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(spacing: Theme.gutter) {
            Text(label)
                .font(Theme.caption)
                .foregroundStyle(Theme.primaryText)
            Spacer(minLength: 0)
            Text(value)
                .font(Theme.secondary)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, 12)
    }
}

private struct SettingsHairline: View {
    var body: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 0.5)
            .padding(.leading, Theme.gutter)
    }
}
