import SwiftUI
import UIKit
import FirebaseAuth
import FirebaseCore

@main
struct CouponPilotApp: App {
    @StateObject private var appState = AppState()

    init() {
        // GoogleService-Info.plist가 번들에 포함된 실제 앱에서만 Firebase를 초기화합니다.
        if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            FirebaseApp.configure()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(.light)
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    enum StoreDirectoryState: Equatable {
        case awaitingLocation, loading, live, empty, unavailable

        var message: String {
            switch self {
            case .awaitingLocation: "위치를 확인하면 주변 매장을 불러올게요"
            case .loading: "수원시 매장 정보를 불러오는 중이에요"
            case .live: "주변 대상 매장을 감지하고 있어요"
            case .empty: "현재 위치 근처에 대상 매장이 없어요"
            case .unavailable: "매장 목록을 불러오지 못했어요"
            }
        }
    }

    enum RecommendationOrigin: Equatable {
        case live, demo
    }

    @Published var currentStore: Store?
    @Published var recommendation: Recommendation?
    @Published var isLoadingRecommendation = false
    @Published var shouldShowRecommendation = false
    @Published var recommendationOrigin: RecommendationOrigin = .live
    @Published private(set) var firebaseUserID: String?
    @Published private(set) var firebaseReady = false
    private var firebaseAuthenticationTask: Task<Void, Never>?

    @Published private(set) var profile: UserProfile
    @Published private(set) var coupons: [Coupon]
    @Published private(set) var nearbyStores: [Store] = []
    @Published private(set) var storeDirectoryState: StoreDirectoryState = .awaitingLocation
    @Published private(set) var usedCoupons: [UsedCoupon]

    init() {
        let savedUsedCoupons = Self.loadSavedUsedCoupons()
        let allUsedCoupons = Self.mergedUsedCoupons(UsedCoupon.sampleHistory, savedUsedCoupons)
        let usedIDs = Set(allUsedCoupons.map(\.id))
        let savedCoupons = Self.loadSavedCoupons().filter { !usedIDs.contains($0.id) }
        usedCoupons = allUsedCoupons
        coupons = Coupon.demoCoupons.filter { !usedIDs.contains($0.id) } + savedCoupons
        profile = Self.loadSavedProfile()

        guard FirebaseApp.app() != nil else { return }

        firebaseReady = true
        if let user = Auth.auth().currentUser {
            firebaseUserID = user.uid
            Task { await hydrateFirebaseData(uid: user.uid) }
        } else {
            startFirebaseAuthenticationIfNeeded()
        }
    }

    /// Location callbacks can happen before the anonymous sign-in started at launch completes.
    /// Wait for that one shared task so a real store entry never falls back to an API error.
    func ensureFirebaseAuthentication() async -> Bool {
        guard FirebaseApp.app() != nil else { return false }
        if let user = Auth.auth().currentUser {
            firebaseUserID = user.uid
            return true
        }
        startFirebaseAuthenticationIfNeeded()
        await firebaseAuthenticationTask?.value
        return Auth.auth().currentUser != nil
    }

    private func startFirebaseAuthenticationIfNeeded() {
        guard firebaseAuthenticationTask == nil else { return }
        firebaseAuthenticationTask = Task { [weak self] in
            guard let self else { return }
            defer { firebaseAuthenticationTask = nil }
            do {
                let result = try await Auth.auth().signInAnonymously()
                firebaseUserID = result.user.uid
                await hydrateFirebaseData(uid: result.user.uid)
            } catch {
                print("Firebase anonymous authentication unavailable: \(error.localizedDescription)")
            }
        }
    }

    func saveImportedCoupon(_ coupon: Coupon) {
        coupons.append(coupon)
        let importedCoupons = coupons.filter { !Coupon.demoCoupons.contains($0) }
        guard let encoded = try? JSONEncoder().encode(importedCoupons) else { return }
        UserDefaults.standard.set(encoded, forKey: "saved-imported-coupons")
        if let uid = firebaseUserID {
            Task { try? await FirestoreRepository.shared.save(coupon: coupon, uid: uid) }
        }
    }

    func saveImportedCoupon(draft: CouponDraft, image: UIImage) {
        let couponID = UUID().uuidString
        let imageFilename = try? CouponImageStore.shared.save(image: image, couponID: couponID)
        saveImportedCoupon(draft.makeCoupon(id: couponID, localImageFilename: imageFilename))
    }

    func markCouponUsed(_ coupon: Coupon) {
        guard coupons.contains(coupon) else { return }
        coupons.removeAll { $0.id == coupon.id }
        if !usedCoupons.contains(where: { $0.id == coupon.id }) {
            usedCoupons.insert(UsedCoupon(coupon: coupon), at: 0)
        }
        persistCouponCollections()
        if let uid = firebaseUserID {
            Task { try? await FirestoreRepository.shared.moveToUsedHistory(coupon: coupon, uid: uid) }
        }
    }

    private static func loadSavedCoupons() -> [Coupon] {
        guard let data = UserDefaults.standard.data(forKey: "saved-imported-coupons"),
              let coupons = try? JSONDecoder().decode([Coupon].self, from: data) else { return [] }
        return coupons.filter { $0.expiresAt > .now }
    }

    private static func loadSavedUsedCoupons() -> [UsedCoupon] {
        guard let data = UserDefaults.standard.data(forKey: "saved-used-coupons"),
              let coupons = try? JSONDecoder().decode([UsedCoupon].self, from: data) else { return [] }
        return coupons
    }

    private func persistCouponCollections() {
        let importedCoupons = coupons.filter { !Coupon.demoCoupons.contains($0) }
        if let encoded = try? JSONEncoder().encode(importedCoupons) {
            UserDefaults.standard.set(encoded, forKey: "saved-imported-coupons")
        }
        let userUsedCoupons = usedCoupons.filter { !UsedCoupon.sampleHistory.contains($0) }
        if let encoded = try? JSONEncoder().encode(userUsedCoupons) {
            UserDefaults.standard.set(encoded, forKey: "saved-used-coupons")
        }
    }

    func setNearbyStores(_ stores: [Store]) {
        nearbyStores = stores
        storeDirectoryState = stores.isEmpty ? .empty : .live
    }

    func setStoreDirectoryState(_ state: StoreDirectoryState) {
        storeDirectoryState = state
    }

    func updateProfile(carrier: String, membershipGrade: String, monthlyBenefitStatus: UserProfile.MonthlyBenefitStatus) {
        let updated = UserProfile(
            id: firebaseUserID ?? profile.id,
            carrier: carrier,
            membershipGrade: membershipGrade,
            monthlyBenefitStatus: monthlyBenefitStatus
        )
        profile = updated
        if let encoded = try? JSONEncoder().encode(updated) {
            UserDefaults.standard.set(encoded, forKey: "saved-user-profile")
        }
        if let uid = firebaseUserID {
            Task { try? await FirestoreRepository.shared.save(profile: updated, uid: uid) }
        }
    }

    func setCurrentStore(_ store: Store) {
        currentStore = store
    }

    private func hydrateFirebaseData(uid: String) async {
        do {
            let remote = try await FirestoreRepository.shared.loadUserData(uid: uid)
            if let profile = remote.profile {
                self.profile = profile
                if let encoded = try? JSONEncoder().encode(profile) {
                    UserDefaults.standard.set(encoded, forKey: "saved-user-profile")
                }
            }
            let mergedUsedCoupons = Self.mergedUsedCoupons(UsedCoupon.sampleHistory, Self.loadSavedUsedCoupons(), remote.usedCoupons)
            usedCoupons = mergedUsedCoupons
            let usedCouponIDs = Set(mergedUsedCoupons.map(\.id))
            let localImportedCoupons = coupons.filter { !Coupon.demoCoupons.contains($0) }

            if !remote.coupons.isEmpty {
                let localImages = Dictionary(uniqueKeysWithValues: coupons.compactMap { coupon in coupon.localImageFilename.map { (coupon.id, $0) } })
                let remoteCouponIDs = Set(remote.coupons.map(\.id))
                let remoteCoupons = remote.coupons.map { coupon in
                    Coupon(id: coupon.id, brand: coupon.brand, title: coupon.title, discountType: coupon.discountType,
                           discountValue: coupon.discountValue, minimumOrderAmount: coupon.minimumOrderAmount,
                           expiresAt: coupon.expiresAt, combinableWithCard: coupon.combinableWithCard,
                           conditions: coupon.conditions, localImageFilename: localImages[coupon.id])
                }
                let unsyncedLocalCoupons = localImportedCoupons.filter { !remoteCouponIDs.contains($0.id) && !usedCouponIDs.contains($0.id) }
                coupons = (Coupon.demoCoupons + remoteCoupons + unsyncedLocalCoupons).filter { !usedCouponIDs.contains($0.id) }
                for coupon in unsyncedLocalCoupons {
                    try? await FirestoreRepository.shared.save(coupon: coupon, uid: uid)
                }
            } else {
                try? await FirestoreRepository.shared.save(profile: profile, uid: uid)
                coupons.removeAll { usedCouponIDs.contains($0.id) }
                for coupon in coupons where !Coupon.demoCoupons.contains(coupon) {
                    try? await FirestoreRepository.shared.save(coupon: coupon, uid: uid)
                }
            }
            persistCouponCollections()
        } catch {
            // Local UserDefaults remains the offline fallback.
            print("Firestore sync unavailable: \(error.localizedDescription)")
        }
    }

    private static func loadSavedProfile() -> UserProfile {
        guard let data = UserDefaults.standard.data(forKey: "saved-user-profile"),
              let profile = try? JSONDecoder().decode(UserProfile.self, from: data) else { return .demo }
        return profile
    }

    private static func mergedUsedCoupons(_ collections: [UsedCoupon]...) -> [UsedCoupon] {
        var seenIDs = Set<String>()
        return collections
            .flatMap { $0 }
            .filter { seenIDs.insert($0.id).inserted }
            .sorted { $0.usedAt > $1.usedAt }
    }
}
