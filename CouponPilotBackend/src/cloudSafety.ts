import { GoogleAuth } from "google-auth-library";
import { redactSensitiveText } from "./privacy.js";

export type SafetyMode = "off" | "monitor" | "enforce";
export type SafetyStatus = "disabled" | "skipped" | "clean" | "matched" | "degraded";

const cloudPlatformAuth = new GoogleAuth({ scopes: ["https://www.googleapis.com/auth/cloud-platform"] });
const DLP_INFO_TYPES = ["EMAIL_ADDRESS", "PHONE_NUMBER", "CREDIT_CARD_NUMBER"] as const;

function modeFromEnvironment(value: string | undefined): SafetyMode {
  return value === "monitor" || value === "enforce" ? value : "off";
}

export function configuredDlpMode(): SafetyMode {
  return modeFromEnvironment(process.env.DLP_MODE);
}

export function configuredModelArmorMode(): SafetyMode {
  return modeFromEnvironment(process.env.MODEL_ARMOR_MODE);
}

function projectID() {
  return process.env.DLP_PROJECT_ID ?? process.env.VERTEX_PROJECT_ID;
}

async function authorizationHeaders(quotaProject?: string) {
  const client = await cloudPlatformAuth.getClient();
  const providerHeaders = await client.getRequestHeaders();
  // google-auth versions may return a Fetch Headers object instead of a plain record. Spreading
  // Headers would silently discard Authorization, so normalize it at this external boundary.
  const headers = typeof Headers !== "undefined" && providerHeaders instanceof Headers
    ? Object.fromEntries(providerHeaders.entries())
    : Object.fromEntries(Object.entries(providerHeaders).filter(([, value]) => typeof value === "string"));
  // Sensitive Data Protection bills content inspection to an explicit consumer project.
  // Supplying it avoids 403 responses from ADC-based Cloud Run identities and does not
  // disclose end-user data; the project identifier is already deployment configuration.
  return quotaProject ? { ...headers, "x-goog-user-project": quotaProject } : headers;
}

/** Provider errors are reduced to a bounded status message; request content is never logged. */
async function safeProviderError(response: Response, provider: string) {
  let reason = "";
  try {
    const body = await response.json() as { error?: { message?: unknown; status?: unknown } };
    const message = typeof body.error?.message === "string" ? body.error.message : "";
    const status = typeof body.error?.status === "string" ? body.error.status : "";
    reason = [status, message].filter(Boolean).join(": ").slice(0, 240);
  } catch {
    // A non-JSON error response is intentionally not retained.
  }
  return `${provider} returned HTTP ${response.status}${reason ? ` (${reason})` : ""}`;
}

/** Explicit detectors keep DLP latency, cost, and false positives bounded for coupon OCR text. */
export function dlpDeidentifyPayload(text: string) {
  return {
    inspectConfig: {
      infoTypes: DLP_INFO_TYPES.map((name) => ({ name })),
      minLikelihood: "POSSIBLE",
      includeQuote: false
    },
    deidentifyConfig: {
      infoTypeTransformations: {
        transformations: [{
          primitiveTransformation: {
            replaceConfig: { newValue: { stringValue: "[REDACTED_DLP]" } }
          }
        }]
      }
    },
    item: { value: text }
  };
}

/**
 * Local redaction always happens first. DLP is a defense-in-depth check for patterns the device
 * and server regex rules did not recognise. In enforce mode, an unavailable DLP service fails the
 * model call closed; in monitor mode it records only a reason code and keeps the safe local path.
 */
export async function deidentifyTextForModel(rawText: string): Promise<{ text: string; status: SafetyStatus; localRedactions: string[] }> {
  const local = redactSensitiveText(rawText);
  const mode = configuredDlpMode();
  const project = projectID();
  if (mode === "off") return { text: local.text, status: "disabled", localRedactions: local.redactions };
  if (!project) {
    if (mode === "enforce") throw new Error("DLP enforce mode requires DLP_PROJECT_ID or VERTEX_PROJECT_ID");
    console.warn("DLP monitor skipped: project is not configured");
    return { text: local.text, status: "skipped", localRedactions: local.redactions };
  }
  try {
    const response = await fetch(`https://dlp.googleapis.com/v2/projects/${encodeURIComponent(project)}/content:deidentify`, {
      method: "POST",
      headers: { ...(await authorizationHeaders(project)), "content-type": "application/json" },
      body: JSON.stringify(dlpDeidentifyPayload(local.text)),
      signal: AbortSignal.timeout(Number(process.env.DLP_TIMEOUT_MS ?? 3_000))
    });
    if (!response.ok) throw new Error(await safeProviderError(response, "DLP"));
    const body = await response.json() as { item?: { value?: unknown } };
    const text = typeof body.item?.value === "string" ? body.item.value : undefined;
    if (text === undefined) throw new Error("DLP response did not contain deidentified text");
    return { text, status: text === local.text ? "clean" : "matched", localRedactions: local.redactions };
  } catch (error) {
    const reason = error instanceof Error ? error.message : "unknown";
    if (mode === "enforce") throw new Error(`DLP enforcement unavailable: ${reason}`);
    console.warn("DLP monitor degraded", { reason });
    return { text: local.text, status: "degraded", localRedactions: local.redactions };
  }
}

