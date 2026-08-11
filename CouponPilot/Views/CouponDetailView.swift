import SwiftUI
import UIKit

struct CouponDetailView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let coupon: Coupon
    @State private var showUseConfirmation = false

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
                        .foregroundStyle(.cyan)
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

                Button(role: .destructive) { showUseConfirmation = true } label: {
                    Label("사용 완료로 이동", systemImage: "checkmark.seal.fill")
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
        .confirmationDialog("이 쿠폰을 사용 완료로 처리할까요?", isPresented: $showUseConfirmation, titleVisibility: .visible) {
            Button("사용 완료 처리", role: .destructive) {
                appState.markCouponUsed(coupon)
                dismiss()
            }
        } message: {
            Text("사용 기록으로 옮기면 이후 추천에서 제외됩니다.")
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

struct UsedCouponDetailView: View {
    let coupon: UsedCoupon

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
            }
            .padding(20)
        }
        .navigationTitle("사용 완료 쿠폰")
        .navigationBarTitleDisplayMode(.inline)
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
