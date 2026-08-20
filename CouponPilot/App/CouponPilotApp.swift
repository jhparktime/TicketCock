import SwiftUI
import UIKit
import FirebaseAuth
import FirebaseAppCheck
import FirebaseCore

@main
struct CouponPilotApp: App {
    @StateObject private var appState = AppState()

    init() {
        // GoogleService-Info.plist가 번들에 포함된 실제 앱에서만 Firebase를 초기화합니다.
        if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            #if targetEnvironment(simulator)
            AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
            #else
            AppCheck.setAppCheckProviderFactory(AppAttestProviderFactory())
            #endif
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
    /// Debug builds retain fixtures for the bootcamp demonstration. Release/TestFlight builds
    /// begin with an empty, clearly personal coupon wallet.
    static let includesDemoFixtures: Bool = {
        #if DEBUG
        true
        #else
        false
        #endif
    }()

    private struct NotificationRecommendationContext: Codable {
        let store: Store
        let recommendation: Recommendation
        let isDemo: Bool
    }

    private static let notificationRecommendationContextKey = "notification-recommendation-context"
    private static let privacyConsentKey = "privacy-consent-v1"
    private static let pendingRestoredCouponIDsKey = "pending-restored-coupon-ids"
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

    enum CloudSyncState: Equatable {
        case localOnly, syncing, synced, needsRetry
    }

    enum AccountStatus: Equatable {
        case unavailable, guest, apple

        var title: String {
            switch self {
            case .unavailable: "로그인 준비 중"
            case .guest: "기기 임시 계정"
            case .apple: "Apple 계정으로 로그인됨"
            }
        }

        var detail: String {
            switch self {
            case .unavailable: "Firebase 설정을 확인한 뒤 로그인할 수 있어요."
            case .guest: "Apple로 로그인하면 쿠폰과 설정을 내 계정에 연결할 수 있어요."
            case .apple: "새 기기에서도 Apple 로그인을 통해 쿠폰과 설정을 불러올 수 있어요."
            }
        }
    }

    @Published var currentStore: Store?
    @Published var recommendation: Recommendation?
    @Published var isLoadingRecommendation = false
    @Published var shouldShowRecommendation = false
    @Published var recommendationOrigin: RecommendationOrigin = .live
    @Published private(set) var firebaseUserID: String?
    @Published private(set) var firebaseReady = false
    @Published private(set) var accountStatus: AccountStatus = .unavailable
    @Published private(set) var cloudSyncState: CloudSyncState = .localOnly
    @Published private(set) var privacyConsent: PrivacyConsent
    private var firebaseAuthenticationTask: Task<Void, Never>?
    private var cloudReconciliationTask: Task<Void, Never>?

    @Published private(set) var profile: UserProfile
    @Published private(set) var coupons: [Coupon]
    @Published private(set) var nearbyStores: [Store] = []
    @Published private(set) var storeDirectoryState: StoreDirectoryState = .awaitingLocation
    @Published private(set) var usedCoupons: [UsedCoupon]
    /// 사용 완료 직후 5초 동안 전역 실행 취소 배너에 노출할 원본 쿠폰입니다.
    @Published private(set) var recentlyUsedCoupon: Coupon?
    private var couponUndoExpirationTask: Task<Void, Never>?
    /// 오프라인 복원 후 원격 usedCoupons 문서가 삭제되기 전까지 유지하는 로컬 tombstone입니다.
    private var pendingRestoredCouponIDs: Set<String> = []

    init() {
        privacyConsent = Self.loadPrivacyConsent()
        pendingRestoredCouponIDs = Self.loadPendingRestoredCouponIDs()
        let savedUsedCoupons = Self.loadSavedUsedCoupons()
        let fixtureHistory = Self.includesDemoFixtures ? UsedCoupon.sampleHistory : []
        let allUsedCoupons = Self.mergedUsedCoupons(fixtureHistory, savedUsedCoupons)
        let usedIDs = Set(allUsedCoupons.map(\.id))
        let savedCoupons = Self.loadSavedCoupons().filter { !usedIDs.contains($0.id) }
        usedCoupons = allUsedCoupons
        recentlyUsedCoupon = nil
        let fixtureCoupons = Self.includesDemoFixtures ? Coupon.demoCoupons : []
        coupons = fixtureCoupons.filter { !usedIDs.contains($0.id) } + savedCoupons
        profile = Self.loadSavedProfile()

        guard FirebaseApp.app() != nil else { return }

        firebaseReady = true
        refreshAccountStatus()
        guard privacyConsent.permitsService else { return }
        cloudSyncState = .syncing
        if let user = Auth.auth().currentUser {
            firebaseUserID = user.uid
            refreshAccountStatus()
            Task { await hydrateFirebaseData(uid: user.uid) }
        } else {
            startFirebaseAuthenticationIfNeeded()
        }
    }

    /// Location callbacks can happen before the anonymous sign-in started at launch completes.
    /// Wait for that one shared task so a real store entry never falls back to an API error.
    func ensureFirebaseAuthentication() async -> Bool {
        guard privacyConsent.permitsService else { return false }
        guard FirebaseApp.app() != nil else { return false }
        if let user = Auth.auth().currentUser {
            firebaseUserID = user.uid
            refreshAccountStatus()
            return true
        }
        startFirebaseAuthenticationIfNeeded()
        await firebaseAuthenticationTask?.value
        return Auth.auth().currentUser != nil
    }

    private func startFirebaseAuthenticationIfNeeded() {
        guard privacyConsent.permitsService else { return }
        guard firebaseAuthenticationTask == nil else { return }
        firebaseAuthenticationTask = Task { [weak self] in
            guard let self else { return }
            defer { firebaseAuthenticationTask = nil }
            do {
                let result = try await Auth.auth().signInAnonymously()
                firebaseUserID = result.user.uid
                refreshAccountStatus()
                await hydrateFirebaseData(uid: result.user.uid)
            } catch {
                cloudSyncState = .needsRetry
                print("Firebase anonymous authentication unavailable: \(error.localizedDescription)")
            }
        }
    }

    func acceptPrivacyConsent(personalization: Bool, locationPersonalization: Bool) {
        let consent = PrivacyConsent(
            policyVersion: PrivacyConsent.currentPolicyVersion,
            requiredProcessingAccepted: true,
            personalizationAccepted: personalization,
            locationPersonalizationAccepted: locationPersonalization,
            acceptedAt: .now
        )
        privacyConsent = consent
        persistPrivacyConsent(consent)
        guard FirebaseApp.app() != nil else { return }
        firebaseReady = true
        refreshAccountStatus()
        cloudSyncState = .syncing
        if let user = Auth.auth().currentUser {
            firebaseUserID = user.uid
            refreshAccountStatus()
            Task { await hydrateFirebaseData(uid: user.uid) }
        } else {
            startFirebaseAuthenticationIfNeeded()
        }
    }

    func updateOptionalConsents(personalization: Bool, locationPersonalization: Bool) {
        guard privacyConsent.permitsService else { return }
        let consent = PrivacyConsent(
            policyVersion: PrivacyConsent.currentPolicyVersion,
            requiredProcessingAccepted: true,
            personalizationAccepted: personalization,
            locationPersonalizationAccepted: locationPersonalization,
            acceptedAt: privacyConsent.acceptedAt ?? .now
        )
        privacyConsent = consent
        persistPrivacyConsent(consent)
        if !personalization {
            profile = .empty
            UserDefaults.standard.removeObject(forKey: "saved-user-profile")
        }
        scheduleCloudReconciliation(delayNanoseconds: 0)
    }

    private static func loadPrivacyConsent() -> PrivacyConsent {
        guard let data = UserDefaults.standard.data(forKey: privacyConsentKey),
              let consent = try? JSONDecoder().decode(PrivacyConsent.self, from: data),
              consent.permitsService else { return .empty }
        return consent
    }

    private func persistPrivacyConsent(_ consent: PrivacyConsent) {
        guard let data = try? JSONEncoder().encode(consent) else { return }
        UserDefaults.standard.set(data, forKey: Self.privacyConsentKey)
    }

    /// 익명 Firebase 계정을 Apple 계정에 연결합니다. 이미 다른 기기에서 연결된 Apple 계정이면
    /// 해당 계정으로 로그인해 저장된 쿠폰을 불러옵니다. 원본 쿠폰 이미지는 기기 밖으로 이동하지 않습니다.
    func continueWithApple(idToken: String, rawNonce: String) async throws -> String {
        guard FirebaseApp.app() != nil else {
            throw NSError(domain: "CouponCock.Auth", code: 1, userInfo: [NSLocalizedDescriptionKey: "로그인 서비스를 준비하지 못했어요."])
        }
        let credential = OAuthProvider.appleCredential(withIDToken: idToken, rawNonce: rawNonce, fullName: nil)
        do {
            if let user = Auth.auth().currentUser, user.isAnonymous {
                let result = try await user.link(with: credential)
                firebaseUserID = result.user.uid
                refreshAccountStatus()
                await hydrateFirebaseData(uid: result.user.uid)
                return "이 기기의 쿠폰과 설정을 Apple 계정에 연결했어요."
            }
            let result = try await Auth.auth().signIn(with: credential)
            firebaseUserID = result.user.uid
            refreshAccountStatus()
            await hydrateFirebaseData(uid: result.user.uid)
            return "Apple 계정으로 로그인해 저장된 쿠폰과 설정을 불러왔어요."
        } catch {
            guard (error as NSError).code == AuthErrorCode.credentialAlreadyInUse.rawValue else { throw error }
            let result = try await Auth.auth().signIn(with: credential)
            firebaseUserID = result.user.uid
            refreshAccountStatus()
            await hydrateFirebaseData(uid: result.user.uid)
            return "기존 Apple 계정으로 로그인해 저장된 쿠폰과 설정을 불러왔어요."
        }
    }

    private func refreshAccountStatus() {
        guard FirebaseApp.app() != nil else {
            accountStatus = .unavailable
            return
        }
        guard let user = Auth.auth().currentUser else {
            accountStatus = .guest
            return
        }
        accountStatus = user.isAnonymous ? .guest : .apple
    }

    func saveImportedCoupon(_ coupon: Coupon) {
        coupons.append(coupon)
        let importedCoupons = coupons.filter { !Coupon.demoCoupons.contains($0) }
        guard let encoded = try? JSONEncoder().encode(importedCoupons) else { return }
        UserDefaults.standard.set(encoded, forKey: "saved-imported-coupons")
        scheduleCloudReconciliation()
    }

    func saveImportedCoupon(draft: CouponDraft, image: UIImage) {
        let couponID = UUID().uuidString
        let imageFilename = try? CouponImageStore.shared.save(image: image, couponID: couponID)
        saveImportedCoupon(draft.makeCoupon(id: couponID, localImageFilename: imageFilename))
    }

    func markCouponUsed(_ coupon: Coupon) {
        guard coupons.contains(coupon) else { return }
        pendingRestoredCouponIDs.remove(coupon.id)
        persistPendingRestoredCouponIDs()
        coupons.removeAll { $0.id == coupon.id }
        if !usedCoupons.contains(where: { $0.id == coupon.id }) {
            usedCoupons.insert(UsedCoupon(coupon: coupon), at: 0)
        }
        armCouponUseUndo(for: coupon)
        persistCouponCollections()
        scheduleCloudReconciliation()
    }

    /// 5초 실행 취소와 사용 기록 화면의 수동 복원이 함께 사용하는 단일 복원 경로입니다.
    /// 원본 전체가 없는 레거시 기록은 잘못된 할인 조건을 추정하지 않고 복원을 거부합니다.
    @discardableResult
    func restoreUsedCoupon(_ usedCoupon: UsedCoupon) -> Bool {
        guard let coupon = usedCoupon.originalCoupon else { return false }
        return restoreCoupon(coupon)
    }

    @discardableResult
    func undoRecentCouponUse() -> Bool {
        guard let coupon = recentlyUsedCoupon else { return false }
        return restoreCoupon(coupon)
    }

    private func restoreCoupon(_ coupon: Coupon) -> Bool {
        guard usedCoupons.contains(where: { $0.id == coupon.id }) else {
            clearCouponUseUndo()
            return false
        }
        usedCoupons.removeAll { $0.id == coupon.id }
        if !coupons.contains(where: { $0.id == coupon.id }) {
            coupons.append(coupon)
            coupons.sort { $0.expiresAt < $1.expiresAt }
        }
        pendingRestoredCouponIDs.insert(coupon.id)
        persistPendingRestoredCouponIDs()
        clearCouponUseUndo()
        persistCouponCollections()
        // FirestoreRepository.save(coupon:) atomically restores the active document and
        // removes the used-history document. A failed request remains locally retryable.
        scheduleCloudReconciliation(delayNanoseconds: 0)
        return true
    }

    private func armCouponUseUndo(for coupon: Coupon) {
        couponUndoExpirationTask?.cancel()
        recentlyUsedCoupon = coupon
        couponUndoExpirationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.recentlyUsedCoupon = nil
            self?.couponUndoExpirationTask = nil
        }
    }

