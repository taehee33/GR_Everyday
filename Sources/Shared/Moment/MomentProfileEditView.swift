import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Profile pictures: the square the owner framed in the round crop, 512 px sRGB JPEG with no
/// metadata (no GPS), small enough for profile-avatar's 300 KB limit.
enum MomentAvatar {
    static let edge = 512

    /// The picked photo turned upright, at most 2048 px, for the crop screen.
    static func upright(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// `crop` (in the image's pixels) scaled to 512 × 512 and encoded.
    static func render(_ image: CGImage, crop: CGRect) -> Data? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let square = image.cropping(to: crop.integral.intersection(bounds)),
              let context = CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: MomentImage.sRGB,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: edge, height: edge))
        guard let scaled = context.makeImage() else { return nil }
        for quality in [0.85, 0.7, 0.55] {
            if let jpeg = MomentImage.encode(scaled, type: .jpeg, quality: quality), jpeg.count < 300_000 {
                return jpeg
            }
        }
        return nil
    }
}

/// Framing a profile picture: the photo under a round guide; drag to move it, pinch (or the
/// slider) to zoom. The photo always covers the circle.
struct MomentAvatarCropper: View {
    let image: CGImage
    let onDone: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var zoomStart: CGFloat?

    private static let side: CGFloat = 300
    private var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
    /// Points per image pixel at zoom 1: the shorter side just fills the circle.
    private var baseScale: CGFloat { Self.side / min(pixelSize.width, pixelSize.height) }
    private var scale: CGFloat { baseScale * zoom }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 0)
                ZStack {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: pixelSize.width * scale, height: pixelSize.height * scale)
                        .offset(offset)
                    // Dim everything outside the circle, then draw the guide.
                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                        .mask {
                            Rectangle()
                                .overlay { Circle().frame(width: Self.side, height: Self.side).blendMode(.destinationOut) }
                                .compositingGroup()
                        }
                        .allowsHitTesting(false)
                    Circle()
                        .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                        .frame(width: Self.side, height: Self.side)
                        .allowsHitTesting(false)
                }
                .frame(width: Self.side + 60, height: Self.side + 60)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let start = dragStart ?? offset
                            dragStart = start
                            offset = clamped(CGSize(width: start.width + value.translation.width,
                                                    height: start.height + value.translation.height), zoom: zoom)
                        }
                        .onEnded { _ in dragStart = nil }
                        .simultaneously(with:
                            MagnifyGesture()
                                .onChanged { value in
                                    let start = zoomStart ?? zoom
                                    zoomStart = start
                                    setZoom(start * value.magnification)
                                }
                                .onEnded { _ in zoomStart = nil }
                        )
                )
                HStack(spacing: 12) {
                    Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { zoom }, set: setZoom), in: 1...5)
                    Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                }
                .frame(maxWidth: Self.side)
                Text("끌어서 위치를, 두 손가락이나 막대로 크기를 맞춰 주세요.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding()
            .background(Color.black.ignoresSafeArea())
            .environment(\.colorScheme, .dark)
            .navigationTitle("사진 맞추기")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") {
                        if let jpeg = MomentAvatar.render(image, crop: cropRect) { onDone(jpeg) }
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    private func setZoom(_ value: CGFloat) {
        zoom = min(max(value, 1), 5)
        offset = clamped(offset, zoom: zoom)
    }

    /// Keeps the photo over the whole circle.
    private func clamped(_ offset: CGSize, zoom: CGFloat) -> CGSize {
        let s = baseScale * zoom
        let maxX = max((pixelSize.width * s - Self.side) / 2, 0)
        let maxY = max((pixelSize.height * s - Self.side) / 2, 0)
        return CGSize(width: min(max(offset.width, -maxX), maxX), height: min(max(offset.height, -maxY), maxY))
    }

    /// The square under the circle, in the image's pixels.
    private var cropRect: CGRect {
        let sidePixels = Self.side / scale
        let x = pixelSize.width / 2 - offset.width / scale - sidePixels / 2
        let y = pixelSize.height / 2 - offset.height / scale - sidePixels / 2
        return CGRect(x: x, y: y, width: sidePixels, height: sidePixels)
    }
}

/// The round profile picture, or the first letter of the name when there is none.
struct MomentAvatarView: View {
    let store: MomentStore
    let profile: MomentProfile?
    var size: CGFloat = 64
    /// A picture chosen but not saved yet (프로필 편집).
    var preview: Data? = nil
    /// Someone known only from a photo or comment (no full profile loaded).
    var owner: UUID? = nil
    var author: MomentAuthor? = nil

