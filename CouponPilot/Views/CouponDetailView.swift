import SwiftUI
import UIKit

struct CouponDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let coupon: Coupon
    @State private var showUseConfirmation = false
    @State private var showDeleteConfirmation = false
    @State private var showEditor = false
    @State private var showCouponViewer = AppState.captureTarget == "barcode"
    @State private var storedBarcode: StoredCouponBarcode?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                CouponPassCard(coupon: coupon)

                VStack(alignment: .leading, spacing: 8) {
                    Text(coupon.title)
                        .font(.system(size: 25, weight: .bold))
                        .foregroundStyle(AppPalette.ink)
                    Text(couponBenefitDescription)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(couponPassColor)
                }

                VStack(alignment: .leading, spacing: 14) {
                    detailLine(icon: "clock", tint: coupon.daysUntilExpiry <= 3 ? AppPalette.warning : AppPalette.muted, title: expiryDescription)
                    detailLine(icon: "cart", tint: AppPalette.muted, title: coupon.minimumOrderAmount == 0 ? "최소 구매금액 없이 사용할 수 있어요" : "\(coupon.minimumOrderAmount.formatted())원 이상 구매 시 사용할 수 있어요")
                    detailLine(icon: coupon.combinableWithCard ? "checkmark.circle" : "minus.circle", tint: coupon.combinableWithCard ? AppPalette.accent : AppPalette.muted, title: coupon.combinableWithCard ? "카드 혜택과 함께 사용할 수 있어요" : "카드 혜택과 중복 사용할 수 없어요")
                }

                if !coupon.conditions.isEmpty {
                    VStack(alignment: .leading, spacing: 11) {
                        Text("사용 조건")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(AppPalette.ink)
                        ForEach(coupon.conditions, id: \.self) { condition in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(AppPalette.muted.opacity(0.65))
                                    .frame(width: 4, height: 4)
                                    .padding(.top, 7)
                                Text(condition)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(AppPalette.muted)
                            }
                        }
                    }
                }

                if coupon.localImageFilename != nil {
                    Label("등록한 쿠폰 원본은 이 기기에만 보관됩니다", systemImage: "lock.shield.fill")
                        .font(.caption)
                        .foregroundStyle(AppPalette.muted)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .background(AppPalette.topCanvas)
        .navigationTitle(coupon.brand)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showEditor = true } label: {
                        Label("쿠폰 수정", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            actionBar
        }
        .onAppear { storedBarcode = SecureCouponBarcodeStore.barcode(for: coupon.id) }
        .confirmationDialog("결제가 완료되었나요?", isPresented: $showUseConfirmation, titleVisibility: .visible) {
            Button("결제 완료 · 사용 처리", role: .destructive) {
                appState.markCouponUsed(coupon)
                dismiss()
            }
            Button("아직 결제 전", role: .cancel) {}
        } message: {
            Text("쿠폰콕은 실제 결제를 확인하지 않습니다. 결제가 완료된 경우에만 사용 처리하면 추천 후보에서 제외됩니다.")
        }
        .confirmationDialog("이 쿠폰을 삭제할까요?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("쿠폰 삭제", role: .destructive) {
                appState.deleteCoupon(coupon)
                dismiss()
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("5초 동안 실행 취소할 수 있으며, 이후 기기 내 쿠폰 이미지도 삭제됩니다.")
        }
        .sheet(isPresented: $showEditor) {
            CouponEditSheet(coupon: coupon) { updatedCoupon in
                appState.updateCoupon(updatedCoupon)
            }
        }
        .sheet(isPresented: $showCouponViewer) {
            CouponViewerSheet(coupon: coupon, storedBarcode: storedBarcode)
        }
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            Button {
                showCouponViewer = true
            } label: {
                Label("쿠폰 보기", systemImage: "ticket.fill")
                    .font(.system(size: 17, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
            }
            .buttonStyle(CouponPrimaryButtonStyle())

            HStack(spacing: 10) {
                Button("사용 완료") { showUseConfirmation = true }
                    .buttonStyle(CouponSecondaryButtonStyle())
                Button("삭제", role: .destructive) { showDeleteConfirmation = true }
                    .buttonStyle(CouponSecondaryButtonStyle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.white.opacity(0.96))
        .overlay(alignment: .top) { Divider().overlay(AppPalette.border) }
    }

    private var couponBenefitDescription: String {
        if coupon.discountType == .percentage {
            return coupon.maximumDiscount.map { "\(coupon.discountValue)% 할인 · 최대 \($0.formatted())원" } ?? "\(coupon.discountValue)% 할인"
        }
        return "\(coupon.discountValue.formatted())원 할인"
    }

    private var expiryDescription: String {
        if coupon.daysUntilExpiry == 0 { return "오늘 만료되는 쿠폰이에요" }
        return "\(coupon.daysUntilExpiry)일 후 만료 · \(coupon.expiresAt.formatted(date: .long, time: .omitted))까지"
    }

    private var couponPassColor: Color {
        CouponPassCard.color(for: coupon.brand)
    }

    private func detailLine(icon: String, tint: Color, title: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AppPalette.muted)
        }
    }
}

