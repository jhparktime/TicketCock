import CryptoKit
import Foundation
import Security
import UIKit

/// Redeemable coupon codes never enter Coupon, UserDefaults, Firestore, or an API request.
/// Their ciphertext and AES key are both device-only Keychain items.
struct CouponBarcodeCandidate: Identifiable, Hashable {
    enum Format: String, Codable, CaseIterable {
        case code128, qr, dataMatrix, pdf417, aztec

        var title: String {
            switch self {
            case .code128: "Code 128"
            case .qr: "QR 코드"
            case .dataMatrix: "Data Matrix"
            case .pdf417: "PDF417"
            case .aztec: "Aztec"
            }
        }
    }

    let value: String
    let format: Format
    var id: String { "\(format.rawValue):\(value)" }

    var maskedValue: String {
        guard value.count > 8 else { return value }
        return "\(value.prefix(4)) ···· \(value.suffix(4))"
    }
}

struct StoredCouponBarcode: Codable, Equatable {
    let value: String
    let format: CouponBarcodeCandidate.Format

    init(candidate: CouponBarcodeCandidate) {
        value = candidate.value
        format = candidate.format
    }
}

enum SecureCouponBarcodeStore {
    private static let keyService = "com.couponpilot.coupon-barcode.key"
    private static let valueService = "com.couponpilot.coupon-barcode.value"
    private static let keyAccount = "device-master-key-v1"

    static func save(_ candidate: CouponBarcodeCandidate, couponID: String) throws {
        guard candidate.value.utf8.count <= 512 else { throw BarcodeStoreError.invalidValue }
        let value = try JSONEncoder().encode(StoredCouponBarcode(candidate: candidate))
        guard let sealed = try AES.GCM.seal(value, using: encryptionKey()).combined else {
            throw BarcodeStoreError.encryptionFailed
        }
        try writeKeychainData(sealed, service: valueService, account: couponID)
    }

    static func barcode(for couponID: String) -> StoredCouponBarcode? {
        guard let sealed = readKeychainData(service: valueService, account: couponID),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let cleartext = try? AES.GCM.open(box, using: encryptionKey()),
              let barcode = try? JSONDecoder().decode(StoredCouponBarcode.self, from: cleartext) else {
            return nil
        }
        return barcode
    }

    static func delete(couponID: String) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: valueService,
            kSecAttrAccount: couponID
        ] as CFDictionary)
    }

    static func deleteAll() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: valueService] as CFDictionary)
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keyService,
            kSecAttrAccount: keyAccount
        ] as CFDictionary)
    }

    private static func encryptionKey() throws -> SymmetricKey {
        if let data = readKeychainData(service: keyService, account: keyAccount) { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try writeKeychainData(data, service: keyService, account: keyAccount)
        return key
    }

    private static func readKeychainData(service: String, account: String) -> Data? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &item)
        return status == errSecSuccess ? item as? Data : nil
    }

    private static func writeKeychainData(_ data: Data, service: String, account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw BarcodeStoreError.keychainFailure(updateStatus) }
        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw BarcodeStoreError.keychainFailure(addStatus) }
    }
}

enum CouponBarcodeRenderer {
    static func image(for barcode: StoredCouponBarcode) -> UIImage? {
        let filterName: String
        switch barcode.format {
        case .code128: filterName = "CICode128BarcodeGenerator"
        case .qr: filterName = "CIQRCodeGenerator"
        case .dataMatrix: filterName = "CIDataMatrixCodeGenerator"
        case .pdf417: filterName = "CIPDF417BarcodeGenerator"
        case .aztec: filterName = "CIAztecCodeGenerator"
        }
        guard let filter = CIFilter(name: filterName) else { return nil }
        filter.setValue(Data(barcode.value.utf8), forKey: "inputMessage")
        if barcode.format == .qr { filter.setValue("M", forKey: "inputCorrectionLevel") }
        guard let output = filter.outputImage else { return nil }
        let factor: CGFloat = barcode.format == .code128 ? 3 : 7
        let rendered = output.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(rendered, from: rendered.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

enum BarcodeStoreError: Error {
    case invalidValue, encryptionFailed
    case keychainFailure(OSStatus)
}
