import UIKit
import Vision

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
}

enum OCRServiceError: Error { case invalidImage }

enum CouponOCRParser {
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
