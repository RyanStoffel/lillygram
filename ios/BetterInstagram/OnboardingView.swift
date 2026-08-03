import SwiftUI

/// "<marketing version> (<build number>)", e.g. "0.1.0 (2)", read from the
/// bundle so Settings/bug reports never show a stale hardcoded string.
let appVersionString: String = {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "\(version) (\(build))"
}()

/// Favorites picker used in two places: the one-time post-login onboarding
/// (fullscreen, with a Skip option) and the star tab (always available, for
/// editing after onboarding — including after skipping it).
///
/// Defaults to the full list of accounts the user follows so selection is a
/// tap-through; the search field filters that list and also hits Instagram's
/// search for accounts the user doesn't follow. Both requests run through the
/// logged-in webview (see WebViewStore), so this only works with a session.
struct FavoritesPickerView: View {
    enum Mode {
        case onboarding
        case editor
    }

    let mode: Mode
    @ObservedObject var favoritesStore: FavoritesStore
    let loadFollowing: () async -> [FavoriteProfile]
    let search: (String) async -> [FavoriteProfile]
    let onCommit: ([FavoriteProfile]) -> Void
    let onSkip: (() -> Void)?

    @State private var query = ""
    @State private var following: [FavoriteProfile] = []
    @State private var remoteResults: [FavoriteProfile] = []
    @State private var selection: [FavoriteProfile] = []
    @State private var isLoadingFollowing = false
    @State private var isSearching = false
    @State private var didSave = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                searchField
                if !selection.isEmpty { selectedStrip }
                profileList
                footer
            }
            .toolbar {
                if mode == .editor {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Settings and Support")
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            AppSettingsView()
        }
        // The presenting view tints everything .primary (white in dark mode),
        // which would make the prominent Save button white-on-white.
        .tint(.blue)
        .onAppear {
            selection = favoritesStore.favorites
        }
        .task {
            guard following.isEmpty else { return }
            isLoadingFollowing = true
            following = (await loadFollowing()).sorted {
                $0.username.lowercased() < $1.username.lowercased()
            }
            isLoadingFollowing = false
        }
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 2 else {
                remoteResults = []
                return
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            isSearching = true
            remoteResults = await search(trimmed)
            isSearching = false
        }
    }

    private var displayed: [FavoriteProfile] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return following }
        let local = following.filter {
            $0.username.lowercased().contains(q) || $0.fullName.lowercased().contains(q)
        }
        let localIDs = Set(local.map(\.id))
        return local + remoteResults.filter { !localIDs.contains($0.id) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mode == .onboarding ? "Build your feed" : "Your favorites")
                .font(.largeTitle.bold())
            Text(mode == .onboarding
                 ? "Pick the accounts you actually want to see. Your home feed will only show their posts. This also updates your official Instagram Favorites list."
                 : "Your home feed only shows posts from these accounts. Saving changes also updates your official Instagram Favorites list.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top, 24)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search your following or all of Instagram", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if isSearching {
                ProgressView()
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 20)
    }

    private var selectedStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(selection) { profile in
                    chip(for: profile)
                }
            }
            .padding(.horizontal)
        }
        .padding(.top, 12)
    }

    private var profileList: some View {
        List(displayed) { profile in
            row(for: profile)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .overlay {
            if isLoadingFollowing && following.isEmpty {
                ProgressView("Loading accounts you follow…")
            } else if displayed.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "No accounts found" : "No matches",
                    systemImage: "person.2",
                    description: Text(query.isEmpty
                        ? "Couldn't load your following list. Try searching instead."
                        : "Keep typing to search all of Instagram.")
                )
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onCommit(selection)
                didSave = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    didSave = false
                }
            } label: {
                Text(saveButtonTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(mode == .onboarding && selection.isEmpty)

            if mode == .onboarding, let onSkip {
                Button("Skip for now") {
                    onSkip()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            if mode == .editor {
                HStack(spacing: 12) {
                    Button("Report a Bug") {
                        showSettings = true
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Text("•")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)

                    Link("Privacy", destination: URL(string: "https://betterinstagram.app/privacy")!)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text("•")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)

                    Link("Terms", destination: URL(string: "https://betterinstagram.app/terms")!)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    private var saveButtonTitle: String {
        if didSave { return "Saved ✓" }
        switch mode {
        case .onboarding:
            return selection.isEmpty ? "Done" : "Done — \(selection.count) selected"
        case .editor:
            return selection.isEmpty ? "Save and turn off filter" : "Save — \(selection.count) selected"
        }
    }

    private func isSelected(_ profile: FavoriteProfile) -> Bool {
        selection.contains { $0.id == profile.id }
    }

    private func toggle(_ profile: FavoriteProfile) {
        UISelectionFeedbackGenerator().selectionChanged()
        if let index = selection.firstIndex(where: { $0.id == profile.id }) {
            selection.remove(at: index)
        } else {
            selection.append(profile)
        }
    }

    private func row(for profile: FavoriteProfile) -> some View {
        Button {
            toggle(profile)
        } label: {
            HStack(spacing: 12) {
                avatar(for: profile, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.username)
                        .font(.subheadline.weight(.semibold))
                    if !profile.fullName.isEmpty {
                        Text(profile.fullName)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: isSelected(profile) ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundStyle(isSelected(profile) ? Color.blue : Color.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func chip(for profile: FavoriteProfile) -> some View {
        Button {
            toggle(profile)
        } label: {
            HStack(spacing: 6) {
                avatar(for: profile, size: 20)
                Text(profile.username)
                    .font(.footnote.weight(.medium))
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.tertiarySystemFill), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private func avatar(for profile: FavoriteProfile, size: CGFloat) -> some View {
        AsyncImage(url: profile.avatarURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// Settings and support sheet for bug reporting and legal terms.
struct AppSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showBugReport = false

    var body: some View {
        NavigationStack {
            List {
                Section("Support") {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        showBugReport = true
                    } label: {
                        Label("Report a Bug", systemImage: "ladybug")
                            .foregroundStyle(.primary)
                    }
                }

                Section("Legal") {
                    Link(destination: URL(string: "https://ryanstoffel.github.io/better-instagram/privacy.html")!) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                            .foregroundStyle(.primary)
                    }
                    Link(destination: URL(string: "https://ryanstoffel.github.io/better-instagram/terms.html")!) {
                        Label("Terms of Service", systemImage: "doc.text")
                            .foregroundStyle(.primary)
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersionString)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings & Support")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showBugReport) {
                BugReportView()
            }
        }
    }
}

/// Native bug reporting interface.
struct BugReportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var bugDescription = ""
    @State private var didSend = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $bugDescription)
                        .frame(minHeight: 120)
                } header: {
                    Text("Describe the issue")
                } footer: {
                    Text("Please describe what happened and how to reproduce it.")
                }

                Section("System Information") {
                    HStack {
                        Text("App Version")
                        Spacer()
                        Text("1.0 (1)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("iOS Version")
                        Spacer()
                        Text(UIDevice.current.systemVersion)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Report a Bug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        sendReport()
                    }
                    .disabled(bugDescription.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert("Report Ready", isPresented: $didSend) {
                Button("OK") { dismiss() }
            } message: {
                Text("Thank you for helping improve BetterInstagram!")
            }
        }
    }

    private func sendReport() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let body = """
        Bug Description:
        \(bugDescription)

        ---
        App Version: \(appVersionString)
        iOS Version: \(UIDevice.current.systemVersion)
        Device: \(UIDevice.current.model)
        """
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let mailURL = URL(string: "mailto:stoffel.thomas.ryan@gmail.com?subject=BetterInstagram%20Bug%20Report&body=\(encodedBody)") {
            UIApplication.shared.open(mailURL)
        }
        didSend = true
    }
}
