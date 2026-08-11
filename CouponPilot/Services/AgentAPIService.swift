import Foundation
import FirebaseAuth
import FirebaseCore

struct RecommendationRequest: Codable {
    let storeId: String
    let storeName: String
    let expectedPrice: Int
    let profile: UserProfile
    let coupons: [Coupon]
}

/// Gemini가 기기 OCR 텍스트에서 보수적으로 추출한 쿠폰 초안입니다. 원본 이미지는 전송하지 않습니다.
struct CouponNormalization: Decodable {
    let brand: String?
    let productName: String?
    let discountType: String
    let discountValue: Int?
    let minimumOrderAmount: Int?
    let expiresAt: String?
    let conditions: [String]
    let requiresConfirmation: Bool
}

struct AgentAPIService {
    /// API Gateway verifies Firebase ID tokens before forwarding to the private Cloud Run service.
    var baseURL = URL(string: "https://coupon-pilot-mobile-7o9xbhxu.an.gateway.dev")!

    private func authenticatedRequest(url: URL, method: String) async throws -> URLRequest {
        guard FirebaseApp.app() != nil, let user = Auth.auth().currentUser else {
            throw URLError(.userAuthenticationRequired)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try await user.getIDToken())", forHTTPHeaderField: "Authorization")
        return request
    }

    func fetchNearbyStores(latitude: Double, longitude: Double) async throws -> [Store] {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/stores/nearby"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(latitude)), URLQueryItem(name: "lng", value: String(longitude)),
            URLQueryItem(name: "radius", value: "1500")
        ]
        let request = try await authenticatedRequest(url: components.url!, method: "GET")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(NearbyStoreResponse.self, from: data).stores.map {
            Store(id: $0.id, name: $0.name, category: $0.category, latitude: $0.latitude, longitude: $0.longitude, radiusMeters: 120)
        }
    }

    func fetchRecommendation(for store: Store, expectedPrice: Int, profile: UserProfile, coupons: [Coupon]) async throws -> Recommendation {
        // 배포 전에도 화면 흐름을 검증할 수 있는 데모 응답입니다.
        guard !baseURL.absoluteString.contains("REPLACE_ME") else { return .preview }

        var request = try await authenticatedRequest(url: baseURL.appendingPathComponent("v1/recommendations"), method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RecommendationRequest(storeId: store.id, storeName: store.name, expectedPrice: expectedPrice, profile: profile, coupons: coupons))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Recommendation.self, from: data)
    }

    func normalizeCoupon(rawText: String) async throws -> CouponNormalization {
        var request = try await authenticatedRequest(url: baseURL.appendingPathComponent("v1/coupons/normalize"), method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["rawText": rawText])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(CouponNormalizationResponse.self, from: data).coupon
    }
}

private struct NearbyStoreResponse: Decodable {
    let stores: [NearbyStore]
}

private struct CouponNormalizationResponse: Decodable {
    let coupon: CouponNormalization
}

private struct NearbyStore: Decodable {
    let id: String
    let name: String
    let category: String
    let latitude: Double
    let longitude: Double
}
