import SwiftUI

struct RecommendationSheet: View {
    let recommendation: Recommendation
    let isDemo: Bool

    private var accent: Color { isDemo ? .orange : .cyan }

    var body: some View {
        ZStack {
            RecommendationLiquidBackground(accent: accent)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 15) {
                    hero
                    bestOption
                    aiExplanation
                    sourceSection
                    alternatives
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 36)
            }
        }
    }

    private var hero: some View {
        RecommendationGlassSurface(tint: accent, cornerRadius: 30) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(.white.opacity(0.34))
                    Image(systemName: "sparkles")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(accent)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 5) {
                    Text("\(recommendation.storeName)에서")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary.opacity(0.72))
                    Text("최대 \(recommendation.recommendedOption.savings.formatted())원\n절약할 수 있어요")
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                        .lineSpacing(-3)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 7) {
                Image(systemName: isDemo ? "testtube.2" : "checkmark.seal.fill")
                Text(isDemo ? "데모 추천" : "계산 결과")
                Text("·")
                Text(isDemo ? "시연용" : "실시간 API")
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(isDemo ? Color.orange : Color.teal)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.48), in: Capsule())
        }
    }

    private var bestOption: some View {
        RecommendationGlassSurface(tint: .mint) {
            Label("가장 좋은 조합", systemImage: "seal.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.teal)

            Text(recommendation.recommendedOption.title)
                .font(.title3.weight(.bold))

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("\(recommendation.recommendedOption.finalPrice.formatted())원")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("정가 \((recommendation.recommendedOption.originalPrice ?? recommendation.originalPrice).formatted())원")
                    .font(.caption)
                    .strikethrough()
                    .foregroundStyle(.secondary)
                Spacer()
                Text("−\(recommendation.recommendedOption.savings.formatted())원")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.teal)
            }

            FlowLayout(spacing: 7) {
                ForEach(recommendation.recommendedOption.badges, id: \.self) { badge in
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.56), in: Capsule())
                        .overlay { Capsule().stroke(.white.opacity(0.75), lineWidth: 1) }
                }
            }
        }
    }

    private var aiExplanation: some View {
        RecommendationGlassSurface(tint: .purple) {
            Label("AI 추천 이유", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(.indigo)
            Text(recommendation.explanation)
                .font(.subheadline)
                .foregroundStyle(.primary.opacity(0.76))
                .fixedSize(horizontal: false, vertical: true)

            if isDemo {
                Label("서버 응답이 아닌 시연용 계산 결과입니다.", systemImage: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private var sourceSection: some View {
        if !recommendation.benefitSources.isEmpty {
            RecommendationGlassSurface(tint: .cyan) {
                Label("공식 혜택 근거", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.teal)
                ForEach(recommendation.benefitSources) { source in
                    Link(destination: URL(string: source.sourceURL)!) {
                        HStack(spacing: 11) {
                            Image(systemName: "doc.text.fill")
                                .font(.title3)
                                .foregroundStyle(.teal)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.provider).font(.subheadline.weight(.bold))
                                Text(source.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.primary)
                        .padding(13)
                        .background(.white.opacity(0.38), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(.white.opacity(0.66), lineWidth: 1) }
                    }
                }
            }
        } else {
            RecommendationGlassSurface(tint: .gray) {
                Label("공식 혜택 근거 없음", systemImage: "info.circle")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("현재 매장에 적용할 공식 통신사 혜택 문서를 찾지 못했어요. 통신사 앱에서 최종 적용 여부를 확인해 주세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var alternatives: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("다른 방법")
                .font(.headline)
                .padding(.leading, 4)
            ForEach(recommendation.alternatives) { option in
                RecommendationGlassSurface(tint: .blue, cornerRadius: 20) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.title).font(.subheadline.weight(.semibold))
                            Text("\(option.savings.formatted())원 절약")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(option.finalPrice.formatted())원")
                            .font(.subheadline.weight(.bold))
                    }
                }
            }
        }
    }
}

private struct RecommendationLiquidBackground: View {
    let accent: Color

    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.96, green: 0.98, blue: 1), Color(red: 0.93, green: 0.96, blue: 1), Color(red: 0.98, green: 0.95, blue: 1)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topTrailing) {
            Circle().fill(accent.opacity(0.20)).frame(width: 300).blur(radius: 72).offset(x: 95, y: -105)
        }
        .overlay(alignment: .bottomLeading) {
            Circle().fill(.purple.opacity(0.14)).frame(width: 280).blur(radius: 78).offset(x: -105, y: 110)
        }
        .ignoresSafeArea()
    }
}

private struct RecommendationGlassSurface<Content: View>: View {
    let tint: Color
    var cornerRadius: CGFloat = 24
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        LinearGradient(
                            colors: [.white.opacity(0.52), tint.opacity(0.12), .white.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(colors: [.white.opacity(0.88), tint.opacity(0.22), .white.opacity(0.36)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
            }
            .shadow(color: tint.opacity(0.10), radius: 18, y: 9)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let rows = rows(for: subviews, in: width)
        return CGSize(width: width, height: rows.reduce(0) { $0 + $1.height } + max(0, CGFloat(rows.count - 1) * spacing))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, in: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(for subviews: Subviews, in width: CGFloat) -> [(indices: [Int], height: CGFloat)] {
        var result: [(indices: [Int], height: CGFloat)] = []
        var row: [Int] = []
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let requiredWidth = row.isEmpty ? size.width : rowWidth + spacing + size.width
            if !row.isEmpty && requiredWidth > width {
                result.append((row, rowHeight))
                row = []
                rowWidth = 0
                rowHeight = 0
            }
            row.append(index)
            rowWidth = row.count == 1 ? size.width : rowWidth + spacing + size.width
            rowHeight = max(rowHeight, size.height)
        }
        if !row.isEmpty { result.append((row, rowHeight)) }
        return result
    }
}
