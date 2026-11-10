import CoreBluetooth
import SwiftUI
#if os(iOS)
import Photos
import UIKit
#else
import AppKit
#endif

/// Who runs the app and how to reach them. Shown in 앱 정보 및 지원 and the documents.
enum AppInfo {
    static let name = "GR Everyday"
    /// Operator shown in the privacy policy and terms.
    static let operatorName = "GR Everyday 개발자"
    static let supportEmail = "hth3381@naver.com"
    /// Effective date of the privacy policy and terms.
    static let effectiveDate = "2026-11-09"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "개발 빌드"
    }

    /// "12 · 85651f7 · 2026-10-31 23:55"; only in the diagnostics.
    static var build: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return [info["CFBundleVersion"] as? String, info["GRBuildCommit"] as? String, info["GRBuildDate"] as? String]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Hardware model, e.g. "iPhone13,3" or "Mac14,2".
    static var hardware: String {
        #if os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
        #else
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #endif
    }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        let name = "macOS"
        #else
        let name = "iOS"
        #endif
        return "\(name) \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }
}

/// 설정 → 앱 정보 및 지원: how to use, policies, contact, and the trademark notice.
struct AboutView: View {
    @EnvironmentObject var connection: ConnectionModel
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppInfo.name).font(.title.bold())
                    Text("\(AppInfo.version) · 무료 · 광고 없음").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            Section {
                NavigationLink { DocumentView(document: .guide) } label: {
                    Label("사용 방법", systemImage: "questionmark.circle")
                }
                NavigationLink { ConnectionCheckView() } label: {
                    Label("연결 진단", systemImage: "stethoscope")
                }
            }

            Section {
                NavigationLink { DocumentView(document: .privacy) } label: {
                    Label("개인정보 처리방침", systemImage: "hand.raised")
                }
                NavigationLink { DocumentView(document: .terms) } label: {
                    Label("이용약관", systemImage: "doc.text")
                }
            }

            Section {
                Button { openURL(mailURL) } label: {
                    Label("이메일로 문의", systemImage: "envelope")
                }
                Button {
                    copy(diagnostics)
                    copied = true
                } label: {
                    Label(copied ? "복사했어요" : "진단 정보 복사", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                #if os(iOS)
                if FileManager.default.fileExists(atPath: DebugLog.url.path) {
                    ShareLink(item: DebugLog.url) { Label("연결 기록 보내기", systemImage: "square.and.arrow.up") }
                }
                #else
                Button { NSWorkspace.shared.activateFileViewerSelecting([DebugLog.url]) } label: {
                    Label("연결 기록 Finder에서 보기", systemImage: "folder")
                }
                #endif
            } header: {
                Text("문의")
            } footer: {
                Text("\(AppInfo.supportEmail)\n메일에는 앱 버전·기기·카메라 정보가 미리 들어가요. 문제를 빨리 찾는 데 쓰여요.")
            }

            Section {
            } footer: {
                Text("\(AppInfo.name)는 RICOH IMAGING과 제휴하지 않은 독립 앱이에요. RICOH 및 GR은 각 권리자의 상표예요.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("앱 정보 및 지원")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Version, device and camera, for the support mail and 진단 정보 복사.
    private var diagnostics: String {
        var lines = [
            "앱: \(AppInfo.name) \(AppInfo.version) (\(AppInfo.build))",
            "기기: \(AppInfo.hardware) · \(AppInfo.osVersion)",
        ]
        if connection.isConnected {
            var camera = connection.model
            if let firmware = connection.props["firmwareVersion"] as? String { camera += " · 펌웨어 \(firmware)" }
            lines.append("카메라: \(camera) · \(connection.route)")
        } else if let last = connection.cameras.max(by: { ($0.lastConnected ?? .distantPast) < ($1.lastConnected ?? .distantPast) }) {
            lines.append("카메라: \(last.shortModel ?? last.bleName) (연결 안 됨)")
        }
        if let message = connection.state.message { lines.append("상태: \(message)") }
        return lines.joined(separator: "\n")
    }

    private var mailURL: URL {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = AppInfo.supportEmail
        c.queryItems = [
            URLQueryItem(name: "subject", value: "[\(AppInfo.name)] 문의"),
            URLQueryItem(name: "body", value: "문의 내용을 적어주세요.\n\n\n\n---\n아래 정보는 문제 확인에 필요하니 지우지 말아주세요.\n\(diagnostics)\n"),
        ]
        return c.url!
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// A plain text document: guide, privacy policy or terms.
struct DocumentView: View {
    let document: AppDocument

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(document.title).font(.largeTitle.bold())
                    Text("시행일 \(AppInfo.effectiveDate) · \(AppInfo.operatorName)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(document.sections, id: \.0) { title, body in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title).font(.headline)
                        Text(body).font(.callout).foregroundStyle(.secondary)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(document.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

enum AppDocument {
    case guide, privacy, terms

    var title: String {
        switch self {
        case .guide: return "사용 방법"
        case .privacy: return "개인정보 처리방침"
        case .terms: return "이용약관"
        }
    }

    var sections: [(String, String)] {
        let app = AppInfo.name
        switch self {
        case .guide:
            return [
                ("처음 연결하기", "카메라에서 메뉴 → 무선 통신 설정 → Bluetooth → 페어링을 열어 두세요. \(app)의 카메라 탭에서 카메라 등록을 누르고, 목록에 나온 카메라를 고르세요. \(Self.deviceName)에 창이 뜨면 카메라 화면의 코드를 입력해 주세요."),
                ("사진 받기", "연결되면 라이브러리 탭에 카메라의 사진이 보여요. 선택을 누르고 사진을 고른 뒤 사진 앱에 저장을 눌러 주세요. 설정에서 새 사진 자동 저장을 켜면 연결할 때마다 아직 받지 않은 사진을 받아요. 카메라의 사진은 지우지 않아요."),
                ("원격 촬영", "카메라 탭의 원격 촬영에서 카메라 화면을 보며 셔터를 누를 수 있어요. 노출·이미지 컨트롤 같은 설정도 여기서 바꿀 수 있어요."),
                ("USB로 연결", "USB-C 케이블이나 USB 카메라 어댑터로 카메라를 연결하고 켠 뒤 카메라 탭의 USB로 연결을 눌러 주세요. USB로는 사진 보기와 저장만 돼요."),
                ("연결이 안 될 때", "카메라를 껐다 켠 뒤 다시 연결해 보세요. 그래도 안 되면 설정 → 앱 정보 및 지원 → 연결 진단에서 원인을 확인해 주세요. 예전 페어링 정보가 남아 등록이 안 되면, \(Self.deviceName)의 Bluetooth 설정에서 그 GR 카메라를 지운 뒤 다시 등록해 주세요."),
            ]
        case .privacy:
            return [
                ("운영자와 적용 범위", "\(app)는 \(AppInfo.operatorName)가 운영하는 카메라 사진 전송 앱이에요. 이 방침은 \(app)의 개인정보 처리와 지원 문의에 적용돼요. 문의 및 개인정보 관련 요청: \(AppInfo.supportEmail)"),
                ("앱이 처리하는 정보", "등록한 카메라의 Bluetooth 이름·식별자와 모델명, 카메라 Wi-Fi 이름과 암호, 카메라의 사진 목록·파일 이름·촬영 시각·파일 크기, 사진·동영상의 원본과 미리보기, 촬영 정보(노출 모드, 이미지 컨트롤 등)를 처리해요. 다시 연결하고 카메라 없이도 목록을 보기 위해 카메라 정보, 사진 목록, 썸네일, 촬영 기록, 저장 여부를 기기에 보관해요."),
                ("기기 안에서만 처리해요", "카메라의 파일은 카메라와 \(Self.deviceName) 사이에서 직접 전송돼요. 운영자는 서버를 두지 않으며 사진, 동영상, 카메라 정보, 사용 기록을 받거나 보관하지 않아요. 광고, 분석, 추적 도구를 쓰지 않아요."),
                ("권한", "Bluetooth는 카메라 등록과 Wi-Fi 켜기에, 로컬 네트워크와 Wi-Fi 연결은 카메라와 통신하는 데, 사진 접근은 고른 사진을 사진 앱에 저장하는 데 써요. Mac에서는 연결할 Wi-Fi 이름을 확인하기 위해 위치 권한을 요청할 수 있으며, 위치는 저장하지 않아요."),
                ("보관과 삭제", "앱에 보관한 정보는 설정에서 캐시를 비우거나 카메라 정보를 지우면 삭제돼요. 앱을 삭제하면 모두 지워져요. 사진 앱이나 저장 폴더에 저장한 사진은 사용자가 직접 관리해요."),
                ("문의할 때", "이메일로 문의하면 보낸 메일 주소와 내용, 메일에 넣은 진단 정보(앱 버전, 기기 모델, 운영체제 버전, 카메라 모델)를 문의에 답하는 데만 쓰고, 처리가 끝나면 지체 없이 삭제해요."),
                ("방침의 변경", "이 방침이 바뀌면 앱 업데이트와 함께 이 화면에 알려요."),
            ]
        case .terms:
            return [
                ("서비스와 운영자", "\(AppInfo.operatorName)는 \(app)를 무료로 제공해요. 현재 버전에는 광고, 구독, 인앱 결제가 없어요. 문의: \(AppInfo.supportEmail)"),
                ("이용 범위", "\(app)는 호환되는 RICOH GR 카메라의 사진·동영상 보기, 저장, 원격 촬영을 돕는 독립 앱이에요. RICOH IMAGING과 제휴하지 않았으며, RICOH 및 GR은 각 권리자의 상표예요. 카메라 모델·펌웨어와 기기 운영체제에 따라 기능이나 연결 방식이 다를 수 있어요."),
                ("사용자의 파일과 책임", "본인이 소유하거나 이용 권한이 있는 카메라와 파일에만 접근해야 해요. 사진과 동영상의 권리는 원래 권리자에게 있으며, 운영자는 그 파일에 대한 권리를 갖지 않아요. 저장하면 고른 원본을 기기에 복사하며, 이미 저장한 항목을 다시 저장하면 사본이 생길 수 있어요."),
                ("책임의 한계", "앱은 있는 그대로 제공돼요. 운영자는 안정적으로 동작하도록 노력하지만, 카메라·기기·네트워크 환경에 따른 연결 실패나 전송 중단까지 보증하지는 않아요. 중요한 사진은 카메라에서 지우기 전에 저장됐는지 확인해 주세요."),
                ("약관의 변경", "약관이 바뀌면 앱 업데이트와 함께 이 화면에 알려요."),
            ]
        }
    }

    private static var deviceName: String {
        #if os(macOS)
        return "Mac"
        #else
        return "iPhone"
        #endif
    }
}

/// Checks the usual reasons a camera won't connect, with a way to the app's permissions.
struct ConnectionCheckView: View {
    @EnvironmentObject var connection: ConnectionModel
    @State private var photosAllowed: Bool?

    var body: some View {
        Form {
            Section {
                row("Bluetooth 권한", ok: CBManager.authorization == .allowedAlways,
                    detail: CBManager.authorization == .notDetermined ? "아직 묻지 않았어요. 카메라를 등록할 때 물어요." : nil,
                    fix: "설정에서 Bluetooth를 허용해 주세요.")
                #if os(iOS)
                row("사진 저장 권한", ok: photosAllowed ?? false,
                    detail: photosAllowed == nil ? "아직 묻지 않았어요. 처음 저장할 때 물어요." : nil,
                    fix: "설정에서 사진 → ‘사진 추가만’ 이상으로 허용해 주세요.")
                #endif
            } header: {
                Text("권한")
            }

            Section {
                row("등록된 카메라", ok: !connection.cameras.isEmpty,
                    detail: connection.cameras.isEmpty ? nil : "\(connection.cameras.count)대",
                    fix: "카메라 탭에서 카메라를 먼저 등록해 주세요.")
                row("Bluetooth 연결", ok: connection.ble.linkedCameraID != nil, detail: nil,
                    fix: "카메라가 켜져 있고 가까이 있는지 확인해 주세요.")
                row("카메라 Wi-Fi", ok: connection.isConnected,
                    detail: connection.isConnected ? connection.route : nil,
                    fix: "카메라 탭에서 연결을 눌러 주세요.")
                if let message = connection.state.message {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                }
            } header: {
                Text("카메라")
            }

            Section {
                Button("앱 권한 설정 열기") { SystemSettings.openBluetooth() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("연결 진단")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
            case .authorized, .limited: photosAllowed = true
            case .notDetermined: photosAllowed = nil
            default: photosAllowed = false
            }
        }
        #endif
    }

    private func row(_ title: String, ok: Bool, detail: String?, fix: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail ?? (ok ? "정상이에요" : fix)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
