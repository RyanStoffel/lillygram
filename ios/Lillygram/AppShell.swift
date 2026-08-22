import SwiftUI

// MARK: - Tab bar

/// Instagram's bottom bar: four icon-only tabs on true black.
///
/// This is a hand-built bar rather than `TabView`. On iOS 26 `TabView` renders a
/// floating translucent capsule, whereas Instagram's bar is flat, edge-to-edge,
/// and separated by a hairline.
struct MainTabView: View {
    @ObservedObject var store: AppStore
    @State private var selection: Tab = .home

    private enum Tab: String, CaseIterable {
        case home, search, messages, profile

        var symbol: String {
            switch self {
            case .home: "house"
            case .search: "magnifyingglass"
            case .messages: "paperplane"
            case .profile: "person.crop.circle"
            }
        }

        var title: String {
            switch self {
            case .home: "Home"
            case .search: "Search"
            case .messages: "Messages"
            case .profile: "Profile"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            bar
        }
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }

    /// Each tab stays alive so scroll position and loaded pages survive switching.
    @ViewBuilder private var content: some View {
        ZStack {
            FeedScreen(store: store).opacity(selection == .home ? 1 : 0)
            SearchScreen(store: store).opacity(selection == .search ? 1 : 0)
            MessagesScreen(store: store).opacity(selection == .messages ? 1 : 0)
            profileTab.opacity(selection == .profile ? 1 : 0)
        }
    }

