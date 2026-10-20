/**
 * Datadog RUM and Observability error reporting helper — Issue #50 / #1100.
 *
 * Centralises error reporting to Datadog RUM with release and environment
 * context, deterministic error sampling, sensitive secrets stripped, and
 * safe fallback so monitoring failures never crash user flows.
 */

"use client";

import { datadogRum } from "@datadog/browser-rum";
import { redactContext, redactErrorForMonitoring, redactPii } from "./pii";

const RELEASE_VERSION =
  process.env.NEXT_PUBLIC_APP_VERSION ||
  process.env.NEXT_PUBLIC_RELEASE_ID ||
  "1.0.0";

const ENVIRONMENT =
  process.env.NEXT_PUBLIC_APP_ENV ||
  process.env.NODE_ENV ||
  "production";

/** Default error sample rate (100% in non-prod, configurable in prod) */
const DEFAULT_ERROR_SAMPLE_RATE =
  process.env.NODE_ENV === "production" ? 1.0 : 1.0;

function getCurrentUserId(): string | undefined {
  if (typeof window === "undefined") return undefined;
  const directId = localStorage.getItem("user_id");
  if (directId) return redactPii(directId);
  try {
    const raw = localStorage.getItem("arenax_auth_user");
    if (raw) {
      const parsed = JSON.parse(raw) as { id?: string; userId?: string };
      const id = parsed.id ?? parsed.userId;
      return id ? redactPii(id) : undefined;
    }
  } catch {
    // Ignore malformed stored auth payload.
  }
  return undefined;
}

function getCurrentRoute(): string | undefined {
  if (typeof window === "undefined") return undefined;
  return window.location.pathname;
}

/**
 * Deterministic hash-based error sampling to avoid reporting floods of
 * identical errors while preserving rare unique errors.
 */
export function shouldSampleError(
  error: Error,
  sampleRate: number = DEFAULT_ERROR_SAMPLE_RATE,
): boolean {
  if (sampleRate >= 1.0) return true;
  if (sampleRate <= 0.0) return false;

  // Simple string hash
  const key = `${error.name}:${error.message}`;
  let hash = 0;
  for (let i = 0; i < key.length; i++) {
    hash = (hash << 5) - hash + key.charCodeAt(i);
    hash |= 0;
  }
  const normalized = Math.abs(hash % 1000) / 1000;
  return normalized < sampleRate;
}

export interface ReportErrorOptions {
  sampleRate?: number;
  preserveWalletAddress?: boolean;
}

/**
 * Reports an error to Datadog RUM with release context, environment context,
 * and PII/secret scrubbing. Never throws.
 */
export function reportErrorToDatadog(
  error: Error,
  context?: Record<string, unknown>,
  options: ReportErrorOptions = {},
): void {
  if (typeof window === "undefined") return;

  const sampleRate = options.sampleRate ?? DEFAULT_ERROR_SAMPLE_RATE;
  if (!shouldSampleError(error, sampleRate)) {
    return;
  }

  const safeContext = redactContext(context ?? {}, {
    preserveWalletAddress: options.preserveWalletAddress,
  }) as Record<string, unknown>;

  // Enrich with release and environment identifiers (#50)
  safeContext.release = RELEASE_VERSION;
  safeContext.environment = ENVIRONMENT;
  safeContext.timestamp = Date.now();

  if (safeContext.userId === undefined) {
    const userId = getCurrentUserId();
    if (userId) safeContext.userId = userId;
  }
  if (safeContext.route === undefined) {
    const route = getCurrentRoute();
    if (route) safeContext.route = route;
  }

  try {
    const cleanedError = redactErrorForMonitoring(error, {
      preserveWalletAddress: options.preserveWalletAddress,
    });
    datadogRum.addError(cleanedError, safeContext);
  } catch {
    // Monitoring must never break error handling or the app.
  }
}