    init(store: MomentStore, profile: MomentProfile?, size: CGFloat = 64, preview: Data? = nil) {
        self.store = store
        self.profile = profile
        self.size = size
        self.preview = preview
    }

    init(store: MomentStore, owner: UUID, author: MomentAuthor?, size: CGFloat) {
        self.store = store
        self.profile = nil
        self.size = size
        self.owner = owner
        self.author = author
    }

    private var url: URL? {
        if let profile { return store.avatarURL(profile) }
        if let owner { return store.avatarURL(owner: owner, author: author) }
        return nil
    }

    var body: some View {
        Circle()
            .fill(.quaternary)
            .frame(width: size, height: size)
            .overlay {
                if let preview, let image = Self.image(preview) {
                    image.resizable().scaledToFill()
                } else if let url {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        initial
                    }
                } else {
                    initial
                }
            }
            .clipShape(Circle())
            .accessibilityLabel("프로필 사진")
    }

    private var initial: some View {
        Text(String((profile?.displayName ?? profile?.handle ?? author?.displayName ?? author?.handle ?? "?").prefix(1)).uppercased())
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    static func image(_ data: Data) -> Image? {
        #if os(iOS)
        UIImage(data: data).map(Image.init(uiImage:))
        #else
        NSImage(data: data).map(Image.init(nsImage:))
        #endif
    }
}

/// Instagram's camera glyph, drawn: a rounded square, the lens and the flash dot.
struct InstagramGlyph: View {
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .strokeBorder(lineWidth: size * 0.1)
            Circle()
                .strokeBorder(lineWidth: size * 0.1)
                .frame(width: size * 0.48, height: size * 0.48)
            Circle()
                .frame(width: size * 0.12, height: size * 0.12)
                .offset(x: size * 0.24, y: -size * 0.24)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 프로필 편집: picture, a short introduction, the camera in use (and whether to show it),
/// Instagram and one link. Names are changed in 설정 › 계정.
struct MomentProfileEditView: View {
    @ObservedObject var account: MomentAccount
    @Environment(\.dismiss) private var dismiss
    @State private var photoItem: PhotosPickerItem?
    /// The picked photo, waiting to be framed in the round crop.
    @State private var framing: FramingImage?
    @State private var newAvatar: Data?
    @State private var removeAvatar = false
    @State private var bio = ""
    @State private var showCamera = false
    /// Checked cameras from the list.
    @State private var chosen: Set<String> = []
    /// Typed cameras not in the list, comma separated ("GR Digital III, 리코 GR1v").
    @State private var otherCameras = ""
    @State private var instagram = ""
    @State private var website = ""
    @State private var saving = false
    @State private var message: String?
    @State private var confirmDelete = false

