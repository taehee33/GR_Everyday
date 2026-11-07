import SwiftUI

@main
struct GRConnectApp: App {
    @StateObject private var connection = ConnectionModel()
    @StateObject private var library = LibraryModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(connection)
                .environmentObject(library)
        }
    }
}

struct RootView: View {
    var body: some View {
        Text("GR")
    }
}
