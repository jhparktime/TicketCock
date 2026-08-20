import SwiftUI
import UIKit
import CoreLocation
import PhotosUI
import AuthenticationServices

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var locationMonitor = LocationMonitor()
    @StateObject private var notificationManager = NotificationManager()
    @StateObject private var nearbyFranchiseFinder = NearbyFranchiseFinder()
    @State private var expectedPrice = "15000"
    @State private var selectedTab = "home"
    @State private var showCouponImporter = false
    @State private var selectedCarrier = UserProfile.empty.carrier
    @State private var selectedMembershipGrade = UserProfile.empty.membershipGrade
    @State private var selectedMonthlyBenefitStatus = UserProfile.empty.monthlyBenefitStatus
    @State private var selectedCardID = ""
    @State private var cardPreviousSpendQualified = false
    @State private var cardMonthlyBenefitRemaining = "0"
    @State private var showRecommendationError = false
    @State private var recommendationErrorTitle = "추천을 불러오지 못했어요"
    @State private var recommendationErrorMessage = "공공데이터 또는 인증된 API에 연결하지 못했습니다. 데모 결과는 실제 API 응답이 아니라는 표시와 함께 제공합니다."
    @State private var failedRecommendationStore: Store?
    @State private var lastStoreDirectoryCoordinate: CLLocationCoordinate2D?
    @State private var lastStoreDirectoryRefreshAt = Date.distantPast
    @State private var isRefreshingStoreDirectory = false
    @State private var selectedRecommendationCoupon: Coupon?
    @State private var showDeletePersonalDataConfirmation = false
    @State private var personalDataDeletionMessage: String?
    @State private var showCardImporter = false
    @State private var appleSignInNonce = ""
    @State private var accountLoginMessage: String?

    var body: some View {
        if appState.privacyConsent.permitsService {
            mainContent
        } else {
            PrivacyConsentView { personalization, locationPersonalization in
                appState.acceptPrivacyConsent(
                    personalization: personalization,
                    locationPersonalization: locationPersonalization
                )
            }
        }
    }

    private var mainContent: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                homeScreen
            }
            .tag("home")
            .tabItem { Label("홈", systemImage: "house.fill") }

            NavigationStack {
                couponLibrary
            }
            .tag("coupons")
            .tabItem { Label("쿠폰", systemImage: "ticket.fill") }

            NavigationStack {
                historyScreen
            }
            .tag("history")
            .tabItem { Label("기록", systemImage: "clock.fill") }

            NavigationStack {
                profileScreen
            }
            .tag("profile")
            .tabItem { Label("내 정보", systemImage: "person.fill") }
        }
        .tint(.cyan)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .overlay(alignment: .bottom) {
            if let coupon = appState.recentlyUsedCoupon {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.mint)
                    Text("\(coupon.title) 사용 완료")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button("실행 취소") {
                        appState.undoRecentCouponUse()
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.cyan)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 54)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay { Capsule().stroke(.white.opacity(0.55), lineWidth: 1) }
                .shadow(color: .black.opacity(0.15), radius: 18, y: 8)
                .padding(.horizontal, 16)
                .padding(.bottom, 66)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityHint("실행 취소를 누르면 사용 가능한 쿠폰으로 복원합니다")
            }
        }
        .animation(.snappy, value: appState.recentlyUsedCoupon?.id)
        .onAppear {
            locationMonitor.onStoreEntry = { store in
                Task { await handleStoreEntry(store) }
            }
            locationMonitor.onLocationUpdate = { coordinate in
                Task { await refreshNearbyStores(at: coordinate) }
            }
            if appState.privacyConsent.locationPersonalizationAccepted {
                locationMonitor.resumeMonitoringIfEnabled()
            } else {
                locationMonitor.stopMonitoring()
            }
            handleNotificationTapIfNeeded()
        }
        .onChange(of: appState.privacyConsent.locationPersonalizationAccepted) { _, isAccepted in
            if isAccepted {
                locationMonitor.requestPermissionsAndMonitor(appState.nearbyStores)
                locationMonitor.requestCurrentLocation()
            } else {
                locationMonitor.stopMonitoring()
            }
        }
        .onChange(of: notificationManager.pendingStoreID) { _, _ in
            handleNotificationTapIfNeeded()
        }
        .sheet(isPresented: $appState.shouldShowRecommendation) {
            if let recommendation = appState.recommendation {
                RecommendationSheet(
                    recommendation: recommendation,
                    isDemo: appState.recommendationOrigin == .demo,
                    onOpenCoupon: appState.coupons.contains(where: { $0.id == recommendation.recommendedOption.id }) ? {
                        appState.shouldShowRecommendation = false
                        selectedRecommendationCoupon = appState.coupons.first { $0.id == recommendation.recommendedOption.id }
                    } : nil
                )
                    .presentationDetents([.large])
                    .presentationCornerRadius(34)
                    .presentationBackground(.ultraThinMaterial)
            }
        }
        .sheet(isPresented: $showCouponImporter) {
            CouponImportSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showCardImporter) {
            CardImportSheet { card in
                selectedCardID = card.productId
                cardPreviousSpendQualified = false
                cardMonthlyBenefitRemaining = "0"
            }
        }
        .sheet(item: $selectedRecommendationCoupon) { coupon in
            NavigationStack {
                CouponDetailView(coupon: coupon)
            }
        }
        .alert(recommendationErrorTitle, isPresented: $showRecommendationError) {
            Button("다시 시도") {
                if let store = failedRecommendationStore {
                    Task { await requestRecommendation(for: store) }
                }
            }
            Button("데모 추천 보기") {
                if let store = failedRecommendationStore {
                    presentDemoRecommendation(for: store)
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text(recommendationErrorMessage)
        }
    }

    private var homeScreen: some View {
        GeometryReader { proxy in
            ZStack {
                LiquidBackground()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 22) {
                        topBar
                        locationPill
                        nearbyStoreHero
                        if !expiringCoupons.isEmpty { expiringCouponSection }
                        quickCouponSection
                        priceCard
                        usedCouponSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 118)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(LiquidBackground().ignoresSafeArea())
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(syncStatusTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(appState.cloudSyncState == .needsRetry ? Color.orange : AppPalette.ink.opacity(0.62))
                Text("오늘의 혜택")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(AppPalette.ink)
            }
            Spacer()
            Button {
                if appState.cloudSyncState == .needsRetry {
                    appState.retryCloudSync()
                }
            } label: {
                ZStack {
                    Circle().fill(.white.opacity(0.15))
                    if appState.cloudSyncState == .syncing {
                        ProgressView().tint(AppPalette.ink)
                    } else {
                        Image(systemName: syncStatusIcon)
                            .font(.title3)
                            .foregroundStyle(appState.cloudSyncState == .needsRetry ? Color.orange : AppPalette.ink)
                    }
                }
                .frame(width: 48, height: 48)
                .overlay { Circle().stroke(AppPalette.ink.opacity(0.12), lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(syncStatusTitle)
            .accessibilityHint(appState.cloudSyncState == .needsRetry ? "탭하여 클라우드 동기화를 다시 시도합니다" : "쿠폰 동기화 상태입니다")
        }
    }

    private var syncStatusTitle: String {
        switch appState.cloudSyncState {
        case .localOnly: "이 기기에 안전하게 저장 중"
        case .syncing: "쿠폰을 안전하게 동기화 중"
        case .synced: "쿠폰 동기화 완료"
        case .needsRetry: "동기화 대기 · 탭하여 재시도"
        }
    }

    private var syncStatusIcon: String {
        switch appState.cloudSyncState {
        case .localOnly: "iphone"
        case .syncing: "arrow.triangle.2.circlepath"
        case .synced: "checkmark.icloud.fill"
        case .needsRetry: "icloud.slash.fill"
        }
    }

    private var locationPill: some View {
        HStack(spacing: 10) {
            Image(systemName: locationMonitor.monitoringState == .active ? "location.fill" : "location.circle")
                .foregroundStyle(locationMonitor.monitoringState == .active ? .mint : .cyan)
                .font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                Text("매장 진입 알림")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                Text(locationStatusMessage)
                    .font(.caption)
                    .foregroundStyle(AppPalette.ink.opacity(0.58))
            }
            Spacer()
            if locationMonitor.monitoringState == .needsAlwaysAuthorization {
                Button("백그라운드 설정") {
                    Task { await notificationManager.requestAuthorization() }
                    locationMonitor.requestBackgroundAuthorization()
                }
                .font(.caption.weight(.bold))
                .buttonStyle(.bordered)
            } else {
                Toggle("매장 진입 알림", isOn: locationMonitoringBinding)
                    .labelsHidden()
                    .tint(.mint)
                    .accessibilityHint("켜면 수원 매장 진입을 감지해 쿠폰을 추천합니다")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white.opacity(0.88), in: Capsule())
        .overlay { Capsule().stroke(AppPalette.ink.opacity(0.10), lineWidth: 1) }
        .shadow(color: AppPalette.ink.opacity(0.05), radius: 12, y: 5)
    }

    private var locationMonitoringBinding: Binding<Bool> {
        Binding(
            get: {
                locationMonitor.monitoringState == .active || locationMonitor.monitoringState == .requestingPermission
            },
            set: { enabled in
                if enabled {
                    guard appState.privacyConsent.locationPersonalizationAccepted else {
                        selectedTab = "profile"
                        return
                    }
                    locationMonitor.requestPermissionsAndMonitor(appState.nearbyStores)
                } else {
                    locationMonitor.stopMonitoring()
                }
            }
        )
    }

    private var locationStatusMessage: String {
        switch locationMonitor.monitoringState {
        case .denied: "위치 권한이 필요해요"
        case .needsAlwaysAuthorization: "백그라운드 알림은 ‘항상 허용’이 필요해요"
        case .active where locationMonitor.isAtRegionLimit:
            "가까운 \(locationMonitor.availableStoreCount)곳 중 \(locationMonitor.monitoredStoreCount)곳 감지 중"
        default: appState.storeDirectoryState.message
        }
    }

    private var nearbyStoreHero: some View {
        return VStack(alignment: .leading, spacing: 18) {
            if let store = appState.currentStore {
                let matchingCoupons = eligibleCoupons(for: store)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 6) {
                            Circle().fill(.mint).frame(width: 8, height: 8)
                            Text("매장 진입 감지됨")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.mint)
                        }
                        Text(store.name)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .lineSpacing(-2)
                            .lineLimit(2)
                        Text(matchingCoupons.isEmpty ? "이 매장에 맞는 등록 쿠폰이 없어요" : "사용 가능한 쿠폰 \(matchingCoupons.count)장 · \(appState.profile.carrier) 멤버십 비교")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    Spacer()
                    Image(systemName: "cup.and.saucer.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .background(.white.opacity(0.16), in: Circle())
                        .overlay { Circle().stroke(.white.opacity(0.28), lineWidth: 1) }
                }

                HStack(spacing: 14) {
                    heroMetric(value: appState.recommendation?.storeName == store.name ? "\(appState.recommendation!.recommendedOption.savings.formatted())원" : "\(matchingCoupons.count)장", label: appState.recommendation?.storeName == store.name ? "계산된 절약" : "매칭 쿠폰")
                    Divider().overlay(.white.opacity(0.22))
                    heroMetric(value: appState.recommendation?.storeName == store.name ? "\(appState.recommendation!.recommendedOption.finalPrice.formatted())원" : "\(store.radiusMeters.formatted(.number.precision(.fractionLength(0))))m", label: appState.recommendation?.storeName == store.name ? "예상 결제" : "알림 반경")
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                Button {
                    Task { await requestRecommendation(for: store) }
                } label: {
                    HStack(spacing: 9) {
                        if appState.isLoadingRecommendation {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(appState.isLoadingRecommendation ? "혜택 계산 중" : matchingCoupons.isEmpty ? "매칭 쿠폰이 없어요" : "AI 조합 추천받기")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                .buttonStyle(PrimaryGlassButtonStyle())
                .disabled(appState.isLoadingRecommendation || matchingCoupons.isEmpty)

                Label("생성형 AI가 쿠폰 문구와 추천 이유를 설명해요. 금액·순위는 규칙 기반 Calculator가 확정합니다.", systemImage: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("인공지능 사용 안내. 생성형 인공지능은 쿠폰 문구와 추천 이유를 설명하며, 금액과 순위는 규칙 기반 계산기가 확정합니다.")
            } else {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 6) {
                            Circle().fill(.yellow).frame(width: 8, height: 8)
                            Text("현재 위치 확인 중")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.yellow)
                        }
                        Text("매장에 들어가면\n혜택을 알려드릴게요")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .lineSpacing(-2)
                        Text(appState.storeDirectoryState.message)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    Spacer()
                    Image(systemName: "location.viewfinder")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .background(.white.opacity(0.16), in: Circle())
                        .overlay { Circle().stroke(.white.opacity(0.28), lineWidth: 1) }
                }

            Button {
                if appState.privacyConsent.locationPersonalizationAccepted {
                    locationMonitor.requestPermissionsAndMonitor(appState.nearbyStores)
                    locationMonitor.requestCurrentLocation()
                } else {
                    appState.updateOptionalConsents(
                        personalization: appState.privacyConsent.personalizationAccepted,
                        locationPersonalization: true
                    )
                }
            } label: {
                    Label(
                        appState.privacyConsent.locationPersonalizationAccepted
                            ? (appState.storeDirectoryState == .unavailable ? "매장 목록 다시 불러오기" : "현재 위치 확인하기")
                            : "위치 개인화 동의하고 시작",
                        systemImage: "location.fill"
                    )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(PrimaryGlassButtonStyle())
            }

            if locationMonitor.monitoringState == .denied {
                Button("설정에서 위치 권한 열기") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }

            if AppState.includesDemoFixtures {
                Button {
                    Task { await handleDemoStoreEntry() }
                } label: {
                    Label("데모: 투썸플레이스 매장 진입 테스트", systemImage: "location.fill.viewfinder")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.75))
                .accessibilityHint("GPS 이동 없이 매장 진입 알림과 추천을 테스트합니다")
            }
        }
        .padding(21)
        .background(
            LinearGradient(colors: [Color.cyan.opacity(0.34), Color.blue.opacity(0.23), Color.purple.opacity(0.22)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 32, style: .continuous)
        )
        .overlay { RoundedRectangle(cornerRadius: 32, style: .continuous).stroke(.white.opacity(0.34), lineWidth: 1) }
        .shadow(color: .black.opacity(0.25), radius: 22, y: 14)
    }

    private func heroMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.headline.weight(.bold))
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quickCouponSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("바로 쓸 쿠폰")
                    .font(.title3.weight(.bold))
                Spacer()
                Button {
                    showCouponImporter = true
                } label: {
                    Label("쿠폰 추가", systemImage: "plus")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.cyan)
                }
                .frame(minWidth: 44, minHeight: 44)
            }

            if appState.coupons.isEmpty {
                Button {
                    showCouponImporter = true
                } label: {
                    HStack(spacing: 13) {
                        Image(systemName: "ticket.badge.plus")
                            .font(.title2)
                            .foregroundStyle(.cyan)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("첫 쿠폰을 등록해 보세요")
                                .font(.subheadline.weight(.bold))
                            Text("사진을 고르면 기기 내 OCR로 쿠폰 정보를 읽어요")
                                .font(.caption)
                                .foregroundStyle(AppPalette.ink.opacity(0.55))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(AppPalette.ink.opacity(0.42))
                    }
                    .padding(17)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(appState.coupons) { coupon in
                            NavigationLink {
                                CouponDetailView(coupon: coupon)
                            } label: {
                                couponCard(coupon)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }

    private var expiringCoupons: [Coupon] {
        appState.coupons.filter { (0...7).contains($0.daysUntilExpiry) }.sorted { $0.expiresAt < $1.expiresAt }
    }

    private var expiringCouponSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("곧 만료되는 쿠폰", systemImage: "clock.badge.exclamationmark.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.orange)
                Spacer()
                Text("7일 이내")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
            }
            ForEach(expiringCoupons) { coupon in
                HStack(spacing: 12) {
                    Image(systemName: "ticket.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(coupon.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(coupon.daysUntilExpiry == 0 ? "오늘 만료" : "\(coupon.daysUntilExpiry)일 후 만료")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(coupon.discountType == .percentage ? "\(coupon.discountValue)%" : "−\(coupon.discountValue.formatted())원")
                        .font(.caption.weight(.bold)).foregroundStyle(.orange)
                }
                .padding(14)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private func couponCard(_ coupon: Coupon) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "ticket.fill")
                    .foregroundStyle(.yellow)
                    .font(.title2)
                Spacer()
                Text("사용 가능")
                    .font(.caption2.bold())
                    .foregroundStyle(.mint)
            }
            Text(coupon.title)
                .font(.headline)
                .lineLimit(2)
                .frame(height: 42, alignment: .topLeading)
            Text(coupon.discountType == .percentage ? "최대 \(coupon.discountValue)% 할인" : "\(coupon.discountValue.formatted())원 할인")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppPalette.ink)
            Text(coupon.minimumOrderAmount == 0 ? "최소 주문금액 없음" : "\(coupon.minimumOrderAmount.formatted())원 이상")
                .font(.caption)
                .foregroundStyle(AppPalette.ink.opacity(0.55))
        }
        .padding(17)
        .frame(width: 208, height: 190, alignment: .leading)
        .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 25, style: .continuous).stroke(AppPalette.ink.opacity(0.10), lineWidth: 1) }
        .shadow(color: AppPalette.ink.opacity(0.06), radius: 16, y: 8)
    }

    private var priceCard: some View {
        GlassCard {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "wonsign.circle.fill")
                    .font(.title)
                    .foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("장바구니 결제금액")
                        .font(.headline)
                    Text("단품 쿠폰은 상품 기준가로 별도 계산해요")
                        .font(.caption)
                        .foregroundStyle(AppPalette.ink.opacity(0.56))
                }
                Spacer()
                HStack(spacing: 3) {
                    TextField("15000", text: $expectedPrice)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .font(.headline.weight(.bold))
                        .frame(width: 78)
                    Text("원").font(.caption).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }

    private var usedCouponSection: some View {
        Button {
            selectedTab = "history"
        } label: {
        HStack(spacing: 13) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(AppPalette.ink.opacity(0.45))
            VStack(alignment: .leading, spacing: 3) {
                Text("사용 완료 쿠폰 \(appState.usedCoupons.count)장")
                    .font(.subheadline.weight(.semibold))
                Text("이미 사용한 쿠폰은 추천에서 안전하게 제외돼요")
                    .font(.caption)
                    .foregroundStyle(AppPalette.ink.opacity(0.52))
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppPalette.ink.opacity(0.42))
        }
        .padding(17)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("사용 완료 쿠폰 기록을 엽니다")
    }

    private var couponLibrary: some View {
        List {
            Section("사용 가능한 쿠폰") {
                ForEach(appState.coupons) { coupon in
                    NavigationLink {
                        CouponDetailView(coupon: coupon)
                    } label: {
                        HStack(spacing: 13) {
                            Image(systemName: "ticket.fill")
                                .foregroundStyle(.yellow)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(coupon.title).font(.headline)
                                Text("\(coupon.brand) · \(coupon.expiresAt.formatted(date: .abbreviated, time: .omitted))까지")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(coupon.discountType == .percentage ? "\(coupon.discountValue)%" : "−\(coupon.discountValue.formatted())원")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.mint)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("내 쿠폰")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCouponImporter = true } label: {
                    Label("쿠폰 추가", systemImage: "plus")
                }
            }
        }
    }

    private var historyScreen: some View {
        List {
            Section("사용 완료") {
                ForEach(appState.usedCoupons) { coupon in
                    NavigationLink {
                        UsedCouponDetailView(coupon: coupon)
                    } label: {
                        HStack(spacing: 13) {
                            if let image = CouponImageStore.shared.image(named: coupon.localImageFilename) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 52, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            } else if let resourceName = coupon.imageResourceName, let image = UIImage(named: resourceName) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 52, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(coupon.productName).font(.headline).lineLimit(1)
                                Text("\(coupon.brand) · \(coupon.usedAt.formatted(date: .abbreviated, time: .omitted)) 사용")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("사용 기록")
    }

    private var profileScreen: some View {
        Form {
            Section("계정") {
                Label(appState.accountStatus.title, systemImage: appState.accountStatus == .apple ? "checkmark.icloud.fill" : "person.crop.circle.badge.clock")
                    .foregroundStyle(appState.accountStatus == .apple ? .mint : .primary)
                Text(appState.accountStatus.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if appState.accountStatus == .guest {
                    SignInWithAppleButton(.continue) { request in
                        let nonce = AppleSignInNonce.make()
                        appleSignInNonce = nonce
                        request.requestedScopes = [.email]
                        request.nonce = AppleSignInNonce.sha256(nonce)
                    } onCompletion: { result in
                        handleAppleSignIn(result)
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 48)

                    Text("로그인하면 이 기기의 쿠폰·프로필을 Apple 계정에 연결합니다. 카드번호·결제내역·위치 이력은 계정에 저장하지 않습니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("초개인화와 위치 동의") {
                Toggle("쿠폰·멤버십 초개인화", isOn: Binding(
                    get: { appState.privacyConsent.personalizationAccepted },
                    set: { accepted in
                        appState.updateOptionalConsents(
                            personalization: accepted,
                            locationPersonalization: appState.privacyConsent.locationPersonalizationAccepted
                        )
                    }
                ))
                Toggle("매장 진입 위치 개인화", isOn: Binding(
                    get: { appState.privacyConsent.locationPersonalizationAccepted },
                    set: { accepted in
                        appState.updateOptionalConsents(
                            personalization: appState.privacyConsent.personalizationAccepted,
                            locationPersonalization: accepted
                        )
                        if !accepted { locationMonitor.stopMonitoring() }
                    }
                ))
                Text("선택 동의이며 언제든 철회할 수 있어요. 위치 이력은 서버에 저장하지 않고, 카드번호·CVC·거래내역은 수집하지 않습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("통신사 멤버십") {
                Picker("통신사", selection: $selectedCarrier) {
                    ForEach(["SKT", "KT", "LG U+", "없음"], id: \.self) { Text($0).tag($0) }
                }
                Picker("멤버십 등급", selection: $selectedMembershipGrade) {
                    ForEach(["VVIP", "VIP", "GOLD", "SILVER", "일반", "확인 필요"], id: \.self) { Text($0).tag($0) }
                }
                Picker("이번 달 멤버십", selection: $selectedMonthlyBenefitStatus) {
                    ForEach(UserProfile.MonthlyBenefitStatus.allCases) { status in
                        Text(status.title).tag(status)
                    }
                }
            }
            .disabled(!appState.privacyConsent.personalizationAccepted)
            Section("보유 카드 혜택 (선택)") {
                Button {
                    showCardImporter = true
                } label: {
                    Label("카드 사진으로 상품 찾기", systemImage: "viewfinder")
                }
                Picker("카드 상품", selection: $selectedCardID) {
                    Text("선택 안 함").tag("")
                    ForEach(PaymentCard.catalog) { card in
                        Text(card.productName).tag(card.productId)
                    }
                }
                if let card = selectedCatalogCard {
                    Toggle("전월 실적 충족", isOn: $cardPreviousSpendQualified)
                    TextField("이번 달 남은 할인 한도", text: $cardMonthlyBenefitRemaining)
                        .keyboardType(.numberPad)
                    Label("카드번호·유효기간·CVC·결제내역은 저장하지 않아요", systemImage: "lock.shield.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if card.productId == "shinhancard-mr-life" {
                        Text("오후 9시~오전 9시 식음료 10% · 1회 최대 1,000원. 쿠폰 중복은 제안하지 않아요.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("현재는 공식 문서와 조건을 보여줘요. 결제수단·포인트 조건이 확정된 경우에만 가격 계산에 반영됩니다.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!appState.privacyConsent.personalizationAccepted)
            Section {
                Button("내 정보 저장") {
                    let cards = selectedCatalogCard.map { card in
                        [PaymentCard(
                            issuer: card.issuer,
                            productId: card.productId,
                            productName: card.productName,
                            previousMonthSpendQualified: cardPreviousSpendQualified,
                            monthlyBenefitRemainingAmount: max(0, Int(cardMonthlyBenefitRemaining) ?? 0)
                        )]
                    } ?? []
                    appState.updateProfile(
                        carrier: selectedCarrier,
                        membershipGrade: selectedMembershipGrade,
                        monthlyBenefitStatus: selectedMonthlyBenefitStatus,
                        cards: cards
                    )
                }
                .fontWeight(.semibold)
                .disabled(!appState.privacyConsent.personalizationAccepted)
            }
            Section("개인정보") {
                Text("쿠폰 이미지와 쿠폰·프로필·사용 기록, 로그인 계정을 삭제할 수 있어요. 결제정보는 수집하지 않고, OCR 텍스트는 AI 구조화 요청에만 전송합니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("계정 및 모든 데이터 삭제", role: .destructive) {
                    showDeletePersonalDataConfirmation = true
                }
            }
        }
        .navigationTitle("내 정보")
        .onAppear {
            selectedCarrier = appState.profile.carrier
            selectedMembershipGrade = appState.profile.membershipGrade
            selectedMonthlyBenefitStatus = appState.profile.monthlyBenefitStatus
            if let card = appState.profile.cards.first {
                selectedCardID = card.productId
                cardPreviousSpendQualified = card.previousMonthSpendQualified
                cardMonthlyBenefitRemaining = String(card.monthlyBenefitRemainingAmount)
            }
        }
        .confirmationDialog("계정과 모든 데이터를 삭제할까요?", isPresented: $showDeletePersonalDataConfirmation, titleVisibility: .visible) {
            Button("모두 삭제", role: .destructive) {
                Task {
                    let completed = await appState.deleteAllPersonalData()
                    personalDataDeletionMessage = completed ? "계정과 이 기기·클라우드의 쿠폰·프로필·사용 기록을 삭제했어요." : "일부 데이터를 삭제하지 못했어요. Apple 로그인 계정은 최근 로그인 확인이 필요할 수 있어요."
                }
            }
        } message: {
            Text("로그인 계정, 이 기기의 쿠폰 이미지, 클라우드에 동기화된 쿠폰·프로필·사용 기록이 삭제됩니다. 이 작업은 되돌릴 수 없습니다.")
        }
        .alert("데이터 삭제", isPresented: Binding(get: { personalDataDeletionMessage != nil }, set: { if !$0 { personalDataDeletionMessage = nil } })) {
            Button("확인", role: .cancel) { personalDataDeletionMessage = nil }
        } message: {
            Text(personalDataDeletionMessage ?? "")
        }
        .alert("로그인", isPresented: Binding(get: { accountLoginMessage != nil }, set: { if !$0 { accountLoginMessage = nil } })) {
            Button("확인", role: .cancel) { accountLoginMessage = nil }
        } message: {
            Text(accountLoginMessage ?? "")
        }
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        guard case let .success(authorization) = result,
              let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8),
              !appleSignInNonce.isEmpty else {
            if case let .failure(error) = result { accountLoginMessage = error.localizedDescription }
            else { accountLoginMessage = "Apple 로그인 정보를 확인하지 못했어요. 다시 시도해 주세요." }
            return
        }
        Task {
            do {
                accountLoginMessage = try await appState.continueWithApple(idToken: idToken, rawNonce: appleSignInNonce)
            } catch {
                accountLoginMessage = "Apple 로그인에 실패했어요. Firebase Authentication에서 Apple 제공업체가 활성화됐는지 확인해 주세요."
            }
            appleSignInNonce = ""
        }
    }

    private var selectedCatalogCard: PaymentCard? {
        PaymentCard.catalog.first { $0.productId == selectedCardID }
    }

    @discardableResult
    private func requestRecommendation(for store: Store, presentsFailureAlert: Bool = true) async -> Recommendation? {
        let matchingCoupons = eligibleCoupons(for: store)
        guard !matchingCoupons.isEmpty else { return nil }
        guard await appState.ensureFirebaseAuthentication() else {
            if presentsFailureAlert {
                presentRecommendationError(
                    for: store,
                    title: "보안 연결을 준비하지 못했어요",
                    message: "Firebase 익명 로그인이 아직 준비되지 않았습니다. 실제 기기에서 서명된 앱으로 실행하면 개인 쿠폰만 안전하게 불러와 추천합니다. 지금은 명시적으로 데모 추천을 볼 수 있어요."
                )
            }
            return nil
        }
        appState.isLoadingRecommendation = true
        defer { appState.isLoadingRecommendation = false }
        let price = Int(expectedPrice) ?? 15_000
        do {
            let recommendationProfile = appState.privacyConsent.personalizationAccepted ? appState.profile : .empty
            let recommendation = try await AgentAPIService().fetchRecommendation(for: store, expectedPrice: price, profile: recommendationProfile, coupons: matchingCoupons)
            appState.cacheRecommendation(recommendation, store: store, origin: .live)
            appState.shouldShowRecommendation = true
            return recommendation
        } catch {
            if presentsFailureAlert {
                presentRecommendationError(
                    for: store,
                    title: "실시간 추천을 불러오지 못했어요",
                    message: "인증된 추천 API 또는 공공 매장 데이터 연결을 확인해 주세요. 데모 추천은 실제 API 응답이 아니라는 표시와 함께 제공합니다."
                )
            }
            return nil
        }
    }

    private func presentRecommendationError(for store: Store, title: String, message: String) {
        failedRecommendationStore = store
        recommendationErrorTitle = title
        recommendationErrorMessage = message
        showRecommendationError = true
    }

    private func handleStoreEntry(_ store: Store) async {
        appState.setCurrentStore(store)
        let matchingCoupons = eligibleCoupons(for: store)
        guard !matchingCoupons.isEmpty else { return }
        // The first alert is intentionally independent of backend latency. If a temporary API
        // failure happens in the background, the customer still receives a useful store-entry
        // notification instead of losing the core service moment.
        await notificationManager.notifyStoreEntry(store, couponCount: matchingCoupons.count)
        guard let recommendation = await requestRecommendation(for: store, presentsFailureAlert: false) else { return }
        await notificationManager.notifyStoreEntry(
            store,
            couponCount: matchingCoupons.count,
            savings: recommendation.recommendedOption.savings
        )
    }

    private func handleDemoStoreEntry() async {
        let store = Store.suwonDemoTwosome
        appState.setCurrentStore(store)
        await notificationManager.notifyStoreEntry(store, couponCount: eligibleCoupons(for: store).count, savings: 2_000)
        presentDemoRecommendation(for: store)
    }

    private func presentDemoRecommendation(for store: Store) {
        appState.cacheRecommendation(.preview(for: store), store: store, origin: .demo)
        appState.shouldShowRecommendation = true
    }

    private func handleNotificationTapIfNeeded() {
        guard let storeID = notificationManager.consumePendingStoreID() else { return }
        selectedTab = "home"
        if appState.restoreCachedRecommendation(for: storeID) { return }
        if let store = appState.nearbyStores.first(where: { $0.id == storeID }) ??
            (storeID == Store.suwonDemoTwosome.id ? .suwonDemoTwosome : nil) {
            appState.setCurrentStore(store)
            Task { await requestRecommendation(for: store) }
        }
    }

    private func eligibleCoupons(for store: Store) -> [Coupon] {
        appState.coupons.filter { $0.isActive && $0.matches(store: store) }
    }

    private func refreshNearbyStores(at coordinate: CLLocationCoordinate2D) async {
        guard SuwonScope.minimumLatitude...SuwonScope.maximumLatitude ~= coordinate.latitude,
              SuwonScope.minimumLongitude...SuwonScope.maximumLongitude ~= coordinate.longitude else { return }
        guard !isRefreshingStoreDirectory else { return }
        if let previous = lastStoreDirectoryCoordinate {
            let movedMeters = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            let refreshedRecently = Date.now.timeIntervalSince(lastStoreDirectoryRefreshAt) < 120
            // Core Location can report many nearly identical points. The backend already caches
            // each area, and this guard avoids unnecessary authenticated API calls on the device.
            if refreshedRecently && movedMeters < 250 { return }
        }
        isRefreshingStoreDirectory = true
        defer { isRefreshingStoreDirectory = false }
        lastStoreDirectoryCoordinate = coordinate
        lastStoreDirectoryRefreshAt = .now
        appState.setStoreDirectoryState(.loading)

        let couponFranchises = Array(Set(appState.coupons.compactMap { SupportedFranchise.detected(in: $0.brand) }))
        let localStores = await nearbyFranchiseFinder.findStores(near: coordinate, franchises: couponFranchises)
        // Register local Apple Maps matches immediately. The public-data response below then
        // enriches the directory without making the user wait before geofencing begins.
        if !localStores.isEmpty {
            appState.setNearbyStores(localStores)
            locationMonitor.replaceMonitoredStores(localStores)
        }
        do {
            guard await appState.ensureFirebaseAuthentication() else { throw URLError(.userAuthenticationRequired) }
            let publicStores = try await AgentAPIService().fetchNearbyStores(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let stores = mergedStores(primary: localStores, secondary: publicStores, near: coordinate)
            appState.setNearbyStores(stores)
            locationMonitor.replaceMonitoredStores(stores)
        } catch {
            // MapKit results are live location data, unlike the explicit demo entry action.
            if localStores.isEmpty {
                appState.setStoreDirectoryState(.unavailable)
                locationMonitor.replaceMonitoredStores([])
            }
        }
    }

    private func mergedStores(primary: [Store], secondary: [Store], near coordinate: CLLocationCoordinate2D) -> [Store] {
        var seen = Set<String>()
        return (primary + secondary).sorted {
            CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
            < CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: CLLocation(latitude: $1.latitude, longitude: $1.longitude))
        }.filter { store in
            let coordinateKey = String(format: "%.4f-%.4f", store.latitude, store.longitude)
            return seen.insert(coordinateKey).inserted
        }
    }
}

private struct PrivacyConsentView: View {
    @State private var requiredProcessingAccepted = false
    @State private var personalizationAccepted = false
    @State private var locationPersonalizationAccepted = false
    let onContinue: (Bool, Bool) -> Void

    var body: some View {
        ZStack {
            LiquidBackground().ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "ticket.fill")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(.cyan)
                        .frame(width: 74, height: 74)
                        .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                    Text("쿠폰콕을 시작하기 전에")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("서비스에 꼭 필요한 처리와 선택 가능한 초개인화 항목을 분리해 안내해요.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    consentCard(
                        title: "필수 개인정보 처리",
                        detail: "익명 사용자 ID, 확인한 쿠폰 정보, 사용 기록을 계정 동기화와 추천 제공에 사용합니다. 쿠폰 원본 이미지는 iPhone에만 보관합니다.",
                        isOn: $requiredProcessingAccepted,
                        required: true
                    )
                    consentCard(
                        title: "쿠폰·멤버십 초개인화",
                        detail: "보유 쿠폰, 통신사·등급, 카드 상품명, 사용 여부를 이용해 현재 상황의 혜택 후보를 좁힙니다. 카드번호와 거래내역은 수집하지 않습니다.",
                        isOn: $personalizationAccepted,
                        required: false
                    )
                    consentCard(
                        title: "매장 진입 위치 개인화",
                        detail: "iOS가 주변 수원 매장 진입을 감지해 알림을 보냅니다. 위치 이력과 이동 경로는 서버에 저장하지 않습니다.",
                        isOn: $locationPersonalizationAccepted,
                        required: false
                    )

                    Label("생성형 AI는 쿠폰 문구와 추천 이유를 설명하며, 금액과 순위는 규칙 기반 Calculator가 확정합니다.", systemImage: "sparkles")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button {
                        onContinue(personalizationAccepted, locationPersonalizationAccepted)
                    } label: {
                        Text("동의하고 시작하기")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .disabled(!requiredProcessingAccepted)

                    Text("선택 동의를 거부해도 쿠폰을 직접 등록·관리할 수 있으며, 내 정보에서 언제든 변경할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .padding(24)
            }
        }
    }

    private func consentCard(title: String, detail: String, isOn: Binding<Bool>, required: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: isOn) {
                HStack(spacing: 6) {
                    Text(required ? "필수" : "선택")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(required ? Color.red : Color.cyan)
                    Text(title).font(.headline)
                }
            }
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(17)
        .background(.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white, lineWidth: 1) }
    }
}

private struct CardImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedItem: PhotosPickerItem?
    @State private var recognition: CardRecognitionResult?
    @State private var isAnalyzing = false
    @State private var errorMessage: String?
    let onUseCard: (PaymentCard) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("카드 이미지는 iPhone의 Vision OCR로만 읽고 저장하거나 서버로 전송하지 않아요.", systemImage: "iphone.and.arrow.forward")
                        .font(.footnote)
                    Label("카드번호·유효기간·CVC는 인식 결과에서 즉시 버리고 카드사·상품명만 사용해요.", systemImage: "lock.shield.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("카드 인식") {
                    PhotosPicker(selection: $selectedItem, matching: .images) {
                        Label("카드 사진 선택", systemImage: "photo.badge.plus")
                    }
                    if isAnalyzing { ProgressView("기기에서 카드 상품을 확인하는 중") }
                    if let card = recognition?.card {
                        Label(card.productName, systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.teal)
                        Button("이 카드 상품으로 입력") {
                            onUseCard(card)
                            dismiss()
                        }
                        .fontWeight(.semibold)
                    } else if recognition != nil {
                        Text("지원하는 카드 상품을 확실하게 찾지 못했어요. 이전 화면에서 직접 선택해 주세요.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if recognition?.sensitiveNumberDetectedAndIgnored == true {
                        Label("긴 숫자열은 감지 즉시 폐기했어요.", systemImage: "eye.slash.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                }

                Section("현재 지원") {
                    ForEach(PaymentCard.catalog) { card in
                        Text(card.productName)
                    }
                }
            }
            .navigationTitle("카드 상품 인식")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
            .onChange(of: selectedItem) { _, item in
                guard let item else { return }
                Task { await recognize(item) }
            }
        }
    }

    @MainActor
    private func recognize(_ item: PhotosPickerItem) async {
        isAnalyzing = true
        recognition = nil
        errorMessage = nil
        defer { isAnalyzing = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { throw OCRServiceError.invalidImage }
            recognition = try await CouponOCRService().recognizeCardProduct(in: image)
        } catch {
            errorMessage = "카드 이미지를 읽지 못했어요. 다른 사진을 선택하거나 직접 입력해 주세요."
        }
    }
}

private struct LiquidBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.98, green: 0.99, blue: 1.0), Color(red: 0.91, green: 0.96, blue: 1.0), Color(red: 0.97, green: 0.94, blue: 1.0)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(alignment: .topTrailing) {
                Circle().fill(.cyan.opacity(0.18)).frame(width: 340).blur(radius: 90).offset(x: 110, y: -125)
            }
            .overlay(alignment: .bottomLeading) {
                Circle().fill(.purple.opacity(0.12)).frame(width: 300).blur(radius: 95).offset(x: -130, y: 150)
            }
            .ignoresSafeArea()
    }
}

private struct GlassCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(AppPalette.ink.opacity(0.10), lineWidth: 1) }
            .shadow(color: AppPalette.ink.opacity(0.06), radius: 14, y: 7)
    }
}

private struct PrimaryGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(AppPalette.ink)
            .background(.white.opacity(configuration.isPressed ? 0.78 : 0.94), in: Capsule())
            .overlay { Capsule().stroke(.white.opacity(0.72), lineWidth: 1) }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private enum AppPalette {
    static let ink = Color(red: 0.055, green: 0.10, blue: 0.22)
}
