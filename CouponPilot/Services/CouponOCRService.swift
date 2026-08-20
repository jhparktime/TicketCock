import UIKit
@preconcurrency import Vision

struct CouponOCRService {
    /// UIImage는 메모리에서만 처리하고 서버로 업로드하지 않습니다.
    func recognizeRawText(in image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else { throw OCRServiceError.invalidImage }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let text = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n") ?? ""
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["ko-KR", "en-US"]

            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: cgImage).perform([request]) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Reads only enough text to match a user-confirmed card product. The image, OCR text,
    /// PAN, expiry date and CVC never leave the device and are not returned to the caller.
    func recognizeCardProduct(in image: UIImage) async throws -> CardRecognitionResult {
        let rawText = try await recognizeRawText(in: image)
        let normalized = rawText
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "ko_KR"))
            .replacingOccurrences(of: #"[^\p{L}\p{N}]"#, with: "", options: .regularExpression)
            .lowercased()
        let hasLongNumber = rawText.range(of: #"(?:\d[ -]?){12,19}"#, options: .regularExpression) != nil

        let matchedCard: PaymentCard?
        if normalized.contains("mrlife") || normalized.contains("미스터라이프") {
            matchedCard = PaymentCard.catalog.first { $0.productId == "shinhancard-mr-life" }
        } else if normalized.contains("톡톡pay") || normalized.contains("톡톡페이") {
            matchedCard = PaymentCard.catalog.first { $0.productId == "kbcard-talktalk-pay" }
        } else if normalized.contains("현대카드m") || normalized.contains("hyundaicardm") {
            matchedCard = PaymentCard.catalog.first { $0.productId == "hyundaicard-m" }
        } else {
            matchedCard = nil
        }
        return CardRecognitionResult(card: matchedCard, sensitiveNumberDetectedAndIgnored: hasLongNumber)
    }
}

struct CardRecognitionResult: Equatable {
    let card: PaymentCard?
    let sensitiveNumberDetectedAndIgnored: Bool
}

enum OCRServiceError: Error { case invalidImage }

enum CouponOCRParser {
    /// 서버 정규화에는 쿠폰 조건 판단에 불필요한 바코드·연락처를 보내지 않습니다.
    /// 서버도 같은 검사를 반복하지만, 기기에서 먼저 제거해 전송 자체를 최소화합니다.
    static func redactedForRemoteNormalization(_ rawText: String) -> String {
        let patterns: [(String, String)] = [
            (#"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "[이메일 제거]"),
            (#"(?:\+?82[-\s]?)?0?1[016789](?:[-\s]?\d){7,8}"#, "[전화번호 제거]"),
            (#"\d{6}[-\s]?[1-4]\d{6}"#, "[식별번호 제거]"),
            (#"(?:\d[\s-]?){12,19}"#, "[바코드 번호 제거]")
        ]
        return patterns.reduce(rawText) { partial, item in
            partial.replacingOccurrences(
                of: item.0,
                with: item.1,
                options: [.regularExpression, .caseInsensitive]
            )
        }
    }

    /// LLM 정규화 도구 호출 전에도 앱에서 즉시 보여 줄 수 있는 보수적 초안입니다.
    static func makeDraft(from rawText: String) -> CouponDraft {
        let lines = rawText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var draft = CouponDraft()
        let joined = lines.joined(separator: " ")
        draft.brand = SupportedFranchise.detected(in: joined)?.displayName ?? ""
        draft.title = lines.first(where: { line in
            !line.localizedCaseInsensitiveContains("유효기간") &&
            !line.localizedCaseInsensitiveContains("주문번호") &&
            !line.localizedCaseInsensitiveContains("교환처") &&
            line.count > 4
        }) ?? ""

        if let amount = firstNumber(matching: #"(\d{1,3}(?:,\d{3})*)\s*원\s*할인"#, in: joined) {
            draft.discountType = .fixedAmount
            draft.discountValue = amount
        } else if let percentage = firstNumber(matching: #"(\d{1,2})\s*%"#, in: joined) {
            draft.discountType = .percentage
            draft.discountValue = percentage
        }

        if let expiry = expiryDate(in: joined) { draft.expiresAt = expiry }
        return draft
    }

    private static func firstNumber(matching pattern: String, in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range].replacingOccurrences(of: ",", with: ""))
    }

    private static func expiryDate(in text: String) -> Date? {
        let pattern = #"(20\d{2})\s*[년.\-/]\s*(\d{1,2})\s*[월.\-/]\s*(\d{1,2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let values = (1...3).compactMap { index -> Int? in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return Int(text[range])
        }
        guard values.count == 3 else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: values[0], month: values[1], day: values[2]))
    }
}