    private var bar: some View {
        VStack(spacing: 0) {
            Theme.separator.frame(height: 0.5)
            HStack(spacing: 0) {
                ForEach(Tab.allCases, id: \.rawValue) { tab in
                    Button {
                        selection = tab
                    } label: {
                        Image(systemName: tab.symbol)
                            .font(.system(size: Theme.icon, weight: selection == tab ? .semibold : .regular))
                            .foregroundStyle(selection == tab ? Theme.primaryText : Theme.secondaryText)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.title)
                    .accessibilityAddTraits(selection == tab ? [.isSelected, .isButton] : .isButton)
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
        .background(Theme.background)
    }

    /// `ProfileScreen` never builds its own stack, so the tab owns one.
    @ViewBuilder private var profileTab: some View {
        if let username = store.account?.username, !username.isEmpty {
            NavigationStack {
                ProfileScreen(store: store, username: username, showsSettings: true)
            }
        } else {
            ZStack {
                Theme.background.ignoresSafeArea()
                Text("Your profile is unavailable.")
                    .font(Theme.secondary)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

// MARK: - Sign in

/// Centred credential entry, styled after Instagram's login screen.
struct SignInScreen: View {
    @ObservedObject var store: AppStore

    @State private var serverURL = BackendConfiguration.serverURLString
    @State private var username = ""
    @State private var password = ""
    @State private var verificationCode = ""
    @State private var totpSeed = ""

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Text("Lillygram")
                        .font(Theme.wordmark)
                        .foregroundStyle(Theme.primaryText)
                        .padding(.bottom, 36)

                    credentialFields
                    submitButton.padding(.top, 20)

                    if let message = store.errorMessage {
                        Text(message)
                            .font(Theme.secondary)
                            .foregroundStyle(Theme.destructive)
                            .multilineTextAlignment(.center)
                            .padding(.top, 16)
                    }

                    accountState
                    twoFactorBlock

                    Text("Credentials go to your own backend over HTTPS and are never stored by Lillygram.")
                        .font(Theme.timestamp)
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.top, 32)
                }
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
                .padding(.horizontal, 32)
                .padding(.vertical, 32)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            if username.isEmpty { username = store.account?.username ?? "" }
        }
    }

    // MARK: Fields

    @ViewBuilder private var credentialFields: some View {
        VStack(spacing: 10) {
            // `Text(verbatim:)` keeps the URL placeholder from picking up
            // markdown link styling, which would tint it blue.
            TextField(text: $serverURL, prompt: Text(verbatim: "https://backend.example.com")) {
                Text("Backend URL")
            }
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .autocorrectionDisabled()
            .fieldBackground()

            TextField("Username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .fieldBackground()

            SecureField("Password", text: $password)
                .fieldBackground()

            if store.phase == .verificationRequired && !totpConfigured {
                SecureField("Authenticator or backup code", text: $verificationCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .fieldBackground()
            }
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.primaryText)
    }

    private var submitButton: some View {
        Button {
            Task {
                await store.signIn(
                    serverURL: serverURL,
                    username: username,
                    password: password,
                    verificationCode: verificationCode,
                    proxyURL: ""
                )
                password = ""
                verificationCode = ""
            }
        } label: {
            if store.isSigningIn {
                ProgressView().tint(Theme.primaryText)
            } else {
                Text(submitTitle)
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(submitDisabled)
        .opacity(submitDisabled ? 0.5 : 1)
    }

    // MARK: Account state

    @ViewBuilder private var accountState: some View {
        if let account = store.account, store.phase != .signedOut {
            VStack(spacing: 4) {
                Text(account.username)
                    .font(Theme.secondary)
                    .foregroundStyle(Theme.secondaryText)
                Text(account.challengeMessage ?? phaseMessage)
                    .font(Theme.secondary)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 28)
        }
    }

    // MARK: Two-factor

    @ViewBuilder private var twoFactorBlock: some View {
        if store.phase == .verificationRequired {
            VStack(spacing: 12) {
                if totpConfigured {
                    Text("Authenticator saved")
                        .font(Theme.secondary)
                        .foregroundStyle(Theme.primaryText)
                    Button("Remove") {
                        Task { _ = await store.saveTOTPSeed(nil) }
                    }
                    .font(Theme.secondary)
                    .foregroundStyle(Theme.destructive)
                    .disabled(store.isSigningIn)
                } else {
                    SecureField("Authenticator setup key", text: $totpSeed)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(Theme.caption)
                        .foregroundStyle(Theme.primaryText)
                        .fieldBackground()
                    Button("Save Setup Key") {
                        Task {
                            if await store.saveTOTPSeed(totpSeed) { totpSeed = "" }
                        }
                    }
                    .font(Theme.username)
                    .foregroundStyle(Theme.accent)
                    .disabled(totpSeed.isEmpty || store.isSigningIn)
                }

                Text("The setup key comes from Instagram's Accounts Center, under Password and security, Two-factor authentication, Authentication app.")
                    .font(Theme.timestamp)
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 28)
        }
    }

    // MARK: Derived state

    private var totpConfigured: Bool {
        store.account?.totpConfigured == true
    }

    /// The verification code stays optional: accounts with 2FA disabled have
    /// none to enter, and a saved setup key supplies it automatically.
    private var submitDisabled: Bool {
        store.isSigningIn || serverURL.isEmpty || username.isEmpty || password.isEmpty
    }

    private var submitTitle: String {
        switch store.phase {
        case .verificationRequired:
            totpConfigured ? "Sign In With Saved Key" : "Sign In"
        case .challengeRequired, .reauthRequired:
            "Reconnect"
        default:
            "Sign In"
        }
    }

    private var phaseMessage: String {
        switch store.phase {
        case .verificationRequired:
            "Enter the current code from your authenticator app, SMS, or Instagram backup codes."
        case .challengeRequired:
            "Complete Instagram's verification in the official app. Lillygram has stopped all requests for this account."
        case .reauthRequired:
            "Instagram rejected the saved session. Lillygram did not retry automatically."
        default:
            "Sign in to continue."
        }
    }
}

// MARK: - Launch

/// Shown while the stored session is restored.
struct LaunchScreen: View {
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 24) {
                Image("LillygramIcon")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                ProgressView().tint(Theme.secondaryText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Opening Lillygram")
    }
}
