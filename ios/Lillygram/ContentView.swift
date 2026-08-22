import SwiftUI

struct ContentView: View {
    @StateObject private var favorites: FavoritesStore
    @StateObject private var store: AppStore

    init() {
        let favorites = FavoritesStore()
        _favorites = StateObject(wrappedValue: favorites)
        _store = StateObject(wrappedValue: AppStore(favorites: favorites))
    }

    var body: some View {
        Group {
            switch store.phase {
            case .restoring:
                LaunchView()
            case .active:
                MainTabView(store: store)
            case .signedOut, .verificationRequired, .challengeRequired, .reauthRequired:
                SignInView(store: store)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task {
            if store.phase == .restoring {
                await store.restoreSession()
            }
        }
        .alert("Lillygram", isPresented: Binding(
            get: { store.errorMessage != nil && store.phase == .active },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "Unknown error")
        }
    }
}

private struct LaunchView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                Image("LillygramIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                ProgressView()
            }
        }
        .accessibilityLabel("Opening Lillygram")
    }
}
