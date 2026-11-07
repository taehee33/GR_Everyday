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

/// Tabs on iPhone; on iPad (iOS 18) the same tabs can become a sidebar.
struct RootView: View {
    @EnvironmentObject var connection: ConnectionModel
    @EnvironmentObject var library: LibraryModel
    @State private var section: Pane = .camera

    var body: some View {
        TabView(selection: $section) {
            CameraTab(section: $section)
                .tabItem { Label(Pane.camera.rawValue, systemImage: Pane.camera.icon) }.tag(Pane.camera)
            LibraryTab()
                .tabItem { Label(Pane.library.rawValue, systemImage: Pane.library.icon) }.tag(Pane.library)
            RemoteTab()
                .tabItem { Label(Pane.remote.rawValue, systemImage: Pane.remote.icon) }.tag(Pane.remote)
            Group {
                if library.photos.isEmpty {
                    NotConnectedView(section: $section)
                } else {
                    StatsView(stats: library.stats, section: $section)
                }
            }
            .tabItem { Label(Pane.stats.rawValue, systemImage: Pane.stats.icon) }.tag(Pane.stats)
            SettingsTab()
                .tabItem { Label(Pane.settings.rawValue, systemImage: Pane.settings.icon) }.tag(Pane.settings)
        }
        .onChange(of: connection.state) { _, state in
            if state == .connected {
                library.prepareAutoSave(viaUSB: false)
                Task { await library.reload() }
            }
        }
    }
}

struct NotConnectedView: View {
    @Binding var section: Pane

    var body: some View {
        ContentUnavailableView {
            Label("카메라에 연결되지 않음", systemImage: "camera")
        } description: {
            Text("카메라 탭에서 연결하세요.")
        } actions: {
            Button("카메라 탭으로") { section = .camera }.buttonStyle(.borderedProminent)
        }
    }
}

extension ConnectionModel.State {
    /// The message while busy or after a failure; nil when there is nothing to say.
    var message: String? {
        switch self {
        case .pairing(let m), .waking(let m), .joining(let m), .failed(let m): return m
        case .lost: return "카메라 연결이 끊겼습니다. 다시 연결하는 중…"
        case .connected, .disconnected: return nil
        }
    }
}