    private func clearCouponUseUndo() {
        couponUndoExpirationTask?.cancel()
        couponUndoExpirationTask = nil
        recentlyUsedCoupon = nil
    }

    private static func loadSavedCoupons() -> [Coupon] {
        guard let data = UserDefaults.standard.data(forKey: "saved-imported-coupons"),
              let coupons = try? JSONDecoder().decode([Coupon].self, from: data) else { return [] }
        return coupons.filter { coupon in
            coupon.expiresAt > .now && (Self.includesDemoFixtures || !Coupon.demoCoupons.contains(coupon))
        }
    }

    private static func loadSavedUsedCoupons() -> [UsedCoupon] {
        guard let data = UserDefaults.standard.data(forKey: "saved-used-coupons"),
              let coupons = try? JSONDecoder().decode([UsedCoupon].self, from: data) else { return [] }
        return Self.includesDemoFixtures ? coupons : coupons.filter { !UsedCoupon.sampleHistory.contains($0) }
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

    func updateProfile(carrier: String, membershipGrade: String, monthlyBenefitStatus: UserProfile.MonthlyBenefitStatus, cards: [PaymentCard]) {
        guard privacyConsent.personalizationAccepted else { return }
        let updated = UserProfile(
            id: firebaseUserID ?? profile.id,
            carrier: carrier,
            membershipGrade: membershipGrade,
            monthlyBenefitStatus: monthlyBenefitStatus,
            cards: cards
        )
        profile = updated
        if let encoded = try? JSONEncoder().encode(updated) {
            UserDefaults.standard.set(encoded, forKey: "saved-user-profile")
        }
        scheduleCloudReconciliation()
    }

    func retryCloudSync() {
        if firebaseUserID == nil {
            startFirebaseAuthenticationIfNeeded()
        } else {
            scheduleCloudReconciliation(delayNanoseconds: 0)
        }
    }

    /// Local data is the immediate source of truth on one anonymously authenticated device.
    /// Reconciliation is idempotent, so a partial Firestore failure can safely retry later.
    private func scheduleCloudReconciliation(delayNanoseconds: UInt64 = 350_000_000) {
        guard privacyConsent.permitsService else {
            cloudSyncState = .localOnly
            return
        }
        guard let uid = firebaseUserID else {
            cloudSyncState = firebaseReady ? .needsRetry : .localOnly
            return
        }
        cloudReconciliationTask?.cancel()
        cloudReconciliationTask = Task { [weak self] in
            guard let self else { return }
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            cloudSyncState = .syncing
            let activeCoupons = coupons.filter { !Coupon.demoCoupons.contains($0) }
            let history = usedCoupons.filter { !UsedCoupon.sampleHistory.contains($0) }
            let pendingRestoreIDs = pendingRestoredCouponIDs
            do {
                try await FirestoreRepository.shared.save(consent: privacyConsent, uid: uid)
                if privacyConsent.personalizationAccepted {
                    try await FirestoreRepository.shared.save(profile: profile, uid: uid)
                } else {
                    try await FirestoreRepository.shared.clearPersonalization(uid: uid)
                }
                for coupon in activeCoupons {
                    try await FirestoreRepository.shared.save(coupon: coupon, uid: uid)
                }
                for usedCoupon in history {
                    try await FirestoreRepository.shared.save(usedCoupon: usedCoupon, uid: uid)
                }
                guard !Task.isCancelled else { return }
                pendingRestoredCouponIDs.subtract(pendingRestoreIDs)
                persistPendingRestoredCouponIDs()
                cloudSyncState = .synced
            } catch {
                guard !Task.isCancelled else { return }
                cloudSyncState = .needsRetry
                print("Firestore reconciliation unavailable: \(error.localizedDescription)")
            }
        }
    }

    /// A user-controlled erase flow for beta and production. Cloud documents are deleted before
    /// the anonymous auth account so Firestore rules can still authorize the erase operation.
    func deleteAllPersonalData() async -> Bool {
        let uid = firebaseUserID
        do {
            cloudReconciliationTask?.cancel()
            await cloudReconciliationTask?.value
            cloudReconciliationTask = nil
            if let uid { try await FirestoreRepository.shared.deleteAllUserData(uid: uid) }
            if FirebaseApp.app() != nil, let user = Auth.auth().currentUser, uid == nil || user.uid == uid {
                try await user.delete()
                firebaseUserID = nil
                refreshAccountStatus()
            }
            try CouponImageStore.shared.deleteAll()
            UserDefaults.standard.removeObject(forKey: "saved-imported-coupons")
            UserDefaults.standard.removeObject(forKey: "saved-used-coupons")
            UserDefaults.standard.removeObject(forKey: "saved-user-profile")
            UserDefaults.standard.removeObject(forKey: Self.privacyConsentKey)
            UserDefaults.standard.removeObject(forKey: Self.notificationRecommendationContextKey)
            UserDefaults.standard.removeObject(forKey: Self.pendingRestoredCouponIDsKey)
            let fixtureCoupons = Self.includesDemoFixtures ? Coupon.demoCoupons : []
            let fixtureHistory = Self.includesDemoFixtures ? UsedCoupon.sampleHistory : []
            coupons = fixtureCoupons
            usedCoupons = fixtureHistory
            pendingRestoredCouponIDs = []
            clearCouponUseUndo()
            profile = Self.includesDemoFixtures ? .demo : .empty
            privacyConsent = .empty
            currentStore = nil
            recommendation = nil
            shouldShowRecommendation = false
            cloudSyncState = .localOnly
            return true
        } catch {
            print("Personal data deletion failed: \(error.localizedDescription)")
            return false
        }
    }

    func setCurrentStore(_ store: Store) {
        currentStore = store
    }

    func cacheRecommendation(_ recommendation: Recommendation, store: Store, origin: RecommendationOrigin) {
        self.recommendation = recommendation
        recommendationOrigin = origin
        if let data = try? JSONEncoder().encode(
            NotificationRecommendationContext(store: store, recommendation: recommendation, isDemo: origin == .demo)
        ) {
            UserDefaults.standard.set(data, forKey: Self.notificationRecommendationContextKey)
        }
    }

    @discardableResult
    func restoreCachedRecommendation(for storeID: String) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.notificationRecommendationContextKey),
              let context = try? JSONDecoder().decode(NotificationRecommendationContext.self, from: data),
              context.store.id == storeID else { return false }
        currentStore = context.store
        recommendation = context.recommendation
        recommendationOrigin = context.isDemo ? .demo : .live
        shouldShowRecommendation = true
        return true
    }

    private func hydrateFirebaseData(uid: String) async {
        do {
            let remote = try await FirestoreRepository.shared.loadUserData(uid: uid)
            if privacyConsent.personalizationAccepted, let profile = remote.profile {
                self.profile = profile
                if let encoded = try? JSONEncoder().encode(profile) {
                    UserDefaults.standard.set(encoded, forKey: "saved-user-profile")
                }
            }
            let fixtureHistory = Self.includesDemoFixtures ? UsedCoupon.sampleHistory : []
            // An offline restore is locally authoritative until reconciliation atomically writes
            // the active document and removes its used-history counterpart in Firestore.
            let remoteHistory = remote.usedCoupons.filter { !pendingRestoredCouponIDs.contains($0.id) }
            let mergedUsedCoupons = Self.mergedUsedCoupons(fixtureHistory, Self.loadSavedUsedCoupons(), remoteHistory)
            usedCoupons = mergedUsedCoupons
            let usedCouponIDs = Set(mergedUsedCoupons.map(\.id))
            let localImportedCoupons = coupons.filter { !Coupon.demoCoupons.contains($0) }

            if !remote.coupons.isEmpty {
                let localImages = Dictionary(uniqueKeysWithValues: coupons.compactMap { coupon in coupon.localImageFilename.map { (coupon.id, $0) } })
                let remoteCouponIDs = Set(remote.coupons.map(\.id))
                let remoteCoupons = remote.coupons.compactMap { coupon -> Coupon? in
                    guard Self.includesDemoFixtures || !Coupon.demoCoupons.contains(coupon) else { return nil }
                    return Coupon(id: coupon.id, brand: coupon.brand, title: coupon.title, discountType: coupon.discountType,
                                  discountValue: coupon.discountValue, minimumOrderAmount: coupon.minimumOrderAmount,
                                  maximumDiscount: coupon.maximumDiscount,
                                  expiresAt: coupon.expiresAt, combinableWithCard: coupon.combinableWithCard,
                                  referencePrice: coupon.referencePrice,
                                  conditions: coupon.conditions, localImageFilename: localImages[coupon.id])
                }
                let unsyncedLocalCoupons = localImportedCoupons.filter { !remoteCouponIDs.contains($0.id) && !usedCouponIDs.contains($0.id) }
                let fixtureCoupons = Self.includesDemoFixtures ? Coupon.demoCoupons : []
                coupons = (fixtureCoupons + remoteCoupons + unsyncedLocalCoupons).filter { !usedCouponIDs.contains($0.id) }
                for coupon in unsyncedLocalCoupons {
                    try? await FirestoreRepository.shared.save(coupon: coupon, uid: uid)
                }
            } else {
                if privacyConsent.personalizationAccepted {
                    try? await FirestoreRepository.shared.save(profile: profile, uid: uid)
                }
                coupons.removeAll { usedCouponIDs.contains($0.id) }
                for coupon in coupons where !Coupon.demoCoupons.contains(coupon) {
                    try? await FirestoreRepository.shared.save(coupon: coupon, uid: uid)
                }
            }
            persistCouponCollections()
            scheduleCloudReconciliation(delayNanoseconds: 0)
        } catch {
            // Local UserDefaults remains the offline fallback.
            cloudSyncState = .needsRetry
            print("Firestore sync unavailable: \(error.localizedDescription)")
        }
    }

    private static func loadSavedProfile() -> UserProfile {
        guard let data = UserDefaults.standard.data(forKey: "saved-user-profile"),
              let profile = try? JSONDecoder().decode(UserProfile.self, from: data) else {
            return Self.includesDemoFixtures ? .demo : .empty
        }
        if !Self.includesDemoFixtures && profile.id == UserProfile.demo.id { return .empty }
        return profile
    }

    private static func mergedUsedCoupons(_ collections: [UsedCoupon]...) -> [UsedCoupon] {
        var seenIDs = Set<String>()
        return collections
            .flatMap { $0 }
            .filter { seenIDs.insert($0.id).inserted }
            .sorted { $0.usedAt > $1.usedAt }
    }

    private static func loadPendingRestoredCouponIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: pendingRestoredCouponIDsKey) ?? [])
    }

    private func persistPendingRestoredCouponIDs() {
        UserDefaults.standard.set(Array(pendingRestoredCouponIDs).sorted(), forKey: Self.pendingRestoredCouponIDsKey)
    }
}
