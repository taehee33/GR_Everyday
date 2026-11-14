import SwiftUI

struct SettingsTab: View {
    @EnvironmentObject var connection: ConnectionModel
    @EnvironmentObject var library: LibraryModel
    @AppStorage("turnOffCameraWiFi") private var turnOffCameraWiFi = false
    @AppStorage(LibraryModel.AutoSave.enabled) private var autoSave = false
    @AppStorage(LibraryModel.AutoSave.jpeg) private var autoJPEG = true
    @AppStorage(LibraryModel.AutoSave.raw) private var autoRAW = true
    @AppStorage(LibraryModel.AutoSave.video) private var autoVideo = false
    @AppStorage(PhotosLibrary.pairRAWKey) private var pairRAW = false
    @AppStorage(PhotosLibrary.targetKey) private var saveTarget = PhotosLibrary.Target.photos.rawValue
    @ObservedObject private var history = SaveHistory.shared
    @AppStorage(ImageCache.sharpThumbnailsKey) private var sharpThumbnails = false
    @State private var cacheSize: Int64 = 0
    @State private var showSharpInfo = false
    @AppStorage(IPadMenu.key) private var iPadMenu = IPadMenu.bottom

    var body: some View {
        NavigationStack {
            Form {
                MomentAccountSection()
                MomentGalleryPagingSection()

                if UIDevice.current.userInterfaceIdiom == .pad {
                    Section {
                        menuChoice("아래 탭", detail: "iPhone처럼 화면 아래에", icon: "dock.rectangle", value: IPadMenu.bottom)
                        menuChoice("왼쪽 사이드바", detail: "Mac처럼 왼쪽에, 아이콘만 보이게 줄일 수 있어요",
                                   icon: "sidebar.left", value: IPadMenu.sidebar)
                    } header: {
                        Text("메뉴 위치")
                    }
                }

                Section {
                    Picker("저장 위치", selection: $saveTarget) {
                        ForEach(PhotosLibrary.Target.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    if target.toPhotos {
                        // Only iOS Settings can change Photos access once asked, so the
                        // whole row opens it (or asks, the first time).
                        Button {
                            if history.readStatus == .notDetermined {
                                Task { await history.requestRead() }
                            } else if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            HStack {
                                Text("사진 앱에서 지운 사진 확인").foregroundStyle(.primary)
                                Spacer()
                                Text(readStatusText).foregroundStyle(.secondary)
                                Image(systemName: history.readStatus == .notDetermined ? "chevron.right" : "arrow.up.forward.app")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Toggle("연결하면 새 사진 자동 저장", isOn: $autoSave)
                    if autoSave {
                        // Indented: these only say what 자동 저장 saves.
                        Group {
                            Toggle("JPG", isOn: $autoJPEG)
                            Toggle("RAW (DNG)", isOn: $autoRAW)
                            Toggle("동영상", isOn: $autoVideo)
                        }
                        .padding(.leading, 24)
                    }
                    if target.toPhotos {
                        Toggle("RAW+JPG를 사진 앱에 한 항목으로", isOn: $pairRAW)
                    }
                } header: {
                    Text("사진 저장")
                } footer: {
                    Text(saveFooter)
                }

                Section {
                    Toggle("연결을 끊을 때 카메라 Wi-Fi도 끄기", isOn: $turnOffCameraWiFi)
                } header: {
                    Text("연결")
                } footer: {
                    Text("다음에 연결할 때 Bluetooth로 다시 켜요.")
                }

                Section {
                    Toggle(isOn: $sharpThumbnails) {
                        HStack(spacing: 6) {
                            Text("미리보기 더 선명하게")
                            Button { showSharpInfo = true } label: { Image(systemName: "info.circle") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("미리보기 선명도 자세히")
                        }
                    }
                    LabeledContent("저장된 캐시", value: ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                    Button("캐시 비우기", role: .destructive) {
                        library.clearCaches()
                        cacheSize = library.cacheSize
                    }
                } header: {
                    Text("저장 공간")
                } footer: {
                    Text("카메라 없이도 지난번 사진 목록을 볼 수 있게 남겨 둬요. 비우면 다음 연결 때 다시 받아요.")
                }

                Section {
                    NavigationLink { AppIconPicker() } label: {
                        Label("앱 로고", systemImage: "app.badge")
                    }
                }

                Section {
                    NavigationLink { AboutView() } label: {
                        LabeledContent {
                            Text(AppInfo.version)
                        } label: {
                            Label("앱 정보 및 지원", systemImage: "info.circle")
                        }
                    }
                }
            }
            .readableWidth()
            .navigationTitle("설정")
            .toolbarTitleDisplayMode(.inlineLarge)
            .task { cacheSize = library.cacheSize }
            .onChange(of: saveTarget) { library.refreshSaved() }
            .sheet(isPresented: $showSharpInfo) { sharpInfo }
        }
    }

    private var target: PhotosLibrary.Target { PhotosLibrary.Target(rawValue: saveTarget) ?? .photos }

    private var readStatusText: String {
        switch history.readStatus {
        case .authorized: return "켜짐"
        case .limited: return "새로 저장한 사진만"
        case .notDetermined: return "허용하기"
        default: return "꺼짐"
        }
    }

    private var saveFooter: String {
        var text: String
        switch target {
        case .photos: text = "사진 앱에만 저장해요. 같은 사진이 파일 앱에 한 번 더 쌓이지 않아요."
        case .both: text = "사진 앱과 파일 앱의 ‘GR Everyday’ 폴더에 함께 저장해요. 사진 앱에서 지워도 파일 앱 사본으로 다시 넣을 수 있어요."
        case .files: text = "파일 앱의 ‘GR Everyday’ 폴더에만 저장해요. 사진 앱에는 넣지 않아요."
        }
        if target.toPhotos {
            text += " ‘한 항목으로’를 켜면 같은 사진의 JPG와 RAW가 사진 앱에서 한 장으로 보여요."
            text += " ‘지운 사진 확인’을 허용하면 사진 앱에서 지운 사진을 건너뛰지 않고 다시 저장해요. 허용한 뒤에는 이 줄을 눌러 설정 앱에서 바꿀 수 있어요."
        }
        return text
    }

    private func menuChoice(_ title: String, detail: String, icon: String, value: String) -> some View {
        Button {
            withAnimation { iPadMenu = value }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title3).frame(width: 30).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if iPadMenu == value {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// What 미리보기 더 선명하게 changes. Measured on a GR IV HDF: the camera's thumbs for
    /// JPEGs are 160 × 120 (avg 7 KB), its 720 px previews avg 55 KB.
    private var sharpInfo: some View {
        func size(_ kb: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(kb) * 1024, countStyle: .file) }
        let count = library.jpegOnlyCount
        return NavigationStack {
            Form {
                Section {
                    LabeledContent("꺼짐", value: "160 × 120px")
                    LabeledContent("켜짐", value: "720 × 480px")
                } header: {
                    Text("썸네일")
                } footer: {
                    Text("카메라는 JPG에 작은 썸네일만 줘요. RAW와 함께 찍은 사진은 원래 RAW의 720px 썸네일을 써서 켜든 끄든 같아요. 켜면 JPG만 있는 사진도 720px 미리보기를 받아 둬서 확대해도 덜 뭉개져요.")
                }
                Section {
                    LabeledContent("사진 1장", value: "약 \(size(7)) → 약 \(size(55))")
                    LabeledContent("100장", value: "약 \(size(700)) → 약 \(size(5500))")
                    if count > 0 {
                        LabeledContent("지금 카드 (JPG만 \(count)장)", value: "약 \(size(count * 7)) → 약 \(size(count * 55))")
                    }
                } header: {
                    Text("저장 공간")
                } footer: {
                    Text("받는 시간도 조금 늘어요. 바꾼 설정은 다음 연결 때부터 적용되고, 캐시를 비우면 다시 줄어요.")
                }
            }
            .navigationTitle("미리보기 더 선명하게")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { showSharpInfo = false } } }
        }
        .presentationDetents([.medium, .large])
    }
}
