import SwiftUI
import UIKit
import CoreLocation

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var locationMonitor = LocationMonitor()
    @StateObject private var notificationManager = NotificationManager()
    @StateObject private var nearbyFranchiseFinder = NearbyFranchiseFinder()
    @State private var expectedPrice = "15000"
    @State private var selectedTab = "home"
    @State private var showCouponImporter = false
    @State private var selectedCarrier = UserProfile.demo.carrier
    @State private var selectedMembershipGrade = UserProfile.demo.membershipGrade
    @State private var selectedMonthlyBenefitStatus = UserProfile.demo.monthlyBenefitStatus
    @State private var showRecommendationError = false
    @State private var recommendationErrorTitle = "추천을 불러오지 못했어요"
    @State private var recommendationErrorMessage = "공공데이터 또는 인증된 API에 연결하지 못했습니다. 데모 결과는 실제 API 응답이 아니라는 표시와 함께 제공합니다."
    @State private var failedRecommendationStore: Store?
    @State private var lastStoreDirectoryCoordinate: CLLocationCoordinate2D?
    @State private var lastStoreDirectoryRefreshAt = Date.distantPast
    @State private var isRefreshingStoreDirectory = false

    var body: some View {
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
        .onAppear {
            locationMonitor.onStoreEntry = { store in
                Task { await handleStoreEntry(store) }
            }
            locationMonitor.onLocationUpdate = { coordinate in
                Task { await refreshNearbyStores(at: coordinate) }
            }
            locationMonitor.resumeMonitoringIfEnabled()
        }
        .sheet(isPresented: $appState.shouldShowRecommendation) {
            if let recommendation = appState.recommendation {
                RecommendationSheet(recommendation: recommendation, isDemo: appState.recommendationOrigin == .demo)
                    .presentationDetents([.large])
                    .presentationCornerRadius(34)
                    .presentationBackground(.ultraThinMaterial)
            }
        }
        .sheet(isPresented: $showCouponImporter) {
            CouponImportSheet()
                .environmentObject(appState)
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
                Text("안녕하세요, 재현님")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppPalette.ink.opacity(0.62))
                Text("오늘의 혜택")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(AppPalette.ink)
            }
            Spacer()
            ZStack {
                Circle().fill(.white.opacity(0.15))
                Image(systemName: "bell.badge.fill")
                    .font(.title3)
                    .foregroundStyle(AppPalette.ink)
            }
            .frame(width: 48, height: 48)
            .overlay { Circle().stroke(AppPalette.ink.opacity(0.12), lineWidth: 1) }
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
            Toggle("매장 진입 알림", isOn: locationMonitoringBinding)
                .labelsHidden()
                .tint(.mint)
                .accessibilityHint("켜면 수원 매장 진입을 감지해 쿠폰을 추천합니다")
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
                locationMonitor.monitoringState == .active ||
                locationMonitor.monitoringState == .requestingPermission ||
                locationMonitor.monitoringState == .needsAlwaysAuthorization
            },
            set: { enabled in
                if enabled {
                    Task { await notificationManager.requestAuthorization() }
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
                    Task { await notificationManager.requestAuthorization() }
                    locationMonitor.requestPermissionsAndMonitor(appState.nearbyStores)
                    locationMonitor.requestCurrentLocation()
                } label: {
                    Label(appState.storeDirectoryState == .unavailable ? "매장 목록 다시 불러오기" : "현재 위치 확인하기", systemImage: "location.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(PrimaryGlassButtonStyle())
            }

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
                Button("멤버십 정보 저장") {
                    appState.updateProfile(
                        carrier: selectedCarrier,
                        membershipGrade: selectedMembershipGrade,
                        monthlyBenefitStatus: selectedMonthlyBenefitStatus
                    )
                }
            }
            Section {
                Label("카드 정보는 이 데모에서 수집하지 않습니다", systemImage: "creditcard.slash.fill")
                Label("최종 혜택은 통신사 공식 앱에서 확인해 주세요", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("내 정보")
        .onAppear {
            selectedCarrier = appState.profile.carrier
            selectedMembershipGrade = appState.profile.membershipGrade
            selectedMonthlyBenefitStatus = appState.profile.monthlyBenefitStatus
        }
    }

    @discardableResult
    private func requestRecommendation(for store: Store) async -> Recommendation? {
        let matchingCoupons = eligibleCoupons(for: store)
        guard !matchingCoupons.isEmpty else { return nil }
        guard await appState.ensureFirebaseAuthentication() else {
            presentRecommendationError(
                for: store,
                title: "보안 연결을 준비하지 못했어요",
                message: "Firebase 익명 로그인이 아직 준비되지 않았습니다. 실제 기기에서 서명된 앱으로 실행하면 개인 쿠폰만 안전하게 불러와 추천합니다. 지금은 명시적으로 데모 추천을 볼 수 있어요."
            )
            return nil
        }
        appState.isLoadingRecommendation = true
        defer { appState.isLoadingRecommendation = false }
        let price = Int(expectedPrice) ?? 15_000
        do {
            let recommendation = try await AgentAPIService().fetchRecommendation(for: store, expectedPrice: price, profile: appState.profile, coupons: matchingCoupons)
            appState.recommendation = recommendation
            appState.recommendationOrigin = .live
            appState.shouldShowRecommendation = true
            return recommendation
        } catch {
            presentRecommendationError(
                for: store,
                title: "실시간 추천을 불러오지 못했어요",
                message: "인증된 추천 API 또는 공공 매장 데이터 연결을 확인해 주세요. 데모 추천은 실제 API 응답이 아니라는 표시와 함께 제공합니다."
            )
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
        // A notification must represent a real calculated recommendation. Avoid waking the
        // user with a generic alert at stores where no registered coupon can be used.
        guard let recommendation = await requestRecommendation(for: store) else { return }
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
        appState.recommendation = .preview(for: store)
        appState.recommendationOrigin = .demo
        appState.shouldShowRecommendation = true
    }

    private func eligibleCoupons(for store: Store) -> [Coupon] {
        appState.coupons.filter { $0.matches(store: store) }
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
