import UIKit
@preconcurrency import Vision

struct CouponOCRService {
    /// UIImage는 메모리에서만 처리하고 서버로 업로드하지 않습니다.
    func recognizeRawText(in image: UIImage) async throws -> String {
        let boxes = try await recognizeTextBoxes(in: image)
        return boxes.map(\.text).joined(separator: "\n")
    }

    private func recognizeTextBoxes(in image: UIImage) async throws -> [RecognizedTextBox] {
        guard let cgImage = image.cgImage else { throw OCRServiceError.invalidImage }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error { continuation.resume(throwing: error); return }
                let boxes = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { observation -> RecognizedTextBox? in
                        guard let text = observation.topCandidates(1).first?.string,
                              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                        return RecognizedTextBox(text: text, normalizedBoundingBox: observation.boundingBox)
                    } ?? []
                continuation.resume(returning: boxes)
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

    /// Prepares a one-time card-identification payload. The original front and back photos never
    /// leave the device and are never written to disk. The back remains OCR-only. The front may
    /// leave the device only as a visual signature after all detected text and conservative PAN
    /// zones are covered, then Vision confirms no readable text remains (fail closed).
    func prepareSafeCardRecognitionPayload(front: UIImage, back: UIImage) async throws -> SafeCardRecognitionPayload {
        async let frontBoxes = recognizeTextBoxes(in: front)
        async let backText = recognizeRawText(in: back)
        let (frontTextBoxes, backRawText) = try await (frontBoxes, backText)
        let frontRawText = frontTextBoxes.map(\.text).joined(separator: "\n")

        let frontSafeText = CardPrivacyRedactor.redact(frontRawText)
        let backSafeText = CardPrivacyRedactor.redact(backRawText)
        guard !(frontSafeText.text + backSafeText.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty else {
            throw OCRServiceError.noNonSensitiveCardIdentity
        }
        let visualSignature = try CardVisualSignature.redactedFront(from: front, textBoxes: frontTextBoxes)
        let remainingText = try await recognizeTextBoxes(in: visualSignature)
        guard remainingText.isEmpty else { throw OCRServiceError.residualTextDetected }
        guard let imageData = CardVisualSignature.compressedJPEG(from: visualSignature) else { throw OCRServiceError.safeImageTooLarge }

        return SafeCardRecognitionPayload(
            frontText: frontSafeText.text,
            backText: backSafeText.text,
            frontVisualSignatureBase64: imageData.base64EncodedString(),
            sensitiveValuesMasked: frontSafeText.maskedSensitiveValues || backSafeText.maskedSensitiveValues
        )
    }
}

struct CardRecognitionResult: Equatable {
    let card: PaymentCard?
    let sensitiveNumberDetectedAndIgnored: Bool
}

private struct RecognizedTextBox {
    let text: String
    let normalizedBoundingBox: CGRect
}

/// This payload is memory-only. Its visual field contains a re-rendered, text-free front image;
/// the original `UIImage`, original OCR text and back image never appear in this model.
struct SafeCardRecognitionPayload: Equatable {
    let frontText: String
    let backText: String
    let frontVisualSignatureBase64: String
    let sensitiveValuesMasked: Bool
}

private enum CardVisualSignature {
    /// 120 KB leaves headroom under the API's 256 KB body limit and avoids retaining a detailed image.
    private static let maximumBytes = 120_000

    static func redactedFront(from image: UIImage, textBoxes: [RecognizedTextBox]) throws -> UIImage {
        guard let cgImage = image.cgImage else { throw OCRServiceError.invalidImage }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > 0, height > 0 else { throw OCRServiceError.invalidImage }
        let normalized = UIImage(cgImage: cgImage)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { context in
            normalized.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
            context.cgContext.setFillColor(UIColor.black.cgColor)
            // Mask every text observation, not only values that happen to match a PAN regex.
            for box in textBoxes {
                let rect = CGRect(
                    x: box.normalizedBoundingBox.minX * width,
                    y: (1 - box.normalizedBoundingBox.maxY) * height,
                    width: box.normalizedBoundingBox.width * width,
                    height: box.normalizedBoundingBox.height * height
                ).insetBy(dx: -18, dy: -14).intersection(CGRect(x: 0, y: 0, width: width, height: height))
                context.cgContext.fill(rect)
            }
            // OCR can miss embossed or vertical digits. Discard the lower half, where PAN, name,
            // expiry and network security marks are commonly placed, even when no text was read.
            context.cgContext.fill(CGRect(x: 0, y: height * 0.50, width: width, height: height * 0.50))
        }
    }

    static func compressedJPEG(from image: UIImage) -> Data? {
        let candidates: [(CGFloat, CGFloat)] = [(720, 0.45), (560, 0.40), (420, 0.35)]
        for (targetWidth, quality) in candidates {
            let scale = min(1, targetWidth / image.size.width)
            let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
            let rendered = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            if let data = rendered.jpegData(compressionQuality: quality), data.count <= maximumBytes { return data }
        }
        return nil
    }
}

private enum CardPrivacyRedactor {
    private static let sensitivePatterns: [String] = [
        #"(?:\d[\s-]?){3,}"#, // Includes every PAN group, even when Vision splits the full number.
        #"\b(?:0?[1-9]|1[0-2])\s*[/.-]\s*(?:\d{2}|\d{4})\b"#,
        #"(?i)\b(?:cvc|cvv|security\s*code|유효기간)\b\s*[:#-]?\s*\d{0,4}"#,
        #"(?i)\b(?:barcode|바코드)\b\s*[:#-]?\s*[A-Z0-9 -]{3,}"#
    ]

    static func redact(_ rawText: String) -> (text: String, maskedSensitiveValues: Bool) {
        var text = rawText
        var masked = false
        for pattern in sensitivePatterns {
            let updated = text.replacingOccurrences(of: pattern, with: "[민감정보 제거]", options: .regularExpression)
            if updated != text { masked = true }
            text = updated
        }
        // Vision occasionally includes e-mail or a phone number in a card photo. They are not
        // needed for issuer/product matching and therefore never leave the device either.
        text = CouponOCRParser.redactedForRemoteNormalization(text)
        return (text: text.prefix(2_500).description, maskedSensitiveValues: masked)
    }

}

enum OCRServiceError: Error {
    case invalidImage
    case noNonSensitiveCardIdentity
    case residualTextDetected
    case safeImageTooLarge
}

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
