/**
 * PII and Sensitive Secrets Redaction for Observability — Issue #50 / #1100.
 *
 * Ensures error reports, metrics, and Datadog RUM telemetry never collect
 * authentication tokens, OTPs, wallet addresses (where not required),
 * dispute evidence contents, payment secrets, emails, phone numbers, or
 * sensitive query parameters in URLs.
 */

const EMAIL_PATTERN = /[^\s@]+@[^\s@]+\.[^\s@]+/gi;
const PHONE_PATTERN = /\+?\d[\d\s\-().]{7,}\d/g;
const JWT_PATTERN = /\beyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\b/g;
const BEARER_PATTERN = /\bBearer\s+[A-Za-z0-9\-._~+/]+=*/gi;
const API_KEY_PATTERN = /\b(?:ghp|gho|ghu|ghs|ghr|xoxb|xoxp|sk_live|sk_test|pk_live|pk_test)_[A-Za-z0-9_-]{10,}\b/gi;
const STELLAR_PUBKEY_PATTERN = /\bG[A-Z2-7]{55}\b/g;
const STELLAR_SECRET_PATTERN = /\bS[A-Z2-7]{55}\b/g;
const ETH_ADDRESS_PATTERN = /\b0x[a-fA-F0-9]{40}\b/g;
const CREDIT_CARD_PATTERN = /\b(?:\d{4}[ -]?){3}\d{4}\b/g;
const PAYMENT_SECRET_PATTERN = /\b(?:pi|seti|cs)_[A-Za-z0-9]+_secret_[A-Za-z0-9]+\b/gi;
const DATA_URL_PATTERN = /data:(?:image|application|text|video)\/[^;]+;base64,[A-Za-z0-9+/=]+/gi;
const OTP_CONTEXT_PATTERN = /\b(?:otp|one[- ]?time[- ]?pass(?:code)?|pin|verification[- ]?code)\b[\s:="']+([0-9]{4,8})\b/gi;
const SENSITIVE_KV_PATTERN = /\b(?:password|passwd|secret|client_secret|auth_token|access_token|refresh_token)\b\s*[:=]\s*["']?([^"'\s,;]+)["']?/gi;

const SENSITIVE_PARAM_NAMES = new Set([
  "token",
  "auth",
  "access_token",
  "refresh_token",
  "auth_token",
  "key",
  "api_key",
  "apikey",
  "secret",
  "client_secret",
  "otp",
  "code",
  "pin",
  "password",
  "passwd",
  "evidence",
  "signature",
  "sig",
]);

const SENSITIVE_OBJECT_KEYS = new RegExp(
  "^(?:token|access_token|refresh_token|auth_token|password|passwd|secret|client_secret|apiKey|api_key|otp|pin|verificationCode|verification_code|cardNumber|cvv|cvc|paymentSecret|evidence|evidenceData|evidenceUrl|evidenceContent|fileData|attachment)$",
  "i",
);

export interface RedactOptions {
  /** If true, wallet addresses (e.g. public G...) are preserved in non-secret contexts. */
  preserveWalletAddress?: boolean;
}

/**
 * Redacts secrets and PII from a plain string.
 */
export function redactPii(value: string, options: RedactOptions = {}): string {
  if (!value || typeof value !== "string") return value;

  let result = value
    // Evidence data URLs
    .replace(DATA_URL_PATTERN, "[EVIDENCE_DATA_REDACTED]")
    // Secrets in key-value format (password=xxx, secret: xxx)
    .replace(SENSITIVE_KV_PATTERN, (match, secretVal) => {
      return match.replace(secretVal, "[SECRET_REDACTED]");
    })
    // OTPs with context
    .replace(OTP_CONTEXT_PATTERN, (match, otpCode) => {
      return match.replace(otpCode, "[OTP_REDACTED]");
    })
    // Auth tokens
    .replace(BEARER_PATTERN, "Bearer [REDACTED]")
    .replace(JWT_PATTERN, "[JWT_REDACTED]")
    .replace(API_KEY_PATTERN, "[API_KEY_REDACTED]")
    // Payment secrets
    .replace(PAYMENT_SECRET_PATTERN, "[PAYMENT_SECRET_REDACTED]")
    .replace(CREDIT_CARD_PATTERN, "[CREDIT_CARD_REDACTED]")
    // Secret seeds must always be scrubbed
    .replace(STELLAR_SECRET_PATTERN, "[STELLAR_SEED_REDACTED]")
    // Standard PII
    .replace(EMAIL_PATTERN, "[EMAIL_REDACTED]")
    .replace(PHONE_PATTERN, "[PHONE_REDACTED]");

  // Wallet addresses: scrub unless explicitly preserved
  if (!options.preserveWalletAddress) {
    result = result
      .replace(STELLAR_PUBKEY_PATTERN, "[WALLET_ADDRESS_REDACTED]")
      .replace(ETH_ADDRESS_PATTERN, "[WALLET_ADDRESS_REDACTED]");
  }

  return result;
}

/**
 * Sanitizes URLs to remove sensitive query parameters (token, otp, secret, etc.).
 */
export function scrubUrl(urlString: string): string {
  if (!urlString || typeof urlString !== "string") return urlString;

  try {
    // Check if it's a relative path or absolute URL
    const hasOrigin = urlString.startsWith("http://") || urlString.startsWith("https://");
    const parsed = hasOrigin
      ? new URL(urlString)
      : new URL(urlString, "https://placeholder.internal");

    let changed = false;
    for (const [key] of parsed.searchParams.entries()) {
      if (SENSITIVE_PARAM_NAMES.has(key.toLowerCase())) {
        parsed.searchParams.set(key, "[REDACTED]");
        changed = true;
      }
    }

    if (!changed) {
      return redactPii(urlString);
    }

    if (hasOrigin) {
      return redactPii(parsed.toString());
    }
    return redactPii(parsed.pathname + parsed.search + parsed.hash);
  } catch {
    // If not parseable as URL, fall back to string redaction
    return redactPii(urlString);
  }
}

/**
 * Deeply scrubs secrets and PII from error context objects, payloads, or arrays.
 */
export function redactContext<T>(
  value: T,
  options: RedactOptions = {},
  seen = new WeakSet<object>(),
): T {
  if (value === null || value === undefined) return value;

  if (typeof value === "string") {
    // Check if string looks like a URL
    if (value.startsWith("http://") || value.startsWith("https://") || value.includes("?")) {
      return scrubUrl(value) as unknown as T;
    }
    return redactPii(value, options) as unknown as T;
  }

  if (Array.isArray(value)) {
    return value.map((item) => redactContext(item, options, seen)) as unknown as T;
  }

  if (typeof value === "object") {
    const obj = value as Record<string, unknown>;
    if (seen.has(obj)) return value;
    seen.add(obj);

    const result: Record<string, unknown> = {};
    for (const [key, val] of Object.entries(obj)) {
      if (SENSITIVE_OBJECT_KEYS.test(key)) {
        // Redact entire sensitive field value
        result[key] = "[REDACTED]";
      } else if (key.toLowerCase().includes("url") && typeof val === "string") {
        result[key] = scrubUrl(val);
      } else {
        result[key] = redactContext(val, options, seen);
      }
    }
    return result as unknown as T;
  }

  return value;
}

/**
 * Returns a clone of `error` whose message, stack, and attached cause
 * have been stripped of secrets and PII.
 */
export function redactErrorForMonitoring(error: Error, options: RedactOptions = {}): Error {
  if (!error) return error;

  const cleanedMessage = redactPii(error.message, options);
  const cleaned = new Error(cleanedMessage);
  cleaned.name = error.name;
  if (error.stack) {
    cleaned.stack = redactPii(error.stack, options);
  }
  return cleaned;
}