private struct CouponPassCard: View {
    let coupon: Coupon

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 11) {
                BrandLogo(brand: coupon.brand, size: 50)
                VStack(alignment: .leading, spacing: 4) {
                    Text(coupon.brand)
                        .font(.system(size: 16, weight: .bold))
                    Text(coupon.title)
                        .font(.system(size: 13, weight: .medium))
                        .opacity(0.80)
                        .lineLimit(1)
                }
                Spacer()
                Text(coupon.daysUntilExpiry == 0 ? "오늘 만료" : "\(coupon.daysUntilExpiry)일 후 만료")
                    .font(.system(size: 13, weight: .bold))
                    .opacity(0.82)
            }

            Spacer()

            Text(coupon.title)
                .font(.system(size: 27, weight: .bold))
                .lineLimit(2)
            Text(coupon.discountType == .percentage ? "\(coupon.discountValue)% 할인" : "\(coupon.discountValue.formatted())원 할인")
                .font(.system(size: 16, weight: .semibold))
                .padding(.top, 6)
                .opacity(0.88)
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 248, alignment: .leading)
        .background(Self.color(for: coupon.brand), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    static func color(for brand: String) -> Color {
        switch SupportedFranchise.detected(in: brand) {
        case .starbucks: Color(red: 0.00, green: 0.44, blue: 0.29)
        case .twosome: Color(red: 0.10, green: 0.11, blue: 0.13)
        case .baskinrobbins: Color(red: 0.82, green: 0.24, blue: 0.52)
        case .parisbaguette: Color(red: 0.04, green: 0.31, blue: 0.63)
        case .touslesjours: Color(red: 0.02, green: 0.38, blue: 0.25)
        case .ediya: Color(red: 0.04, green: 0.28, blue: 0.56)
        case .ashleyqueens: Color(red: 0.25, green: 0.24, blue: 0.23)
        case .hollys: Color(red: 0.74, green: 0.06, blue: 0.12)
        case .cu: Color(red: 0.43, green: 0.16, blue: 0.67)
        case .gs25: Color(red: 0.00, green: 0.42, blue: 0.28)
        case .seveneleven: Color(red: 0.00, green: 0.42, blue: 0.30)
        case .emart24: Color(red: 0.98, green: 0.72, blue: 0.00)
        default: AppPalette.accent
        }
    }
}

private struct CouponViewerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let coupon: Coupon
    let storedBarcode: StoredCouponBarcode?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let barcode = displayBarcode, let barcodeImage = CouponBarcodeRenderer.image(for: barcode) {
                        RedeemableBarcodePreview(barcode: barcode, image: barcodeImage)
                    }

                    if let image = CouponImageStore.shared.image(named: coupon.localImageFilename) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    } else if displayBarcode == nil {
                        CouponPassCard(coupon: coupon)
                        Text("등록된 쿠폰 원본 이미지가 없어요")
                            .font(.subheadline)
                            .foregroundStyle(AppPalette.muted)
                    }
                }
                .padding(20)
            }
            .background(AppPalette.topCanvas)
            .navigationTitle("쿠폰 보기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }

    /// 스크린샷 시나리오에서만 로컬 보관 바코드 화면을 재현합니다.
    /// 실제 앱에서는 Keychain에서 읽은 값만 렌더링합니다.
    private var displayBarcode: StoredCouponBarcode? {
        if let storedBarcode { return storedBarcode }
        guard AppState.captureTarget == "barcode" else { return nil }
        return StoredCouponBarcode(candidate: CouponBarcodeCandidate(value: "8801234567890", format: .code128))
    }
}

