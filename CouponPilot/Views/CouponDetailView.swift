import SwiftUI
import UIKit

struct CouponDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let coupon: Coupon
    @State private var showUseConfirmation = false
    @State private var showDeleteConfirmation = false
    @State private var showEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                couponImage
                VStack(alignment: .leading, spacing: 7) {
                    Text(coupon.brand.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(coupon.title)
                        .font(.title2.weight(.bold))
                    Text(coupon.discountType == .percentage ? "제조 음료 \(coupon.discountValue)% 할인" : "\(coupon.discountValue.formatted())원 할인")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(AppPalette.accent)
                }

                VStack(spacing: 0) {
                    detailRow("유효기간", value: coupon.expiresAt.formatted(date: .long, time: .omitted))
                    Divider()
                    detailRow("최소 주문금액", value: coupon.minimumOrderAmount == 0 ? "없음" : "\(coupon.minimumOrderAmount.formatted())원")
                    Divider()
                    detailRow("카드 혜택 중복", value: coupon.combinableWithCard ? "가능" : "불가")
                }
                .padding(.horizontal, 16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                if coupon.localImageFilename != nil {
                    Label("쿠폰 이미지는 이 기기에만 보관됩니다", systemImage: "lock.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button { showEditor = true } label: {
                        Label("쿠폰 수정", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) { showDeleteConfirmation = true } label: {
                        Label("삭제", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                    }
                    .buttonStyle(.bordered)
                }

                Button(role: .destructive) { showUseConfirmation = true } label: {
                    Label("결제 후 사용 처리", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                }
                .buttonStyle(.bordered)
            }
            .padding(20)
        }
        .navigationTitle("쿠폰 상세")
        .navigationBarTitleDisplayMode(.inline)
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
    }

    @ViewBuilder
    private var couponImage: some View {
        if let image = CouponImageStore.shared.image(named: coupon.localImageFilename) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.primary.opacity(0.08), lineWidth: 1) }
        } else {
            ContentUnavailableView("저장된 이미지가 없어요", systemImage: "photo", description: Text("이미지로 추가한 쿠폰은 여기에서 원본을 확인할 수 있어요."))
                .frame(maxWidth: .infinity)
                .frame(height: 240)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
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
