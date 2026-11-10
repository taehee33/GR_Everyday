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
    @AppStorage(ImageCache.sharpThumbnailsKey) private var sharpThumbnails = false
    @State private var cacheSize: Int64 = 0
    @State private var showSharpInfo = false
    @AppStorage(IPadMenu.key) private var iPadMenu = IPadMenu.bottom

    var body: some View {
        NavigationStack {
            Form {
                if UIDevice.current.userInterfaceIdiom == .pad {
                    Section {
                        Picker("메뉴 위치", selection: $iPadMenu) {
                            Text("아래 탭").tag(IPadMenu.bottom)
                            Text("왼쪽 사이드바").tag(IPadMenu.sidebar)
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("화면")
                    } footer: {
                        Text("카메라 · 라이브러리 · 순간들 · 설정을 아래 탭으로 보일지, 왼쪽 사이드바로 보일지 골라요.")
                    }
                }

                Section {
                    Toggle("연결하면 새 사진 자동 저장", isOn: $autoSave)
                    if autoSave {
                        Toggle("JPG", isOn: $autoJPEG)
                        Toggle("RAW (DNG)", isOn: $autoRAW)
                        Toggle("동영상", isOn: $autoVideo)
                    }
                    Toggle("RAW+JPG를 한 장으로 저장", isOn: $pairRAW)
                } header: {
                    Text("사진 저장")
                } footer: {
                    Text("사진 앱과 파일 앱의 ‘GR Everyday’ 폴더에 저장돼요. ‘한 장으로’를 켜면 같은 사진의 JPG와 RAW가 사진 앱에 한 항목으로 들어가요.")
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
            .sheet(isPresented: $showSharpInfo) { sharpInfo }
        }
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
