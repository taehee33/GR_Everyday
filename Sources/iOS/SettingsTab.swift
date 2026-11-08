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
    @State private var cacheSize: Int64 = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("새 사진 자동 저장", isOn: $autoSave)
                    if autoSave {
                        Toggle("JPG", isOn: $autoJPEG)
                        Toggle("RAW (DNG)", isOn: $autoRAW)
                        Toggle("동영상", isOn: $autoVideo)
                    }
                    Toggle("이미 저장한 파일은 건너뛰기", isOn: $library.skipExisting)
                    Toggle("RAW+JPEG를 사진 앱에 한 장으로", isOn: $pairRAW)
                } header: {
                    Text("사진 저장")
                } footer: {
                    Text("저장한 사진은 사진 앱과, 파일 앱의 ‘GR Connect’ 폴더에 들어갑니다. 자동 저장은 연결할 때 아직 저장하지 않은 사진을 받습니다.\nRAW+JPEG를 켜면 같은 이름의 JPG와 DNG를 함께 저장할 때 사진 앱에 한 항목(JPEG로 표시, RAW 포함)으로 넣습니다. 끄면 지금처럼 각각 따로 보입니다.")
                }

                Section {
                    Toggle("연결을 끊을 때 카메라 Wi-Fi도 끄기", isOn: $turnOffCameraWiFi)
                } header: {
                    Text("연결")
                } footer: {
                    Text("끄면 다음 연결 때 Bluetooth로 카메라 Wi-Fi를 다시 켭니다.")
                }

                Section {
                    LabeledContent("저장된 캐시", value: ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                    Button("캐시 비우기", role: .destructive) {
                        library.clearCaches()
                        cacheSize = library.cacheSize
                    }
                } header: {
                    Text("캐시")
                } footer: {
                    Text("마지막으로 본 카드의 사진 목록·썸네일을 남겨 두어, 카메라 없이도 라이브러리를 볼 수 있습니다. 비우면 다음 연결 때 다시 받습니다.")
                }

                Section("정보") {
                    LabeledContent("버전", value: version)
                    LabeledContent("빌드", value: build)
                }
            }
            .navigationTitle("설정")
            .task { cacheSize = library.cacheSize }
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }

    private var build: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return [info["CFBundleVersion"] as? String, info["GRBuildCommit"] as? String].compactMap { $0 }.joined(separator: " · ")
    }
}