    private var instagramName: String? { instagram.isEmpty ? nil : MomentProfile.normalizeInstagram(instagram) }
    private var websiteLink: String? { website.isEmpty ? nil : MomentProfile.normalizeWebsite(website) }
    private var typedCameras: [String] {
        otherCameras.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces).prefix(40)) }
            .filter { !$0.isEmpty }
    }
    /// What is saved: the checked ones in list order, then the typed ones; none when hidden.
    private var cameraNames: [String] {
        guard showCamera else { return [] }
        var names = MomentProfile.cameraChoices.filter(chosen.contains)
        for name in typedCameras where !names.contains(name) { names.append(name) }
        return names
    }
    private var tooManyCameras: Bool { cameraNames.count > MomentProfile.camerasLimit }
    private var canSave: Bool {
        !saving && (instagram.isEmpty || instagramName != nil) && (website.isEmpty || websiteLink != nil)
            && bio.count <= MomentProfile.bioLimit && !tooManyCameras
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 10) {
                            MomentAvatarView(store: account.store, profile: removeAvatar ? nil : account.me,
                                             size: 96, preview: newAvatar)
                            HStack(spacing: 14) {
                                PhotosPicker(selection: $photoItem, matching: .images) {
                                    Text(account.me?.avatarVersion == nil && newAvatar == nil ? "사진 고르기" : "사진 바꾸기")
                                }
                                if newAvatar != nil || (account.me?.avatarVersion != nil && !removeAvatar) {
                                    Button("지우기", role: .destructive) {
                                        newAvatar = nil
                                        photoItem = nil
                                        removeAvatar = account.me?.avatarVersion != nil
                                    }
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(.callout)
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                Section {
                    NavigationLink {
                        MomentNameEditPage(account: account, kind: .displayName)
                    } label: {
                        LabeledContent("표시 이름", value: account.me?.displayName ?? "")
                    }
                    NavigationLink {
                        MomentNameEditPage(account: account, kind: .handle)
                    } label: {
                        LabeledContent("사용자명", value: account.me?.handle ?? "")
                    }
                } header: {
                    Text("이름")
                } footer: {
                    Text("이름은 바로 저장돼요.")
                }

                Section {
                    TextField("어떤 순간을 담고 있나요?", text: $bio, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("소개")
                } footer: {
                    Text("\(bio.count)/\(MomentProfile.bioLimit)")
                        .foregroundStyle(bio.count > MomentProfile.bioLimit ? Color.red : Color.secondary)
                }

                Section {
                    HStack(spacing: 10) {
                        InstagramGlyph(size: 18).foregroundStyle(.secondary)
                        TextField("인스타그램 사용자명", text: $instagram)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.asciiCapable)
                            #endif
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "link").foregroundStyle(.secondary).frame(width: 18)
                        TextField("웹사이트 (example.com)", text: $website)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                    }
                } header: {
                    Text("링크")
                } footer: {
                    if !instagram.isEmpty, instagramName == nil {
                        Text("인스타그램 사용자명은 영문, 숫자, 마침표(.), 밑줄(_)로 30자까지예요.").foregroundStyle(.red)
                    } else if !website.isEmpty, websiteLink == nil {
                        Text("웹사이트 주소를 확인해 주세요.").foregroundStyle(.red)
                    } else {
                        Text("프로필에 아이콘으로 보이고, 누르면 바로 열려요.")
                    }
                }

                Section {
                    Toggle("프로필에 공개", isOn: $showCamera)
                    if showCamera {
                        ForEach(MomentProfile.cameraChoices, id: \.self) { name in
                            Button {
                                if chosen.contains(name) { chosen.remove(name) } else { chosen.insert(name) }
                            } label: {
                                HStack {
                                    Text(name).foregroundStyle(.primary)
                                    Spacer()
                                    if chosen.contains(name) {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(chosen.contains(name) ? .isSelected : [])
                        }
                        TextField("그 밖의 카메라 (쉼표로 구분)", text: $otherCameras)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("사용 중인 카메라")
                } footer: {
                    if tooManyCameras {
                        Text("카메라는 \(MomentProfile.camerasLimit)대까지 보여 줄 수 있어요.").foregroundStyle(.red)
                    } else {
                        Text("여러 대를 고를 수 있어요. 끄면 카메라 정보를 저장하지 않아요.")
                    }
                }

                if let message {
                    Text(message).foregroundStyle(.red).font(.footnote)
                }

                Section {
                    Button("탈퇴", role: .destructive) { confirmDelete = true }
                        .momentDeleteAlert(account: account, isPresented: $confirmDelete)
                }
            }
            .formStyle(.grouped)
            // After 탈퇴 (or signing out elsewhere) there is no profile left to edit.
            .onChange(of: account.state) { _, state in if state != .ready { dismiss() } }
            .navigationTitle("프로필 편집")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("저장") { Task { await save() } }.disabled(!canSave)
                    }
                }
            }
            .onAppear(perform: fill)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = MomentAvatar.upright(data) else {
                        message = "이 사진을 프로필 사진으로 쓸 수 없어요."
                        return
                    }
                    framing = FramingImage(image: image)
                    photoItem = nil
                }
            }
        }
        .sheet(item: $framing) { item in
            MomentAvatarCropper(image: item.image) { jpeg in
                newAvatar = jpeg
                removeAvatar = false
                message = nil
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 620)
        #endif
    }

    struct FramingImage: Identifiable {
        let id = UUID()
        let image: CGImage
    }

    private func fill() {
        guard let me = account.me else { return }
        bio = me.bio ?? ""
        instagram = me.instagram ?? ""
        website = me.website ?? ""
        if !me.cameras.isEmpty {
            showCamera = true
            chosen = Set(me.cameras.filter(MomentProfile.cameraChoices.contains))
            otherCameras = me.cameras.filter { !MomentProfile.cameraChoices.contains($0) }.joined(separator: ", ")
        } else {
            // Not shown yet: suggest the cameras of my photos for when it is turned on.
            for shot in Set(account.myPhotos.compactMap(\.info.camera)) {
                if MomentProfile.cameraChoices.contains(shot) { chosen.insert(shot) }
            }
        }
    }

    private func save() async {
        saving = true
        message = nil
        defer { saving = false }
        let trimmedBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        let edit = MomentProfileEdit(bio: trimmedBio.isEmpty ? nil : trimmedBio,
                                     instagram: instagramName, website: websiteLink, cameras: cameraNames)
        let avatar: Data?? = newAvatar.map { .some($0) } ?? (removeAvatar ? .some(nil) : nil)
        if await account.saveProfile(edit, avatar: avatar) {
            dismiss()
        } else {
            message = account.errorMessage
        }
    }
}