private struct CouponPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(AppPalette.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private struct CouponSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(AppPalette.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(AppPalette.canvas, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private struct RedeemableBarcodePreview: View {
    let barcode: StoredCouponBarcode
    let image: UIImage

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label("교환용 바코드", systemImage: "barcode.viewfinder")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppPalette.ink)
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(AppPalette.accent)
            }

            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(height: barcode.format == .code128 ? 104 : 180)
                .padding(.horizontal, barcode.format == .code128 ? 0 : 30)

            Text("\(barcode.format.title) · 이 iPhone에 암호화 보관됨")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(.white.opacity(0.86), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("교환용 \(barcode.format.title) 바코드")
    }
}

private struct CouponBarcodeUnavailablePreview: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "barcode.viewfinder")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(AppPalette.accent)
            Text("교환용 바코드가 저장되지 않았어요")
                .font(.headline)
            Text("쿠폰 사진을 다시 등록해 실제 바코드를 인식하거나, 원본 쿠폰 앱에서 확인해 주세요.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

private struct CouponEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let coupon: Coupon
    let onSave: (Coupon) -> Void

    @State private var brand: String
    @State private var title: String
    @State private var discountType: Coupon.DiscountType
    @State private var discountValue: Int
    @State private var minimumOrderAmount: Int
    @State private var maximumDiscountText: String
    @State private var expiresAt: Date
    @State private var combinableWithCard: Bool
    @State private var conditionsText: String

    init(coupon: Coupon, onSave: @escaping (Coupon) -> Void) {
        self.coupon = coupon
        self.onSave = onSave
        _brand = State(initialValue: coupon.brand)
        _title = State(initialValue: coupon.title)
        _discountType = State(initialValue: coupon.discountType)
        _discountValue = State(initialValue: coupon.discountValue)
        _minimumOrderAmount = State(initialValue: coupon.minimumOrderAmount)
        _maximumDiscountText = State(initialValue: coupon.maximumDiscount.map(String.init) ?? "")
        _expiresAt = State(initialValue: coupon.expiresAt)
        _combinableWithCard = State(initialValue: coupon.combinableWithCard)
        _conditionsText = State(initialValue: coupon.conditions.joined(separator: ", "))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("쿠폰 정보") {
                    TextField("브랜드", text: $brand)
                    TextField("쿠폰명", text: $title)
                    Picker("할인 방식", selection: $discountType) {
                        Text("금액 할인").tag(Coupon.DiscountType.fixedAmount)
                        Text("퍼센트 할인").tag(Coupon.DiscountType.percentage)
                    }
                    TextField("할인 금액", value: $discountValue, format: .number)
                        .keyboardType(.numberPad)
                    TextField("최소 주문 금액", value: $minimumOrderAmount, format: .number)
                        .keyboardType(.numberPad)
                    if discountType == .percentage {
                        TextField("최대 할인액 (미확인 시 비움)", text: $maximumDiscountText)
                            .keyboardType(.numberPad)
                    }
                    DatePicker("유효기간", selection: $expiresAt, in: Calendar.current.startOfDay(for: .now)..., displayedComponents: .date)
                    Toggle("카드 혜택과 중복 가능", isOn: $combinableWithCard)
                }
                Section("사용 조건") {
                    TextField("쉼표로 구분", text: $conditionsText, axis: .vertical)
                        .lineLimit(3...6)
                    Text("조건이 불확실하면 비워 두고, 결제 전 공식 쿠폰 화면을 확인하세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("쿠폰 수정")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        let maximumDiscount = discountType == .percentage ? Int(maximumDiscountText.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
                        let conditions = conditionsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                        onSave(Coupon(
                            id: coupon.id,
                            brand: brand.trimmingCharacters(in: .whitespacesAndNewlines),
                            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                            discountType: discountType,
                            discountValue: max(0, discountValue),
                            minimumOrderAmount: max(0, minimumOrderAmount),
                            maximumDiscount: maximumDiscount,
                            expiresAt: expiresAt,
                            combinableWithCard: combinableWithCard,
                            referencePrice: coupon.referencePrice,
                            conditions: conditions,
                            localImageFilename: coupon.localImageFilename
                        ))
                        dismiss()
                    }
                    .disabled(brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct UsedCouponDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let coupon: UsedCoupon
    @State private var showRestoreConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let image = CouponImageStore.shared.image(named: coupon.localImageFilename) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.primary.opacity(0.08), lineWidth: 1) }
                } else if let resourceName = coupon.imageResourceName, let image = UIImage(named: resourceName) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.primary.opacity(0.08), lineWidth: 1) }
                }

                Label("사용 완료", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text(coupon.productName)
                    .font(.title2.weight(.bold))

                VStack(spacing: 0) {
                    detailRow("교환처", value: coupon.brand)
                    Divider()
                    detailRow("사용일", value: coupon.usedAt.formatted(date: .long, time: .omitted))
                    Divider()
                    detailRow("유효기간", value: coupon.expiresAt.formatted(date: .long, time: .omitted))
                    Divider()
                    detailRow("주문번호", value: coupon.orderNumber)
                }
                .padding(.horizontal, 16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                if coupon.originalCoupon != nil {
                    Button { showRestoreConfirmation = true } label: {
                        Label("사용 가능한 쿠폰으로 복원", systemImage: "arrow.uturn.backward.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppPalette.accent)
                } else {
                    Label("이전 버전에서 저장한 기록은 원본 할인 조건이 없어 복원할 수 없어요", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .navigationTitle("사용 완료 쿠폰")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("이 쿠폰을 다시 사용 가능으로 복원할까요?", isPresented: $showRestoreConfirmation, titleVisibility: .visible) {
            Button("쿠폰 복원") {
                if appState.restoreUsedCoupon(coupon) { dismiss() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("할인 금액, 사용 조건, 만료일과 기기 내 이미지가 원래 상태로 복원됩니다.")
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.semibold)
        }
        .padding(.vertical, 15)
    }
}
