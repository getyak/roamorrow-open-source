import Photos
import UIKit
import Observation

@MainActor
@Observable
final class CompanionPhotoLibrary {
    private(set) var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var assets: [PHAsset] = []
    private(set) var requestingAccess = false

    static func canRead(_ status: PHAuthorizationStatus) -> Bool {
        status == .authorized || status == .limited
    }

    /// Merely opening the attachment sheet never requests broader access.
    func refresh() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard Self.canRead(status) else { assets = []; return }
        let options = PHFetchOptions()
        options.fetchLimit = 12
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        assets = (0..<result.count).map { result.object(at: $0) }
    }

    func requestAccess() async {
        guard !requestingAccess, status == .notDetermined else { refresh(); return }
        requestingAccess = true
        defer { requestingAccess = false }
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard !Task.isCancelled else { return }
        refresh()
    }

    nonisolated static func thumbnail(_ asset: PHAsset) async throws -> UIImage {
        return try await CompanionPhotoRequest<UIImage>().value { finish in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            let manager = PHImageManager.default()
            let id = manager.requestImage(for: asset, targetSize: CGSize(width: 224, height: 224),
                contentMode: .aspectFill, options: options) { image, info in
                if let image { finish(.success(image)) }
                else { finish(.failure(info?[PHImageErrorKey] as? Error ?? CompanionMediaPreparation.Failure.invalidFile)) }
            }
            return { manager.cancelImageRequest(id) }
        }
    }

    static func original(_ asset: PHAsset) async throws -> Data {
        return try await CompanionPhotoRequest<Data>().value { finish in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.version = .current
            options.isNetworkAccessAllowed = true
            let manager = PHImageManager.default()
            let id = manager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                if let data {
                    guard data.count <= 10 * 1_024 * 1_024 else {
                        finish(.failure(CompanionMediaPreparation.Failure.tooLarge)); return
                    }
                    finish(.success(data))
                } else {
                    finish(.failure(info?[PHImageErrorKey] as? Error ?? CompanionMediaPreparation.Failure.invalidFile))
                }
            }
            return { manager.cancelImageRequest(id) }
        }
    }
}
