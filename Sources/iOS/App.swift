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
        tabs
        // Already on the camera's Wi-Fi (joined in Settings, or still joined from last time):
        // connect without asking.
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active, connection.state == .disconnected || connection.state == .lost else { return }
            Task {
                // GRLINK_CAMERA_URL (scripts/mock_camera.py, in the Simulator) has no camera Wi-Fi to notice.
                let mock = ProcessInfo.processInfo.environment["GRLINK_CAMERA_URL"] != nil
                let ssid = mock ? "GR_MOCK" : await WiFi.currentSSID()
                if let ssid, ssid.hasPrefix("GR_"), !connection.isConnected, !connection.isBusy {
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

    /// iPad: 설정 → 메뉴 위치. "bottom" (default) is the iPhone's tab bar at the bottom;
    /// "sidebar" is a Mac-like sidebar that narrows to icons.
    @AppStorage(IPadMenu.key) private var iPadMenu = IPadMenu.bottom
    /// The real width class, handed back to the tabs' content when the bar is forced to the
    /// iPhone style.
    @Environment(\.horizontalSizeClass) private var sizeClass

    @ViewBuilder private var tabs: some View {
        if UIDevice.current.userInterfaceIdiom == .pad, iPadMenu == IPadMenu.sidebar {
            SidebarLayout(section: $section)
        } else {
            // A compact width class makes iPad draw the tab bar at the bottom, as on iPhone;
            // each tab gets the real class back so its own layout still uses the space.
            let real = sizeClass
            TabView(selection: $section) {
                CameraTab(active: section == .camera) { section = .library }
                    .environment(\.horizontalSizeClass, real)
                    .tabItem { Label(Pane.camera.rawValue, systemImage: Pane.camera.icon) }.tag(Pane.camera)
                LibraryTab { section = .camera }
                    .environment(\.horizontalSizeClass, real)
                    .tabItem { Label(Pane.library.rawValue, systemImage: Pane.library.icon) }.tag(Pane.library)
                NavigationStack { MomentView() }
                    .environment(\.horizontalSizeClass, real)
                    .tabItem { Label(Pane.moment.rawValue, systemImage: Pane.moment.icon) }.tag(Pane.moment)
                SettingsTab()
                    .environment(\.horizontalSizeClass, real)
                    .tabItem { Label(Pane.settings.rawValue, systemImage: Pane.settings.icon) }.tag(Pane.settings)
            }
            .environment(\.horizontalSizeClass, .compact)
        }
    }
}

/// iPad's sidebar: always there, either with names or narrowed to icons by the button at
/// its top (the system sidebar would turn into a tab bar instead). Every section stays
/// alive underneath so switching keeps its scroll position and navigation.
private struct SidebarLayout: View {
    @Binding var section: Pane
    @AppStorage("iPadSidebarWide") private var wide = true
    /// The shooting screen is open in the 카메라 section.
    @State private var shooting = false

    private let panes: [Pane] = [.camera, .library, .moment, .settings]

    var body: some View {
        HStack(spacing: 0) {
            if !(shooting && section == .camera) {
                sidebar
                Divider().ignoresSafeArea()
            }
            ZStack {
                page(.camera) {
                    CameraTab(active: section == .camera) { section = .library }
                        .onPreferenceChange(HidesAppMenu.self) { hide in
                            withAnimation(.snappy) { shooting = hide }
                        }
                }
                page(.library) { LibraryTab { section = .camera } }
                page(.moment) { NavigationStack { MomentView() } }
                page(.settings) { SettingsTab() }
            }
        }
    }

    private func page<V: View>(_ pane: Pane, @ViewBuilder _ view: () -> V) -> some View {
        view()
            .opacity(section == pane ? 1 : 0)
            .allowsHitTesting(section == pane)
            .accessibilityHidden(section != pane)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy) { wide.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(wide ? "사이드바 줄이기" : "사이드바 늘리기")
            .padding(.bottom, 8)
            ForEach(panes) { pane in
                let on = section == pane
                Button { section = pane } label: {
                    HStack(spacing: 12) {
                        Image(systemName: pane.icon).font(.title3).frame(width: 28)
                        if wide { Text(pane.rawValue).font(.body.weight(on ? .semibold : .regular)) }
                    }
                    .frame(maxWidth: .infinity, alignment: wide ? .leading : .center)
                    .padding(.horizontal, wide ? 12 : 0).padding(.vertical, 10)
                    .foregroundStyle(on ? Color.accentColor : .primary)
                    .background(on ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pane.rawValue)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.top, 8)
        .frame(width: wide ? 220 : 68)
        .background(Color(.secondarySystemBackground))
    }
}

/// Where iPad shows the four sections.
enum IPadMenu {
    static let key = "iPadMenu"
    static let bottom = "bottom", sidebar = "sidebar"
}

extension View {
    /// Keeps lists and forms at a readable width on iPad instead of running edge to edge.
    func readableWidth(_ maxWidth: CGFloat = 720) -> some View {
        modifier(ReadableWidth(maxWidth: maxWidth))
    }
}

private struct ReadableWidth: ViewModifier {
    let maxWidth: CGFloat
    @Environment(\.horizontalSizeClass) private var sizeClass

    @ViewBuilder func body(content: Content) -> some View {
        if sizeClass == .regular {
            GeometryReader { geo in
                content.contentMargins(.horizontal, max((geo.size.width - maxWidth) / 2, 20), for: .scrollContent)
            }
        } else {
            // iPhone keeps the list's own side margins; setting them to 0 removed them.
            content
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
/// (and back), and the full-screen gallery (내 사진전) follows the phone either way. iPad
/// keeps every orientation.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Orientation.allowed
    }
}

@MainActor
enum Orientation {
    static var allowed: UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad { return .all }
        if free { return .allButUpsideDown }
        return landscape ? .landscape : .portrait
    }
    private(set) static var landscape = false
    private(set) static var free = false

    /// Lets the phone turn any way (true) or puts it back upright (false).
    static func setFree(_ free: Bool) {
        self.free = free
        guard UIDevice.current.userInterfaceIdiom != .pad,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        if !free { scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait)) }
    }

    static func set(landscape: Bool) {
        self.landscape = landscape
        guard UIDevice.current.userInterfaceIdiom != .pad,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait))
    }
}
