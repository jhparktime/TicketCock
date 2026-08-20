import { SpanStatusCode, trace, type Attributes } from "@opentelemetry/api";
import { randomUUID } from "node:crypto";
import type { NextFunction, Request, Response } from "express";

const tracer = trace.getTracer("couponcok-agent", "1.0.0");
let initialization: Promise<void> | undefined;

export type ObservedRequest = Request & { couponcokRequestId?: string };

export function requestCorrelationID(req: Request) {
  return (req as ObservedRequest).couponcokRequestId;
}

/**
 * Node API는 공개 진입 경계이므로 공급망을 작게 유지합니다. 표준 OpenTelemetry
 * span과 Cloud Logging용 구조화 로그를 만들고, AgentOps 자동 계측은 ADK 서비스가 담당합니다.
 */
export function initializeObservability() {
  if (!initialization) {
    initialization = (async () => {
      if (process.env.NODE_ENV !== "test") console.log("CouponCock OpenTelemetry boundary enabled; AgentOps runs in ADK service");
    })();
  }
  return initialization;
}

export function recordAIUsage(input: {
  operation: string;
  model: string;
  promptTokens?: number;
  outputTokens?: number;
  totalTokens?: number;
  items?: number;
}) {
  if (process.env.NODE_ENV === "test") return;
  console.log(JSON.stringify({
    severity: "INFO",
    event: "finops.ai_usage",
    ...input
  }));
}

export function traceHttpRequest(req: Request, res: Response, next: NextFunction) {
  const requestId = randomUUID();
  (req as ObservedRequest).couponcokRequestId = requestId;
  res.setHeader("x-couponcok-request-id", requestId);
  const startedAt = performance.now();
  const span = tracer.startSpan(`${req.method} ${req.path}`, {
    attributes: {
      "http.request.method": req.method,
      "url.path": req.path,
      "couponcok.surface": req.path === "/mcp" ? "mcp" : "rest",
      "couponcok.request_id": requestId
    }
  });
  res.on("finish", () => {
    span.setAttribute("http.response.status_code", res.statusCode);
    span.setAttribute("couponcok.duration_ms", Math.round(performance.now() - startedAt));
    span.setStatus({ code: res.statusCode >= 500 ? SpanStatusCode.ERROR : SpanStatusCode.OK });
    if (process.env.NODE_ENV !== "test") {
      console.log(JSON.stringify({
        severity: res.statusCode >= 500 ? "ERROR" : "INFO",
        event: "http.request",
        requestId,
        method: req.method,
        path: req.path,
        status: res.statusCode,
        durationMs: Math.round(performance.now() - startedAt)
      }));
    }
    span.end();
  });
  next();
}

export async function traceOperation<T>(name: string, attributes: Attributes, operation: () => Promise<T>): Promise<T> {
  const startedAt = performance.now();
  return tracer.startActiveSpan(name, { attributes }, async (span) => {
    try {
      const result = await operation();
      span.setStatus({ code: SpanStatusCode.OK });
      if (process.env.NODE_ENV !== "test") console.log(JSON.stringify({ severity: "INFO", event: name, durationMs: Math.round(performance.now() - startedAt), ...attributes }));
      return result;
    } catch (error) {
      span.recordException(error instanceof Error ? error : new Error(String(error)));
      span.setStatus({ code: SpanStatusCode.ERROR, message: error instanceof Error ? error.message : "operation failed" });
      if (process.env.NODE_ENV !== "test") console.error(JSON.stringify({ severity: "ERROR", event: name, durationMs: Math.round(performance.now() - startedAt), error: error instanceof Error ? error.message : "operation failed", ...attributes }));
      throw error;
    } finally {
      span.end();
    }
  });
}
