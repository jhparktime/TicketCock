import UIKit

/// 쿠폰 이미지의 앱 내부 보관소입니다. 네트워크 전송이나 Firebase 업로드를 하지 않습니다.
@MainActor
final class CouponImageStore {
    static let shared = CouponImageStore()

    private let directoryURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("CouponPilot/CouponImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
        return directory
    }()

    private init() {}

    func save(image: UIImage, couponID: String) throws -> String {
        let filename = "\(couponID).jpg"
        let url = directoryURL.appendingPathComponent(filename)
        guard let data = image.jpegData(compressionQuality: 0.88) else { throw CouponImageStoreError.encodingFailed }
        try data.write(to: url, options: .atomic)
        return filename
    }

    func image(named filename: String?) -> UIImage? {
        guard let filename else { return nil }
        return UIImage(contentsOfFile: directoryURL.appendingPathComponent(filename).path)
    }
}

enum CouponImageStoreError: Error { case encodingFailed }
