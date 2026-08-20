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

async function authorizationHeaders() {
  const client = await cloudPlatformAuth.getClient();
  return client.getRequestHeaders();
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
      headers: { ...(await authorizationHeaders()), "content-type": "application/json" },
      body: JSON.stringify(dlpDeidentifyPayload(local.text)),
      signal: AbortSignal.timeout(Number(process.env.DLP_TIMEOUT_MS ?? 3_000))
    });
    if (!response.ok) throw new Error(`DLP returned HTTP ${response.status}`);
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
