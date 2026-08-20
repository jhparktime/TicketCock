import CryptoKit
import Foundation
import Security

/// Firebase와 Apple 로그인 사이에서 재사용 공격을 막기 위한 요청별 nonce입니다.
enum AppleSignInNonce {
    static func make() -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = 32
        while remaining > 0 {
            var random: UInt8 = 0
            guard SecRandomCopyBytes(kSecRandomDefault, 1, &random) == errSecSuccess else {
                return UUID().uuidString
            }
            if random < UInt8(alphabet.count) {
                result.append(alphabet[Int(random)])
                remaining -= 1
            }
        }
        return result
    }

    static func sha256(_ nonce: String) -> String {
        SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
