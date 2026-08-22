import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct SignInView: View {
    @ObservedObject var store: AppStore
    @State private var serverURL = BackendConfiguration.serverURLString
    @State private var username = ""
    @State private var password = ""
    @State private var verificationCode = ""
    @State private var proxyURL = ""
    @State private var showAdvanced = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://backend.example.com", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                } header: {
                    Text("Lillygram Backend")
                } footer: {
                    Text("Credentials go directly to your backend over HTTPS and are never stored by Lillygram.")
                }

                if let account = store.account, store.phase != .signedOut {
                    Section("Account State") {
                        LabeledContent("Account", value: account.username)
                        Text(account.challengeMessage ?? stateMessage)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Instagram") {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !smsPending {
                        SecureField("Password", text: $password)
                    }
                    if store.phase == .verificationRequired {
                        SecureField(
                            smsPending ? "SMS code" : "Authenticator or backup code",
                            text: $verificationCode
                        )
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)

                        if !smsPending {
                            Button("Request One SMS Code") {
                                Task {
                                    _ = await store.requestSMS(password: password)
                                    password = ""
                                }
                            }
                            .disabled(password.isEmpty || store.isSigningIn)
                        } else {
                            SecureField(
                                "Password after Instagram approval",
                                text: $password
                            )
                            Button("I Approved in Instagram") {
                                Task {
                                    _ = await store.checkAppApproval(
                                        password: password
                                    )
                                    password = ""
                                }
                            }
                            .disabled(password.isEmpty || store.isSigningIn)
                            Text(
                                "Use this only after approving the login request in the official Instagram app."
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    DisclosureGroup("Connection options", isExpanded: $showAdvanced) {
                        SecureField("Per-account proxy URL", text: $proxyURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("Optional. Configure one stable residential or mobile proxy for this account. Do not rotate it between requests.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let message = store.errorMessage {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task {
                            if smsPending {
                                _ = await store.verifySMS(code: verificationCode)
                            } else {
                                await store.signIn(
                                    serverURL: serverURL,
                                    username: username,
                                    password: password,
                                    verificationCode: verificationCode,
                                    proxyURL: proxyURL
                                )
                            }
                            password = ""
                            verificationCode = ""
                            proxyURL = ""
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if store.isSigningIn {
                                ProgressView()
                            } else {
                                Text(signInTitle).fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(submitDisabled)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Lillygram")
            .onAppear {
                if username.isEmpty { username = store.account?.username ?? "" }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var smsPending: Bool {
        store.account?.smsPending == true
    }

    private var submitDisabled: Bool {
        if store.isSigningIn || serverURL.isEmpty || username.isEmpty {
            return true
        }
        if store.phase == .verificationRequired {
            return verificationCode.isEmpty || (!smsPending && password.isEmpty)
        }
        return password.isEmpty
    }

    private var signInTitle: String {
        switch store.phase {
        case .verificationRequired:
            smsPending ? "Verify SMS Code" : "Submit Verification Code"
        case .challengeRequired, .reauthRequired:
            "Reconnect Explicitly"
        default: "Sign In"
        }
    }

    private var stateMessage: String {
        switch store.phase {
        case .verificationRequired: "Enter the current code from your authenticator app, SMS, or Instagram backup codes."
        case .challengeRequired: "Complete Instagram's verification in the official app. Lillygram has stopped all requests for this account."
        case .reauthRequired: "Instagram rejected the saved session. Lillygram did not retry automatically."
        default: "Sign in to continue."
        }
    }
}

struct MainTabView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") {
                HomeFeedView(store: store)
            }
            Tab("Stories", systemImage: "circle.dashed") {
                StoriesView(store: store)
            }
            Tab("Search", systemImage: "magnifyingglass") {
                AccountSearchView(store: store)
            }
            Tab("Messages", systemImage: "paperplane") {
                MessagesView(store: store)
            }
            Tab("Profile", systemImage: "person.crop.circle") {
                NavigationStack {
                    if let username = store.account?.username {
                        ProfileView(store: store, username: username, showsSettings: true)
                    }
                }
            }
        }
        .tint(.white)
        .preferredColorScheme(.dark)
    }
}

struct HomeFeedView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var favorites: FavoritesStore
    @State private var showFavorites = false
    @State private var showComposer = false
    @State private var showSettings = false

    init(store: AppStore) {
        self.store = store
        favorites = store.favorites
    }

    var body: some View {
        NavigationStack {
            Group {
                if favorites.favorites.isEmpty {
                    ContentUnavailableView {
                        Label("Choose your favorites", systemImage: "star")
                    } description: {
                        Text("Home stays empty until you choose accounts. Algorithmic posts are never used as a fallback.")
                    } actions: {
                        Button("Choose Accounts") { showFavorites = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else if store.isLoadingFeed && store.feed.isEmpty {
                    ProgressView("Loading favorites")
                } else if store.feed.isEmpty {
                    ContentUnavailableView(
                        "No favorite posts in this page",
                        systemImage: "rectangle.stack",
                        description: Text("Load another page without opening the algorithmic feed.")
                    )
                    .overlay(alignment: .bottom) {
                        if store.canLoadMoreFeed {
                            Button("Load Another Page") { Task { await store.loadMoreFeed() } }
                                .buttonStyle(.bordered)
                                .padding(.bottom, 80)
                        }
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 24) {
                            ForEach(store.feed) { media in
                                FeedMediaView(media: media)
                            }
                            if store.canLoadMoreFeed {
                                Button("Load More") { Task { await store.loadMoreFeed() } }
                                    .buttonStyle(.bordered)
                                    .disabled(store.isLoadingFeed)
                            }
                        }
                        .padding(.vertical)
                    }
                    .refreshable { await store.loadFeed(reset: true) }
                }
            }
            .background(Color.black)
            .navigationTitle("Home")
            .navigationDestination(for: String.self) { username in
                ProfileView(store: store, username: username)
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Post", systemImage: "plus") { showComposer = true }
                    Button("Favorites", systemImage: "star") { showFavorites = true }
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                }
            }
            .task { await store.loadFeed() }
            .sheet(isPresented: $showFavorites, onDismiss: {
                store.refilterFeed()
                Task { await store.loadFeed(reset: true) }
            }) {
                FavoritesPickerView(store: store)
            }
            .sheet(isPresented: $showComposer) {
                UploadComposerView(store: store, mode: .post)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(store: store)
            }
        }
    }
}

struct FeedMediaView: View {
    let media: InstagramMedia

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: media.user.username) {
                HStack(spacing: 10) {
                    ProfileAvatar(profile: media.user, size: 36)
                    Text(media.user.username)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .padding(.horizontal)
            }
            .buttonStyle(.plain)

            NativeMediaView(media: media)

            if !media.caption.isEmpty {
                Text(media.caption)
                    .font(.subheadline)
                    .padding(.horizontal)
            }
            HStack(spacing: 16) {
                Text("\(media.likeCount) likes")
                Text("\(media.commentCount) comments")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
        }
    }
}

struct NativeMediaView: View {
    let media: InstagramMedia

    var body: some View {
        switch media.kind {
        case .photo:
            RemoteImage(url: media.thumbnail ?? media.media)
        case .video:
            if let url = media.media {
                NativeVideoView(url: url)
                    .aspectRatio(1, contentMode: .fit)
            } else {
                RemoteImage(url: media.thumbnail)
            }
        case .carousel:
            TabView {
                ForEach(Array(media.carouselItems.enumerated()), id: \.offset) { _, asset in
                    if asset.kind == .video, let url = asset.media {
                        NativeVideoView(url: url)
                    } else {
                        RemoteImage(url: asset.thumbnail ?? asset.media)
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .aspectRatio(1, contentMode: .fit)
        case .reel:
            EmptyView()
        }
    }
}

struct FavoritesPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: AppStore
    @ObservedObject private var favorites: FavoritesStore
    @State private var query = ""
    @State private var results: [ProfileSummary] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    init(store: AppStore) {
        self.store = store
        favorites = store.favorites
    }

    var body: some View {
        NavigationStack {
            List {
                if !favorites.favorites.isEmpty {
                    Section("Selected") {
                        ForEach(favorites.favorites) { profile in row(profile) }
                    }
                }
                Section(query.isEmpty ? "Search for accounts" : "Results") {
                    ForEach(results) { profile in row(profile) }
                    if isSearching { ProgressView() }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .searchable(text: $query, prompt: "Account username")
            .navigationTitle("Favorites")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: query) {
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 2 else {
                    results = []
                    return
                }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                isSearching = true
                defer { isSearching = false }
                do {
                    results = try await store.searchAccounts(trimmed)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func row(_ profile: ProfileSummary) -> some View {
        Button {
            favorites.toggle(profile)
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(spacing: 12) {
                ProfileAvatar(profile: profile, size: 42)
                VStack(alignment: .leading) {
                    Text(profile.username).fontWeight(.semibold)
                    if !profile.fullName.isEmpty {
                        Text(profile.fullName).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: favorites.contains(profile) ? "checkmark.circle.fill" : "circle")
            }
        }
        .buttonStyle(.plain)
    }
}

struct StoriesView: View {
    @ObservedObject var store: AppStore
    @State private var selectedTray: StoryTray?
    @State private var showComposer = false

    var body: some View {
        NavigationStack {
            Group {
                if store.isLoadingStories && store.stories.isEmpty {
                    ProgressView("Loading stories")
                } else if store.stories.isEmpty {
                    ContentUnavailableView("No active stories", systemImage: "circle.dashed")
                } else {
                    List(store.stories) { tray in
                        Button { selectedTray = tray } label: {
                            HStack(spacing: 12) {
                                ProfileAvatar(profile: tray.user, size: 50)
                                VStack(alignment: .leading) {
                                    Text(tray.user.username).fontWeight(.semibold)
                                    Text("\(tray.items.count) stor\(tray.items.count == 1 ? "y" : "ies")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                    .refreshable { await store.loadStories(reset: true) }
                }
            }
            .navigationTitle("Stories")
            .toolbar {
                Button("Add Story", systemImage: "plus") { showComposer = true }
            }
            .task { await store.loadStories() }
            .fullScreenCover(item: $selectedTray) { StoryViewer(tray: $0) }
            .sheet(isPresented: $showComposer) {
                UploadComposerView(store: store, mode: .story)
            }
        }
    }
}

struct StoryViewer: View {
    @Environment(\.dismiss) private var dismiss
    let tray: StoryTray
    @State private var index = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if tray.items.indices.contains(index) {
                NativeMediaView(media: tray.items[index])
            }
            VStack {
                HStack {
                    ProfileAvatar(profile: tray.user, size: 34)
                    Text(tray.user.username).fontWeight(.semibold)
                    Spacer()
                    Button("Done") { dismiss() }
                }
                .padding()
                Spacer()
                HStack {
                    Button("Previous") { index = max(index - 1, 0) }
                        .disabled(index == 0)
                    Spacer()
                    Button(index == tray.items.count - 1 ? "Done" : "Next") {
                        if index == tray.items.count - 1 { dismiss() } else { index += 1 }
                    }
                }
                .padding()
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct AccountSearchView: View {
    @ObservedObject var store: AppStore
    @State private var query = ""
    @State private var results: [ProfileSummary] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List(results) { profile in
                NavigationLink {
                    ProfileView(store: store, username: profile.username)
                } label: {
                    HStack(spacing: 12) {
                        ProfileAvatar(profile: profile, size: 44)
                        VStack(alignment: .leading) {
                            Text(profile.username).fontWeight(.semibold)
                            Text(profile.fullName).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay {
                if isSearching { ProgressView() }
                else if results.isEmpty {
                    ContentUnavailableView("Search accounts", systemImage: "person.text.rectangle", description: Text("Posts, hashtags, places, and Reels are not available."))
                }
            }
            .searchable(text: $query, prompt: "Username")
            .navigationTitle("Search")
            .task(id: query) {
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 2 else { results = []; return }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                isSearching = true
                defer { isSearching = false }
                do {
                    results = try await store.searchAccounts(trimmed)
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                    results = []
                }
            }
            .alert("Search Failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
        }
    }
}

struct ProfileView: View {
    @ObservedObject var store: AppStore
    let username: String
    var showsSettings = false
    @State private var profile: Profile?
    @State private var posts: [InstagramMedia] = []
    @State private var nextCursor: String?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showSettings = false
    @State private var selectedMedia: InstagramMedia?

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

    var body: some View {
        Group {
            if let profile {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 18) {
                            ProfileAvatar(url: profile.avatar, initials: profile.username, size: 84)
                            Spacer()
                            stat(profile.mediaCount, "Posts")
                            stat(profile.followerCount, "Followers")
                            stat(profile.followingCount, "Following")
                        }
                        Text(profile.fullName).fontWeight(.semibold)
                        if !profile.biography.isEmpty { Text(profile.biography) }
                    }
                    .padding()

                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(posts) { media in
                            Button { selectedMedia = media } label: {
                                RemoteImage(url: media.thumbnail ?? media.media)
                                    .aspectRatio(1, contentMode: .fill)
                                    .clipped()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if nextCursor != nil {
                        Button("Load More Posts") { Task { await loadMorePosts() } }
                            .buttonStyle(.bordered)
                            .padding()
                    }
                }
            } else if isLoading {
                ProgressView("Loading profile")
            } else {
                ContentUnavailableView(
                    "Profile unavailable",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text(errorMessage ?? "Try again later.")
                )
            }
        }
        .navigationTitle(username)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsSettings {
                Button("Settings", systemImage: "gearshape") { showSettings = true }
            }
        }
        .task {
            do {
                async let loadedProfile = store.profile(username: username)
                async let loadedPosts = store.profileMedia(username: username)
                profile = try await loadedProfile
                let page = try await loadedPosts
                posts = page.items.filter { $0.kind != .reel }
                nextCursor = page.nextCursor
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
        .sheet(isPresented: $showSettings) { SettingsView(store: store) }
        .sheet(item: $selectedMedia) { media in
            NavigationStack {
                NativeMediaView(media: media)
                    .navigationTitle(media.user.username)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.large])
        }
    }

    private func loadMorePosts() async {
        do {
            let page = try await store.profileMedia(username: username, cursor: nextCursor)
            posts.append(contentsOf: page.items.filter { $0.kind != .reel })
            nextCursor = page.nextCursor
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack {
            Text(value.formatted()).fontWeight(.bold)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct MessagesView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        NavigationStack {
            Group {
                if store.isLoadingThreads && store.threads.isEmpty {
                    ProgressView("Loading messages")
                } else if store.threads.isEmpty {
                    ContentUnavailableView("No conversations", systemImage: "paperplane")
                } else {
                    List(store.threads) { thread in
                        NavigationLink {
                            DirectThreadView(store: store, thread: thread)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(thread.title).fontWeight(.semibold)
                                if let message = thread.messages.first {
                                    Text(message.text.isEmpty ? "Shared media" : message.text)
                                        .lineLimit(1)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await store.loadThreads(reset: true) }
                }
            }
            .navigationTitle("Messages")
            .task { await store.loadThreads() }
        }
    }
}

struct DirectThreadView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject var store: AppStore
    let thread: DirectThread
    @State private var messages: [DirectMessage] = []
    @State private var selectedReel: InstagramMedia?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List(messages) { message in
            VStack(alignment: .leading, spacing: 8) {
                if !message.text.isEmpty { Text(message.text) }
                if let media = message.media {
                    if media.kind == .reel && media.sharedReel {
                        Button("Watch shared Reel") { selectedReel = media }
                            .buttonStyle(.bordered)
                    } else if media.kind != .reel {
                        NativeMediaView(media: media)
                            .frame(maxHeight: 360)
                    }
                }
                if let timestamp = message.timestamp {
                    Text(timestamp, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay { if isLoading { ProgressView() } }
        .navigationTitle(thread.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button("Continue in Instagram") {
                if let appURL = URL(string: "instagram://direct/inbox") {
                    openURL(appURL) { accepted in
                        if !accepted, let webURL = URL(string: "https://www.instagram.com/direct/inbox/") {
                            openURL(webURL)
                        }
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.black)
        }
        .task {
            do {
                messages = try await store.messages(threadID: thread.id)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
        .alert("Messages Unavailable", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") {} } message: { Text(errorMessage ?? "Unknown error") }
        .fullScreenCover(item: $selectedReel) { SharedReelPlayer(media: $0) }
    }
}

struct SharedReelPlayer: View {
    @Environment(\.dismiss) private var dismiss
    let media: InstagramMedia

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if media.sharedReel, let url = media.media {
                NativeVideoView(url: url, autoplay: true)
                    .ignoresSafeArea()
            } else {
                Text("This Reel was not opened from a direct message.")
                    .foregroundStyle(.secondary)
            }
            VStack {
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .padding()
                }
                Spacer()
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct NativeVideoView: View {
    @State private var player: AVPlayer
    let autoplay: Bool

    init(url: URL, autoplay: Bool = false) {
        _player = State(initialValue: AVPlayer(url: url))
        self.autoplay = autoplay
    }

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                if autoplay { player.play() }
            }
            .onDisappear {
                player.pause()
            }
    }
}

struct UploadComposerView: View {
    enum Mode { case post, story }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: AppStore
    let mode: Mode
    @State private var pickerItem: PhotosPickerItem?
    @State private var upload: PendingUpload?
    @State private var caption = ""
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Media") {
                    PhotosPicker(selection: $pickerItem, matching: .any(of: [.images, .videos])) {
                        Text(upload == nil ? "Choose Photo or Video" : upload?.filename ?? "Selected")
                    }
                }
                if mode == .post {
                    Section("Caption") {
                        TextEditor(text: $caption).frame(minHeight: 100)
                    }
                }
                if let loadError { Text(loadError).foregroundStyle(.red) }
            }
            .navigationTitle(mode == .post ? "New Post" : "New Story")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if store.isUploading {
                        ProgressView()
                    } else {
                        Button("Share") { Task { await submit() } }
                            .disabled(upload == nil)
                    }
                }
            }
            .task(id: pickerItem) {
                guard let pickerItem else { upload = nil; return }
                do {
                    guard let data = try await pickerItem.loadTransferable(type: Data.self) else {
                        throw APIClientError.invalidResponse
                    }
                    let contentType = pickerItem.supportedContentTypes.first {
                        $0.conforms(to: .movie)
                    } ?? pickerItem.supportedContentTypes.first {
                        $0.conforms(to: .image)
                    }
                    let isVideo = contentType?.conforms(to: .movie) == true
                    let fallbackExtension = isVideo ? "mov" : "jpg"
                    let fallbackMIME = isVideo ? "video/quicktime" : "image/jpeg"
                    upload = PendingUpload(
                        data: data,
                        filename: "upload.\(contentType?.preferredFilenameExtension ?? fallbackExtension)",
                        mimeType: contentType?.preferredMIMEType ?? fallbackMIME
                    )
                } catch {
                    loadError = error.localizedDescription
                }
            }
        }
    }

    private func submit() async {
        guard var upload else { return }
        upload.caption = caption
        let succeeded = mode == .post
            ? await store.uploadPost(upload)
            : await store.uploadStory(upload)
        if succeeded { dismiss() }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: AppStore
    @State private var proxyURL = ""
    @State private var showBugReport = false
    @State private var proxySaved = false

    var body: some View {
        NavigationStack {
            Form {
                if let settings = store.backendSettings {
                    Section("Account Safety") {
                        LabeledContent("Status", value: settings.account.status.rawValue.replacingOccurrences(of: "_", with: " "))
                        LabeledContent("Read limit", value: "\(settings.readLimitPerHour) per hour")
                        LabeledContent("Write limit", value: "\(settings.writeLimitPerHour) per hour")
                        LabeledContent("Warm-up", value: "\(settings.warmupDays) days")
                        LabeledContent("Writes available") {
                            Text(settings.account.writesEnabledAt, style: .date)
                        }
                    }
                }

                Section {
                    SecureField("Stable per-account proxy URL", text: $proxyURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(proxySaved ? "Saved" : "Update Proxy") {
                        Task { proxySaved = await store.updateProxy(proxyURL) }
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Leave blank and update to remove the proxy. Proxy credentials are sent to the backend over HTTPS and are not stored on this device.")
                }

                Section("Support") {
                    Button("Report a Bug") { showBugReport = true }
                    Link("Privacy Policy", destination: URL(string: "https://ryanstoffel.github.io/lillygram/privacy.html")!)
                    Link("Terms of Service", destination: URL(string: "https://ryanstoffel.github.io/lillygram/terms.html")!)
                }

                Section("Backend") {
                    Text(BackendConfiguration.serverURLString)
                        .font(.caption)
                        .textSelection(.enabled)
                    Button("Disconnect Account", role: .destructive) {
                        dismiss()
                        store.disconnect()
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: appVersionString)
                    LabeledContent("Status", value: "Private beta")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await store.loadBackendSettings() }
            .sheet(isPresented: $showBugReport) { BugReportView() }
        }
    }
}

struct ProfileAvatar: View {
    private let url: URL?
    private let initials: String
    private let size: CGFloat

    init(profile: ProfileSummary, size: CGFloat) {
        url = profile.avatar
        initials = profile.username
        self.size = size
    }

    init(url: URL?, initials: String, size: CGFloat) {
        self.url = url
        self.initials = initials
        self.size = size
    }

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Circle().fill(Color.white.opacity(0.12))
                    .overlay(Text(String(initials.prefix(1)).uppercased()).fontWeight(.semibold))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct RemoteImage: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                image.resizable().scaledToFit()
            case .failure:
                Color.black.overlay(Text("Media unavailable").foregroundStyle(.secondary))
            default:
                Color.black.overlay(ProgressView())
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
    }
}
