import SwiftUI
import UIKit

@main
struct GRConnectApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
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

/// The connection screen, with the shooting screen pushed over it from the 원격 촬영 tile
/// (with or without a camera). Back, or the camera bar at its top, returns.
struct CameraTab: View {
    let active: Bool
    let openLibrary: () -> Void
    @EnvironmentObject var connection: ConnectionModel
    @State private var path: [Route] = []

    enum Route: Hashable { case shoot }

    var body: some View {
        NavigationStack(path: $path) {
            CameraScreen(openLibrary: openLibrary, openShoot: { path = [.shoot] })
                .navigationDestination(for: Route.self) { _ in
                    ShootView(active: active) { path = [] }
                }
        }
    }
}

/// iPhone stays in portrait; the shooting screen's 가로 모드 button turns it to landscape
/// (and back). iPad keeps every orientation.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Orientation.allowed
    }
}

@MainActor
enum Orientation {
    static var allowed: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : (landscape ? .landscape : .portrait)
    }
    private(set) static var landscape = false

    static func set(landscape: Bool) {
        self.landscape = landscape
        guard UIDevice.current.userInterfaceIdiom != .pad,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait))
    }
}
