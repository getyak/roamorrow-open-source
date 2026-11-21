import SwiftUI
import Photos

@MainActor
struct CompanionRecentPhotos: View {
    let library: CompanionPhotoLibrary
    let importing: Bool
    let onChoose: (PHAsset) -> Void
    let onAllPhotos: () -> Void

    @State private var permissionTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(companionText("companion.media.recent", "最近照片")).font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Button(companionText("companion.media.allPhotos", "所有照片"), action: onAllPhotos)
                    .font(.subheadline).frame(minHeight: 44)
                    .accessibilityIdentifier("companion.media.allPhotos")
            }
            if CompanionPhotoLibrary.canRead(library.status) {
                if library.assets.isEmpty {
                    Text(companionText("companion.media.recentEmpty", "这里还没有可显示的照片。可从所有照片中选择。"))
                        .font(.footnote).foregroundStyle(CompanionHomeStyle.secondaryInk)
                        .frame(minHeight: 60, alignment: .leading)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            ForEach(Array(library.assets.enumerated()), id: \.element.localIdentifier) { index, asset in
                                Button { onChoose(asset) } label: {
                                    CompanionRecentPhotoThumbnail(asset: asset)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(String(format: companionText("companion.media.recentPhoto", "最近照片 %d"), index + 1))
                                .accessibilityIdentifier("companion.media.recent.\(index)")
                            }
                        }
                    }.frame(height: 92)
                }
                if library.status == .limited {
                    Text(companionText("companion.media.recentLimited", "这里只显示你允许访问的照片。"))
                        .font(.footnote).foregroundStyle(CompanionHomeStyle.secondaryInk)
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled").font(.title2).accessibilityHidden(true)
                    if library.status == .notDetermined {
                        Button {
                            permissionTask = Task { await library.requestAccess() }
                        } label: {
                            Text(companionText("companion.media.showRecent", "显示最近照片"))
                                .font(.subheadline).frame(minHeight: 44, alignment: .leading)
                        }
                        .disabled(library.requestingAccess)
                        .accessibilityIdentifier("companion.media.showRecent")
                        if library.requestingAccess { ProgressView() }
                    } else {
                        Text(companionText("companion.media.recentDenied", "仍可点击所有照片，选择要添加的图片。"))
                            .font(.footnote).foregroundStyle(CompanionHomeStyle.secondaryInk)
                    }
                    Spacer(minLength: 0)
                }.padding(14).background(CompanionHomeStyle.incoming, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .onDisappear { permissionTask?.cancel() }
        .disabled(importing)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("companion.media.recentPhotos")
    }
}

@MainActor
private struct CompanionRecentPhotoThumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            CompanionHomeStyle.incoming
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundStyle(CompanionHomeStyle.secondaryInk) }
        }
        .frame(width: 92, height: 92)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .task(id: asset.localIdentifier) {
            image = nil
            let loaded = try? await CompanionPhotoLibrary.thumbnail(asset)
            guard !Task.isCancelled else { return }
            image = loaded
        }
        .accessibilityHidden(true)
    }
}
