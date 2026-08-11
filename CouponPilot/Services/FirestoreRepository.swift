@preconcurrency import FirebaseFirestore

/// Coupon images and OCR raw text are intentionally excluded: only confirmed coupon fields are synced.
@MainActor
final class FirestoreRepository {
    static let shared = FirestoreRepository()
    private let database = Firestore.firestore()

    func loadUserData(uid: String) async throws -> (profile: UserProfile?, coupons: [Coupon], usedCoupons: [UsedCoupon]) {
        async let profileSnapshot = database.collection("users").document(uid).getDocument()
        async let couponSnapshot = database.collection("users").document(uid).collection("coupons").getDocuments()
        async let usedCouponSnapshot = database.collection("users").document(uid).collection("usedCoupons").getDocuments()
        let (profileDocument, couponDocuments, usedCouponDocuments) = try await (profileSnapshot, couponSnapshot, usedCouponSnapshot)
        let profile = profileDocument.exists ? profile(from: profileDocument.data() ?? [:], fallbackID: uid) : nil
        let coupons = couponDocuments.documents.compactMap { coupon(from: $0.data(), id: $0.documentID) }
        let usedCoupons = usedCouponDocuments.documents.compactMap { usedCoupon(from: $0.data(), id: $0.documentID) }
        return (profile, coupons, usedCoupons)
    }

    func save(profile: UserProfile, uid: String) async throws {
        try await database.collection("users").document(uid).setData([
            "carrier": profile.carrier,
            "membershipGrade": profile.membershipGrade,
            "monthlyBenefitStatus": profile.monthlyBenefitStatus.rawValue,
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true)
    }

    func save(coupon: Coupon, uid: String) async throws {
        var data: [String: Any] = [
            "brand": coupon.brand, "title": coupon.title, "discountType": coupon.discountType.rawValue,
            "discountValue": coupon.discountValue, "minimumOrderAmount": coupon.minimumOrderAmount,
            "expiresAt": Timestamp(date: coupon.expiresAt), "combinableWithCard": coupon.combinableWithCard,
            "conditions": coupon.conditions, "updatedAt": FieldValue.serverTimestamp()
        ]
        if let referencePrice = coupon.referencePrice { data["referencePrice"] = referencePrice }
        try await database.collection("users").document(uid).collection("coupons").document(coupon.id).setData(data, merge: true)
    }

    func moveToUsedHistory(coupon: Coupon, uid: String) async throws {
        let user = database.collection("users").document(uid)
        try await user.collection("usedCoupons").document(coupon.id).setData([
            "brand": coupon.brand, "productName": coupon.title, "expiresAt": Timestamp(date: coupon.expiresAt),
            "usedAt": FieldValue.serverTimestamp(), "source": "CouponPilot"
        ])
        try await user.collection("coupons").document(coupon.id).delete()
    }

    private func profile(from data: [String: Any], fallbackID: String) -> UserProfile? {
        guard let carrier = data["carrier"] as? String else { return nil }
        let grade = data["membershipGrade"] as? String ?? "확인 필요"
        let status = UserProfile.MonthlyBenefitStatus(rawValue: data["monthlyBenefitStatus"] as? String ?? "") ?? .unknown
        return UserProfile(id: fallbackID, carrier: carrier, membershipGrade: grade, monthlyBenefitStatus: status)
    }

    private func coupon(from data: [String: Any], id: String) -> Coupon? {
        guard let brand = data["brand"] as? String,
              let title = data["title"] as? String,
              let rawType = data["discountType"] as? String,
              let discountType = Coupon.DiscountType(rawValue: rawType),
              let discountValue = data["discountValue"] as? Int,
              let minimumOrderAmount = data["minimumOrderAmount"] as? Int,
              let expiresAt = (data["expiresAt"] as? Timestamp)?.dateValue(),
              let combinableWithCard = data["combinableWithCard"] as? Bool else { return nil }
        return Coupon(id: id, brand: brand, title: title, discountType: discountType, discountValue: discountValue,
                      minimumOrderAmount: minimumOrderAmount, expiresAt: expiresAt, combinableWithCard: combinableWithCard,
                      referencePrice: data["referencePrice"] as? Int,
                      conditions: data["conditions"] as? [String] ?? [], localImageFilename: nil)
    }

    private func usedCoupon(from data: [String: Any], id: String) -> UsedCoupon? {
        guard let brand = data["brand"] as? String,
              let productName = data["productName"] as? String,
              let expiresAt = (data["expiresAt"] as? Timestamp)?.dateValue() else { return nil }
        let usedAt = (data["usedAt"] as? Timestamp)?.dateValue() ?? .now
        return UsedCoupon(
            id: id,
            brand: brand,
            productName: productName,
            expiresAt: expiresAt,
            orderNumber: "앱에서 사용 처리",
            barcodeLast4: "-",
            usedAt: usedAt,
            source: data["source"] as? String ?? "CouponPilot"
        )
    }
}
