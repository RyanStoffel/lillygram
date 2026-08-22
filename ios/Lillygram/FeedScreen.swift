import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Values that describe rhythm rather than palette, so they stay local to the
/// feed instead of widening the shared token set.
private enum FeedMetrics {
    /// Instagram's separators are thinner than a system `Divider`.
    static let hairline: CGFloat = 0.5
    static let actionSpacing: CGFloat = 16
    static let textSpacing: CGFloat = 6
    static let rowPadding: CGFloat = 8
    static let storyBarHeight: CGFloat = 2
    /// The left 40% of a story goes back, the rest advances.
    static let storyBackEdge: CGFloat = 0.4
    static let dismissDrag: CGFloat = 80
    static let searchDebounce: Duration = .milliseconds(350)
}

private struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: FeedMetrics.hairline)
    }
}

// MARK: - Home feed

struct FeedScreen: View {
    @ObservedObject private var store: AppStore
    @ObservedObject private var favorites: FavoritesStore

    @State private var showsComposer = false
    @State private var showsFavorites = false
    @State private var openTray: StoryTray?

    init(store: AppStore) {
        _store = ObservedObject(wrappedValue: store)
        _favorites = ObservedObject(wrappedValue: store.favorites)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Hairline()
                scroller
            }
            .background(Theme.background)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { username in
                ProfileScreen(store: store, username: username, showsSettings: false)
            }
        }
        .sheet(isPresented: $showsComposer) {
            UploadComposer(store: store, mode: .post)
        }
        .sheet(isPresented: $showsFavorites, onDismiss: {
            store.refilterFeed()
            Task { await store.loadFeed(reset: true) }
        }) {
            FavoritesPicker(store: store)
        }
        .fullScreenCover(item: $openTray) { tray in
            StoryViewer(tray: tray)
        }
        .task { await store.loadFeed() }
        .task { await store.loadStories() }
    }

    private var header: some View {
        HStack(spacing: Theme.gutter) {
            Text("Lillygram")
                .font(Theme.wordmark)
                .foregroundStyle(Theme.primaryText)

            Spacer(minLength: 0)

            Button { showsComposer = true } label: {
                headerIcon("plus.app")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New post")

            Button { showsFavorites = true } label: {
                headerIcon("star")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Chosen accounts")
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, FeedMetrics.rowPadding)
    }

    private func headerIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: Theme.icon))
            .foregroundStyle(Theme.primaryText)
    }

    private var scroller: some View {
        ScrollView {
            VStack(spacing: 0) {
                if !store.stories.isEmpty {
                    storiesTray
                    Hairline()
                }
                posts
            }
        }
        .scrollIndicators(.hidden)
        .refreshable { await store.loadFeed(reset: true) }
        .background(Theme.background)
    }

    // MARK: Stories

    private var storiesTray: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Theme.gutter) {
                ForEach(store.stories) { tray in
                    Button { openTray = tray } label: {
                        VStack(spacing: FeedMetrics.textSpacing) {
                            Avatar(profile: tray.user, size: Theme.avatarStory, ringed: true)
                            Text(tray.user.username)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.primaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(width: Theme.avatarStory)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, Theme.gutter)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Posts

    @ViewBuilder private var posts: some View {
        if favorites.favorites.isEmpty {
            chooseAccountsState
        } else if store.feed.isEmpty, store.isLoadingFeed {
            ProgressView()
                .tint(Theme.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
        } else if store.feed.isEmpty {
            emptyPageState
        } else {
            LazyVStack(spacing: 0) {
                ForEach(store.feed) { media in
                    // A reel is only ever renderable from a DM thread.
                    if media.kind != .reel {
                        FeedPost(media: media)
                        Hairline()
                    }
                }
                if store.canLoadMoreFeed {
                    loadMoreButton
                }
            }
        }
    }

    private var loadMoreButton: some View {
        Button {
            Task { await store.loadMoreFeed() }
        } label: {
            Text("Load More")
                .font(Theme.username)
                .foregroundStyle(store.isLoadingFeed ? Theme.secondaryText : Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isLoadingFeed)
    }

    // MARK: Empty states

    private var chooseAccountsState: some View {
        VStack(spacing: Theme.gutter) {
            Text("Home only shows the accounts you choose.")
                .font(Theme.caption)
                .foregroundStyle(Theme.primaryText)
            Text("Nothing else gets in. Pick the people you actually want to see.")
                .font(Theme.secondary)
                .foregroundStyle(Theme.secondaryText)
            Button("Choose Accounts") { showsFavorites = true }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: 240)
                .padding(.top, FeedMetrics.rowPadding)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 56)
    }

    private var emptyPageState: some View {
        VStack(spacing: Theme.gutter) {
            Text("No posts from your accounts in this page.")
                .font(Theme.caption)
                .foregroundStyle(Theme.primaryText)
            Text("Lillygram will not fill the gap with anything you did not choose.")
                .font(Theme.secondary)
                .foregroundStyle(Theme.secondaryText)
            if store.canLoadMoreFeed {
                loadMoreButton
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 56)
    }
}

// MARK: - Feed post

private struct FeedPost: View {
    let media: InstagramMedia

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            author
            FeedMedia(media: media)
            actions
            details
        }
    }

    private var author: some View {
        NavigationLink(value: media.user.username) {
            HStack(spacing: Theme.gutter) {
                Avatar(profile: media.user, size: Theme.avatarFeed)
                Text(media.user.username)
                    .font(Theme.username)
                    .foregroundStyle(Theme.primaryText)
                if media.user.isVerified {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, FeedMetrics.rowPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var actions: some View {
        HStack(spacing: FeedMetrics.actionSpacing) {
            Image(systemName: "heart")
            Image(systemName: "bubble.right")
            Image(systemName: "paperplane")
            Spacer(minLength: 0)
            Image(systemName: "bookmark")
        }
        .font(.system(size: Theme.icon))
        .foregroundStyle(Theme.primaryText)
        .padding(.horizontal, Theme.gutter)
        .padding(.top, Theme.gutter)
        .accessibilityHidden(true)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: FeedMetrics.textSpacing) {
            if media.likeCount > 0 {
                Text(media.likeCount == 1 ? "1 like" : "\(media.likeCount) likes")
                    .font(Theme.username)
                    .foregroundStyle(Theme.primaryText)
            }
            if !media.caption.isEmpty {
                Text("\(Text(media.user.username).font(Theme.username)) \(media.caption)")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let takenAt = media.takenAt {
                Text(takenAt.formatted(.relative(presentation: .named)))
                    .font(Theme.timestamp)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.gutter)
        .padding(.top, FeedMetrics.rowPadding)
        .padding(.bottom, Theme.gutter)
    }
}

/// Renders a post's media edge to edge. Reels are never renderable in the feed.
private struct FeedMedia: View {
    let media: InstagramMedia

    var body: some View {
        switch media.kind {
        case .photo:
            RemoteImage(url: media.media ?? media.thumbnail)
        case .carousel:
            carousel
        case .video:
            video(url: media.media, fallback: media.thumbnail)
        case .reel:
            EmptyView()
        }
    }

    @ViewBuilder private var carousel: some View {
        if media.carouselItems.isEmpty {
            RemoteImage(url: media.media ?? media.thumbnail)
        } else {
            TabView {
                ForEach(Array(media.carouselItems.enumerated()), id: \.offset) { page in
                    if page.element.kind == .video {
                        video(url: page.element.media, fallback: page.element.thumbnail)
                    } else {
                        RemoteImage(url: page.element.thumbnail ?? page.element.media)
                    }
                }
            }
            .tabViewStyle(.page)
            .aspectRatio(1, contentMode: .fit)
        }
    }

    @ViewBuilder private func video(url: URL?, fallback: URL?) -> some View {
        if let url {
            LoopFreeVideo(url: url)
                .aspectRatio(1, contentMode: .fit)
        } else {
            RemoteImage(url: fallback)
        }
    }
}

/// `VideoPlayer` that never autoplays and always pauses when it leaves screen.
private struct LoopFreeVideo: View {
    @State private var player: AVPlayer

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .onDisappear { player.pause() }
    }
}

// MARK: - Story viewer

struct StoryViewer: View {
    let tray: StoryTray

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    init(tray: StoryTray) {
        self.tray = tray
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.background.ignoresSafeArea()

            GeometryReader { proxy in
                current
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(tap(width: proxy.size.width))
                    .simultaneousGesture(swipeDown)
            }
            .ignoresSafeArea()

            VStack(spacing: Theme.gutter) {
                progress
                caption
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, FeedMetrics.rowPadding)
        }
    }

    private var item: InstagramMedia? {
        tray.items.indices.contains(index) ? tray.items[index] : nil
    }

    @ViewBuilder private var current: some View {
        if let item {
            switch item.kind {
            case .video:
                if let url = item.media {
                    LoopFreeVideo(url: url)
                } else {
                    RemoteImage(url: item.thumbnail, aspect: nil)
                }
            case .photo, .carousel:
                RemoteImage(url: item.media ?? item.thumbnail, aspect: nil)
            case .reel:
                EmptyView()
            }
        }
    }

    private var progress: some View {
        HStack(spacing: FeedMetrics.storyBarHeight) {
            ForEach(tray.items.indices, id: \.self) { position in
                Capsule()
                    .fill(Theme.primaryText.opacity(position <= index ? 1 : 0.3))
                    .frame(height: FeedMetrics.storyBarHeight)
            }
        }
    }

    private var caption: some View {
        HStack(spacing: FeedMetrics.rowPadding) {
            Avatar(profile: tray.user, size: 28)
            Text(tray.user.username)
                .font(Theme.username)
                .foregroundStyle(Theme.primaryText)
            if let takenAt = item?.takenAt {
                Text(takenAt.formatted(.relative(presentation: .named)))
                    .font(Theme.timestamp)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close stories")
        }
    }

    private func tap(width: CGFloat) -> some Gesture {
        SpatialTapGesture().onEnded { value in
            if value.location.x < width * FeedMetrics.storyBackEdge {
                if index > 0 { index -= 1 }
            } else if index + 1 < tray.items.count {
                index += 1
            } else {
                dismiss()
            }
        }
    }

    private var swipeDown: some Gesture {
        DragGesture(minimumDistance: 20).onEnded { value in
            if value.translation.height > FeedMetrics.dismissDrag,
               abs(value.translation.width) < FeedMetrics.dismissDrag {
                dismiss()
            }
        }
    }
}

// MARK: - Upload composer

struct UploadComposer: View {
    enum Mode { case post, story }

    @ObservedObject private var store: AppStore
    let mode: Mode

    @Environment(\.dismiss) private var dismiss
    @State private var pickerItem: PhotosPickerItem?
    @State private var upload: PendingUpload?
    @State private var preview: Image?
    @State private var caption = ""
    @State private var loadError: String?

    init(store: AppStore, mode: Mode) {
        _store = ObservedObject(wrappedValue: store)
        self.mode = mode
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PhotosPicker(selection: $pickerItem, matching: .any(of: [.images, .videos])) {
                    previewSquare
                }
                .buttonStyle(.plain)

                if mode == .post {
                    TextField("Write a caption", text: $caption, axis: .vertical)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(3 ... 8)
                        .padding(Theme.gutter)
                        .background(Theme.surface)
                }

                if let loadError {
                    Text(loadError)
                        .font(Theme.secondary)
                        .foregroundStyle(Theme.destructive)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.gutter)
                }

                Spacer(minLength: 0)
            }
            .background(Theme.background)
            .navigationTitle(mode == .post ? "New Post" : "New Story")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.isUploading {
                        ProgressView().tint(Theme.secondaryText)
                    } else {
                        Button("Share") { Task { await submit() } }
                            .disabled(upload == nil)
                    }
                }
            }
            .task(id: pickerItem) { await load() }
        }
    }

    private var previewSquare: some View {
        Theme.surface
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let preview {
                    preview
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder
                }
            }
            .clipped()
            .contentShape(Rectangle())
    }

    private var placeholder: some View {
        VStack(spacing: FeedMetrics.rowPadding) {
            Image(systemName: upload == nil ? "photo.on.rectangle" : "video")
                .font(.system(size: Theme.icon))
            Text(upload == nil ? "Select a photo or video" : "Video ready to share")
                .font(Theme.secondary)
        }
        .foregroundStyle(Theme.secondaryText)
    }

    private func load() async {
        guard let pickerItem else {
            upload = nil
            preview = nil
            return
        }
        loadError = nil
        do {
            guard let data = try await pickerItem.loadTransferable(type: Data.self) else {
                throw APIClientError.invalidResponse
            }
            let contentType = pickerItem.supportedContentTypes.first { $0.conforms(to: .movie) }
                ?? pickerItem.supportedContentTypes.first { $0.conforms(to: .image) }
            let isVideo = contentType?.conforms(to: .movie) == true
            upload = PendingUpload(
                data: data,
                filename: "upload.\(contentType?.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg"))",
                mimeType: contentType?.preferredMIMEType ?? (isVideo ? "video/quicktime" : "image/jpeg")
            )
            preview = isVideo ? nil : UIImage(data: data).map { Image(uiImage: $0) }
        } catch {
            loadError = error.localizedDescription
            upload = nil
            preview = nil
        }
    }

    private func submit() async {
        guard var pending = upload else { return }
        if mode == .post {
            pending.caption = caption
        }
        let succeeded = mode == .post
            ? await store.uploadPost(pending)
            : await store.uploadStory(pending)
        if succeeded { dismiss() }
    }
}