/**
 * Defense in depth for the iOS-produced card visual signature. The client already covers every
 * Vision text box and the lower card half, but an untrusted HTTP caller could lie about that.
 * Before Gemini sees pixels, DLP redacts **all** readable text again. The original signature is
 * never persisted, logged, or returned to the client; only DLP's redacted bytes stay in memory.
 */
export async function redactCardVisualSignatureForModel(base64Image: string): Promise<string> {
  const project = projectID();
  if (configuredDlpMode() !== "enforce" || !project) {
    throw new Error("Card visual classification requires DLP_MODE=enforce and a DLP project");
  }
  try {
    const response = await fetch(
      `https://dlp.googleapis.com/v2/projects/${encodeURIComponent(project)}/locations/global/image:redact`,
      {
        method: "POST",
        headers: { ...(await authorizationHeaders(project)), "content-type": "application/json" },
        body: JSON.stringify({
          byteItem: { type: "IMAGE_JPEG", data: base64Image },
          imageRedactionConfigs: [{ redactAllText: true }],
          includeFindings: false
        }),
        signal: AbortSignal.timeout(Number(process.env.DLP_IMAGE_TIMEOUT_MS ?? 5_000))
      }
    );
    if (!response.ok) throw new Error(await safeProviderError(response, "DLP image redaction"));
    const body = await response.json() as { redactedImage?: unknown };
    if (typeof body.redactedImage !== "string" || !body.redactedImage.length) {
      throw new Error("DLP image redaction returned no image");
    }
    return body.redactedImage;
  } catch (error) {
    const reason = error instanceof Error ? error.message : "unknown";
    throw new Error(`Card visual signature blocked because DLP image redaction was unavailable: ${reason}`);
  }
}

function modelArmorTemplateName() {
  const project = process.env.MODEL_ARMOR_PROJECT_ID ?? process.env.VERTEX_PROJECT_ID;
  const location = process.env.MODEL_ARMOR_LOCATION ?? "asia-northeast3";
  const template = process.env.MODEL_ARMOR_TEMPLATE;
  return project && template ? { project, location, template } : undefined;
}

/** Return only the policy state. Model Armor content and raw prompts are never logged. */
export async function checkModelArmorText(text: string, surface: "prompt" | "response"): Promise<SafetyStatus> {
  const mode = configuredModelArmorMode();
  const configured = modelArmorTemplateName();
  if (mode === "off") return "disabled";
  if (!configured) {
    if (mode === "enforce") throw new Error("Model Armor enforce mode requires project, location, and template configuration");
    console.warn("Model Armor monitor skipped: template is not configured", { surface });
    return "skipped";
  }
  const operation = surface === "prompt" ? "sanitizeUserPrompt" : "sanitizeModelResponse";
  const requestBody = surface === "prompt" ? { userPromptData: { text } } : { modelResponseData: { text } };
  try {
    const response = await fetch(
      `https://modelarmor.${configured.location}.rep.googleapis.com/v1/projects/${encodeURIComponent(configured.project)}/locations/${encodeURIComponent(configured.location)}/templates/${encodeURIComponent(configured.template)}:${operation}`,
      {
        method: "POST",
        headers: { ...(await authorizationHeaders()), "content-type": "application/json" },
        body: JSON.stringify(requestBody),
        signal: AbortSignal.timeout(Number(process.env.MODEL_ARMOR_TIMEOUT_MS ?? 3_000))
      }
    );
    if (!response.ok) throw new Error(`Model Armor returned HTTP ${response.status}`);
    const body = await response.json() as { sanitizationResult?: { filterMatchState?: unknown } };
    const matched = body.sanitizationResult?.filterMatchState === "MATCH_FOUND";
    if (matched && mode === "enforce") throw new Error(`Model Armor blocked ${surface}`);
    if (matched) console.warn("Model Armor monitor match", { surface });
    return matched ? "matched" : "clean";
  } catch (error) {
    const reason = error instanceof Error ? error.message : "unknown";
    if (mode === "enforce") throw error;
    console.warn("Model Armor monitor degraded", { surface, reason });
    return "degraded";
  }
}
