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

/// 카메라 · 라이브러리 · Moment · 설정. 카메라 connects and, once the camera is on Wi-Fi,
/// becomes the shooting screen; 촬영 통계 is a view inside 라이브러리.
struct RootView: View {
    @EnvironmentObject var connection: ConnectionModel
    @EnvironmentObject var library: LibraryModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var section: Pane = .camera

    var body: some View {
        TabView(selection: $section) {
            CameraTab(active: section == .camera) { section = .library }
                .tabItem { Label(Pane.camera.rawValue, systemImage: Pane.camera.icon) }.tag(Pane.camera)
            LibraryTab { section = .camera }
                .tabItem { Label(Pane.library.rawValue, systemImage: Pane.library.icon) }.tag(Pane.library)
            NavigationStack { MomentView() }
                .tabItem { Label(Pane.moment.rawValue, systemImage: Pane.moment.icon) }.tag(Pane.moment)
            SettingsTab()
                .tabItem { Label(Pane.settings.rawValue, systemImage: Pane.settings.icon) }.tag(Pane.settings)
        }
        // Already on the camera's Wi-Fi (joined in Settings, or still joined from last time):
        // connect without asking.
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active, connection.state == .disconnected || connection.state == .lost else { return }
            Task {
                if let ssid = await WiFi.currentSSID(), ssid.hasPrefix("GR_"), !connection.isConnected, !connection.isBusy {
                    await connection.connectDirect()
                }
            }
        }
        .onChange(of: connection.state) { _, state in
            if state == .connected {
                library.prepareAutoSave(viaUSB: connection.viaUSB)
                Task { await library.reload() }
            }
        }
    }
}

/// The connection screen, with the shooting screen pushed over it: on its own once the
/// camera joins Wi-Fi, or from the 원격 촬영 tile even without a camera. Back (or the camera
/// bar at its top) returns to the connection screen.
struct CameraTab: View {
    let active: Bool
    let openLibrary: () -> Void
    @EnvironmentObject var connection: ConnectionModel
    @State private var path: [Route] = []

    enum Route: Hashable { case shoot }

    /// USB can't shoot, so it stays on the connection screen.
    private var shooting: Bool { !connection.viaUSB && (connection.isConnected || connection.state == .lost) }

    var body: some View {
        NavigationStack(path: $path) {
            CameraScreen(openLibrary: openLibrary, openShoot: { path = [.shoot] })
                .navigationDestination(for: Route.self) { _ in
                    ShootView(active: active) { path = [] }
                }
        }
        .onChange(of: shooting, initial: true) { _, now in
            if now, path.isEmpty { path = [.shoot] }
        }
    }
}
