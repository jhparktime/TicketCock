import { createHmac } from "node:crypto";

export type SensitiveValueKind = "card-number" | "long-digit-secret" | "phone" | "email" | "resident-id";

export type SensitiveValueFinding = {
  kind: SensitiveValueKind;
  path: string;
};

const EMAIL_PATTERN = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/iu;
const KOREAN_PHONE_PATTERN = /(?:^|\D)(?:\+?82[-\s]?)?0?1[016789](?:[-\s]?\d){7,8}(?:\D|$)/u;
const KOREAN_RESIDENT_ID_PATTERN = /(?:^|\D)\d{6}[-\s]?[1-4]\d{6}(?:\D|$)/u;
const LONG_DIGIT_PATTERN = /(?:\d[\s-]?){12,19}/gu;
const EMAIL_REDACT_PATTERN = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/giu;
const KOREAN_PHONE_REDACT_PATTERN = /(?:\+?82[-\s]?)?0?1[016789](?:[-\s]?\d){7,8}/gu;
const KOREAN_RESIDENT_ID_REDACT_PATTERN = /\d{6}[-\s]?[1-4]\d{6}/gu;
const LONG_DIGIT_REDACT_PATTERN = /(?:\d[\s-]?){12,19}/gu;

function luhnValid(value: string) {
  const digits = value.replace(/\D/gu, "");
  if (digits.length < 13 || digits.length > 19 || /^(\d)\1+$/u.test(digits)) return false;
  let sum = 0;
  let doubleDigit = false;
  for (let index = digits.length - 1; index >= 0; index -= 1) {
    let digit = Number(digits[index]);
    if (doubleDigit) {
      digit *= 2;
      if (digit > 9) digit -= 9;
    }
    sum += digit;
    doubleDigit = !doubleDigit;
  }
  return sum % 10 === 0;
}

function sensitiveStringKind(value: string): SensitiveValueKind | undefined {
  if (EMAIL_PATTERN.test(value)) return "email";
  if (KOREAN_RESIDENT_ID_PATTERN.test(value)) return "resident-id";
  if (KOREAN_PHONE_PATTERN.test(value)) return "phone";
  const candidates = value.match(LONG_DIGIT_PATTERN) ?? [];
  if (candidates.some(luhnValid)) return "card-number";
  if (candidates.some((candidate) => candidate.replace(/\D/gu, "").length >= 12)) return "long-digit-secret";
  return undefined;
}

/**
 * Inspect values after an allowlist projection and before an Agent, MCP server, or trace.
 * Monetary values remain numeric fields and are intentionally allowed; long digit strings are
 * treated as coupon/card secrets even when they do not pass Luhn validation.
 */
export function findSensitiveValue(value: unknown, path = "$"): SensitiveValueFinding | undefined {
  if (typeof value === "string") {
    const kind = sensitiveStringKind(value);
    return kind ? { kind, path } : undefined;
  }
  if (Array.isArray(value)) {
    for (let index = 0; index < value.length; index += 1) {
      const finding = findSensitiveValue(value[index], `${path}[${index}]`);
      if (finding) return finding;
    }
    return undefined;
  }
  if (value && typeof value === "object") {
    for (const [key, item] of Object.entries(value)) {
      const finding = findSensitiveValue(item, `${path}.${key}`);
      if (finding) return finding;
    }
  }
  return undefined;
}

export function assertAgentPayloadSafe(value: unknown) {
  const finding = findSensitiveValue(value);
  if (finding) {
    throw new Error(`Agent payload rejected: ${finding.kind} at ${finding.path}`);
  }
}

/** Remove common secrets from OCR/free text before it is sent to a model. */
export function redactSensitiveText(value: string) {
  const redactions = new Set<SensitiveValueKind>();
  const apply = (pattern: RegExp, kind: SensitiveValueKind, replacement: string, input: string) =>
    input.replace(pattern, () => {
      redactions.add(kind);
      return replacement;
    });
  let text = apply(EMAIL_REDACT_PATTERN, "email", "[REDACTED_EMAIL]", value);
  text = apply(KOREAN_RESIDENT_ID_REDACT_PATTERN, "resident-id", "[REDACTED_RESIDENT_ID]", text);
  text = apply(KOREAN_PHONE_REDACT_PATTERN, "phone", "[REDACTED_PHONE]", text);
  text = apply(LONG_DIGIT_REDACT_PATTERN, "long-digit-secret", "[REDACTED_LONG_NUMBER]", text);
  return { text, redactions: [...redactions] };
}

/**
 * HMAC provides a stable per-environment pseudonym without exposing the Firebase UID to ADK.
 * This remains pseudonymous data, not anonymous data. Key rotation deliberately changes the
 * reference and prevents long-term cross-environment linkage.
 */
export function pseudonymizeSubject(subject: string, secret = process.env.PSEUDONYMIZATION_KEY) {
  const effectiveSecret = process.env.NODE_ENV === "test" && !secret
    ? "couponcok-test-pseudonym-key-not-for-production"
    : secret;
  if (!effectiveSecret || Buffer.byteLength(effectiveSecret, "utf8") < 32) {
    throw new Error("PSEUDONYMIZATION_KEY must contain at least 32 bytes");
  }
  return createHmac("sha256", effectiveSecret)
    .update("couponcok-agent-user-reference-v1\0", "utf8")
    .update(subject, "utf8")
    .digest("hex")
    .slice(0, 32);
}