// MARK: - Favorites picker

struct FavoritesPicker: View {
    @ObservedObject private var store: AppStore
    @ObservedObject private var favorites: FavoritesStore

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [ProfileSummary] = []
    @State private var isSearching = false
    @State private var searchError: String?

    init(store: AppStore) {
        _store = ObservedObject(wrappedValue: store)
        _favorites = ObservedObject(wrappedValue: store.favorites)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                Hairline()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if !favorites.favorites.isEmpty {
                            sectionHeader("Selected")
                            ForEach(favorites.favorites) { profile in
                                row(profile)
                                Hairline()
                            }
                        }
                        resultsSection
                    }
                }
                .scrollIndicators(.hidden)
            }
            .background(Theme.background)
            .navigationTitle("Chosen Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: query) { await search() }
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleResults: [ProfileSummary] {
        results.filter { !favorites.contains($0) }
    }

    private var searchField: some View {
        HStack(spacing: FeedMetrics.rowPadding) {
            Image(systemName: "magnifyingglass")
                .font(Theme.secondary)
                .foregroundStyle(Theme.secondaryText)
            TextField("Search", text: $query)
                .font(Theme.caption)
                .foregroundStyle(Theme.primaryText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .fieldBackground()
        .padding(.horizontal, Theme.gutter)
        .padding(.vertical, Theme.gutter)
    }

    @ViewBuilder private var resultsSection: some View {
        if !visibleResults.isEmpty {
            sectionHeader("Results")
            ForEach(visibleResults) { profile in
                row(profile)
                Hairline()
            }
        } else if isSearching {
            ProgressView()
                .tint(Theme.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        } else if let searchError {
            note(searchError, tint: Theme.destructive)
        } else if trimmedQuery.count >= 2 {
            note("No accounts matched that name.", tint: Theme.secondaryText)
        } else if favorites.favorites.isEmpty {
            note("Search for the accounts you want on Home.", tint: Theme.secondaryText)
        }
    }

    private func note(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(Theme.secondary)
            .foregroundStyle(tint)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Theme.timestamp.weight(.semibold))
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.gutter)
            .padding(.top, Theme.gutter)
            .padding(.bottom, FeedMetrics.textSpacing)
    }

    private func row(_ profile: ProfileSummary) -> some View {
        Button {
            store.favorites.toggle(profile)
        } label: {
            HStack(spacing: Theme.gutter) {
                Avatar(profile: profile, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.username)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    if !profile.fullName.isEmpty {
                        Text(profile.fullName)
                            .font(Theme.secondary)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: store.favorites.contains(profile) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(store.favorites.contains(profile) ? Theme.accent : Theme.secondaryText)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func search() async {
        guard trimmedQuery.count >= 2 else {
            results = []
            searchError = nil
            isSearching = false
            return
        }
        do {
            try await Task.sleep(for: FeedMetrics.searchDebounce)
        } catch {
            return
        }
        let term = trimmedQuery
        isSearching = true
        defer { isSearching = false }
        do {
            results = try await store.searchAccounts(term)
            searchError = nil
        } catch is CancellationError {
            // Superseded by a newer query.
        } catch {
            searchError = error.localizedDescription
        }
    }
}
