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
                LaunchScreen()
            case .active:
                MainTabView(store: store)
            case .signedOut, .verificationRequired, .challengeRequired, .reauthRequired:
                SignInScreen(store: store)
            }
        }
        .background(Theme.background.ignoresSafeArea())
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
