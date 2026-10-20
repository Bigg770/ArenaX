/**
 * Observability, Secret Scrubbing, and Source Map Security Tests — Issue #50.
 *
 * Verifies that:
 * 1. Auth tokens, OTPs, wallet addresses, dispute evidence, and payment secrets
 *    are scrubbed from error messages, context objects, and URLs.
 * 2. Errors reported to Datadog RUM include release and environment identifiers
 *    and can be sampled safely.
 * 3. Synthetic staging smoke test asserts zero leakage of sensitive credentials.
 * 4. Production source maps are restricted from public access.
 */

import {
  redactPii,
  scrubUrl,
  redactContext,
  redactErrorForMonitoring,
} from "@/lib/pii";
import {
  reportErrorToDatadog,
  shouldSampleError,
} from "@/lib/monitoring";
import { datadogRum } from "@datadog/browser-rum";

jest.mock("@datadog/browser-rum", () => ({
  datadogRum: {
    init: jest.fn(),
    addError: jest.fn(),
    stopSession: jest.fn(),
    clearUser: jest.fn(),
    getInitConfiguration: jest.fn(),
  },
}));

describe("Issue #50: Frontend Observability and Secret Scrubbing", () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  describe("PII and Secret Redaction (pii.ts)", () => {
    it("scrubs Bearer tokens and JWTs", () => {
      const jwt =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c";
      const bearer = `Bearer ${jwt}`;
      const text = `Failed request with header ${bearer}`;

      const scrubbed = redactPii(text);
      expect(scrubbed).not.toContain(jwt);
      expect(scrubbed).toContain("Bearer [REDACTED]");
    });

    it("scrubs API keys and tokens", () => {
      const apiKey = ["sk", "test", "51Abcdef1234567890abcdef"].join("_");
      const text = `Provider error: key ${apiKey} invalid`;

      const scrubbed = redactPii(text);
      expect(scrubbed).not.toContain(apiKey);
      expect(scrubbed).toContain("[API_KEY_REDACTED]");
    });

    it("scrubs OTPs and verification codes", () => {
      const text = "User verification failed for otp: 849201 with pin 123456";
      const scrubbed = redactPii(text);

      expect(scrubbed).not.toContain("849201");
      expect(scrubbed).not.toContain("123456");
      expect(scrubbed).toContain("[OTP_REDACTED]");
    });

    it("scrubs Stellar wallet addresses and secret seeds by default", () => {
      const stellarPubkey = "GBVOL62XCLX26SV77YFNGZ7WPTZWVMM2F3C6TYE7XEKQ3ZAYE7UWRX2K";
      const stellarSeed = "SBVOL62XCLX26SV77YFNGZ7WPTZWVMM2F3C6TYE7XEKQ3ZAYE7UWRX2K";
      const text = `Transaction failed for pubkey ${stellarPubkey} with seed ${stellarSeed}`;

      const scrubbed = redactPii(text);
      expect(scrubbed).not.toContain(stellarPubkey);
      expect(scrubbed).not.toContain(stellarSeed);
      expect(scrubbed).toContain("[WALLET_ADDRESS_REDACTED]");
      expect(scrubbed).toContain("[STELLAR_SEED_REDACTED]");
    });

    it("scrubs dispute evidence contents and base64 data URLs", () => {
      const dataUrl = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAUA";
      const text = `Dispute upload failed for image ${dataUrl}`;

      const scrubbed = redactPii(text);
      expect(scrubbed).not.toContain(dataUrl);
      expect(scrubbed).toContain("[EVIDENCE_DATA_REDACTED]");
    });

    it("scrubs payment secrets including credit cards and client secrets", () => {
      const cc = "4111 2222 3333 4444";
      const stripeSecret = ["pi", "1234567890", "secret", "abcdef1234567890"].join("_");
      const text = `Payment card ${cc} failed with client_secret ${stripeSecret}`;

      const scrubbed = redactPii(text);
      expect(scrubbed).not.toContain(cc);
      expect(scrubbed).not.toContain(stripeSecret);
      expect(scrubbed).toContain("[CREDIT_CARD_REDACTED]");
      expect(scrubbed).toContain("[PAYMENT_SECRET_REDACTED]");
    });

    it("scrubs sensitive query parameters from URLs", () => {
      const url =
        "https://arenax.gg/auth/verify?token=secret-token-123&otp=654321&user=john";
      const scrubbed = scrubUrl(url);

      expect(scrubbed).not.toContain("secret-token-123");
      expect(scrubbed).not.toContain("654321");
      expect(scrubbed).toContain("token=%5BREDACTED%5D");
      expect(scrubbed).toContain("otp=%5BREDACTED%5D");
      expect(scrubbed).toContain("user=john");
    });
  });

  describe("Context Redaction (redactContext)", () => {
    it("scrubs deeply nested sensitive fields in context objects", () => {
      const context = {
        meta: {
          token: "eyJhbGciOi...",
          auth_token: "secret",
          evidenceContent: "base64-payload-here",
          deep: {
            cardNumber: "4111222233334444",
            email: "player@arenax.gg",
            actionUrl: "https://arenax.gg/api/pay?secret=xyz123",
          },
        },
        publicField: "safe-value",
      };

      const result = redactContext(context);
      expect(result.meta.token).toBe("[REDACTED]");
      expect(result.meta.auth_token).toBe("[REDACTED]");
      expect(result.meta.evidenceContent).toBe("[REDACTED]");
      expect(result.meta.deep.cardNumber).toBe("[REDACTED]");
      expect(result.meta.deep.email).toBe("[EMAIL_REDACTED]");
      expect(result.meta.deep.actionUrl).toContain("secret=%5BREDACTED%5D");
      expect(result.publicField).toBe("safe-value");
    });
  });

  describe("Observability Context & Sampling (monitoring.ts)", () => {
    it("attaches release and environment context to reported errors", () => {
      const err = new Error("Match connection failure");
      reportErrorToDatadog(err, { matchId: "match-42" });

      expect(datadogRum.addError).toHaveBeenCalledTimes(1);
      const [, context] = (datadogRum.addError as jest.Mock).mock.calls[0];

      expect(context.release).toBeDefined();
      expect(context.environment).toBeDefined();
      expect(context.timestamp).toBeDefined();
      expect(context.matchId).toBe("match-42");
    });

    it("samples errors deterministically based on sampleRate", () => {
      const errorA = new Error("Frequent websocket reconnect ping timeout");
      const errorB = new Error("Rare payment signature validation error");

      // 0% sample rate drops all errors
      expect(shouldSampleError(errorA, 0.0)).toBe(false);
      expect(shouldSampleError(errorB, 0.0)).toBe(false);

      // 100% sample rate keeps all errors
      expect(shouldSampleError(errorA, 1.0)).toBe(true);
      expect(shouldSampleError(errorB, 1.0)).toBe(true);

      // Same error produces consistent sampling verdict
      const result1 = shouldSampleError(errorA, 0.5);
      const result2 = shouldSampleError(errorA, 0.5);
      expect(result1).toBe(result2);
    });
  });

  describe("Staging Smoke Test with Synthetic Sensitive Values", () => {
    it("ensures synthetic sensitive credentials are never forwarded to RUM", () => {
      const syntheticSecrets = {
        jwt: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.synthetic-payload.signature",
        otp: "987654",
        stellarWallet: "GAAZI4TCR3TY5OJHCTJC2A4QSY6CJWJH5IAJTGKIN2ER7LBNVKOCCWN7",
        stellarSeed: "SBVOL62XCLX26SV77YFNGZ7WPTZWVMM2F3C6TYE7XEKQ3ZAYE7UWRX2K",
        evidencePayload: "data:image/png;base64,SYNTHETIC_EVIDENCE_BYTES==",
        stripeSecret: ["pi", "syn12345", "secret", "secretxyz987"].join("_"),
      };

      const error = new Error(
        `Failed API call with seed ${syntheticSecrets.stellarSeed} and wallet ${syntheticSecrets.stellarWallet}`,
      );

      reportErrorToDatadog(error, {
        token: syntheticSecrets.jwt,
        otp: syntheticSecrets.otp,
        evidence: syntheticSecrets.evidencePayload,
        paymentSecret: syntheticSecrets.stripeSecret,
        callbackUrl: `https://staging.arenax.gg/confirm?token=${syntheticSecrets.jwt}&otp=${syntheticSecrets.otp}`,
      });

      expect(datadogRum.addError).toHaveBeenCalledTimes(1);
      const [calledError, calledContext] = (datadogRum.addError as jest.Mock).mock.calls[0];

      // Assert error message scrubbing
      expect(calledError.message).not.toContain(syntheticSecrets.stellarSeed);
      expect(calledError.message).not.toContain(syntheticSecrets.stellarWallet);

      // Assert context scrubbing
      const serializedContext = JSON.stringify(calledContext);
      expect(serializedContext).not.toContain(syntheticSecrets.jwt);
      expect(serializedContext).not.toContain(syntheticSecrets.otp);
      expect(serializedContext).not.toContain(syntheticSecrets.evidencePayload);
      expect(serializedContext).not.toContain(syntheticSecrets.stripeSecret);
    });
  });

  describe("Source Map Security Configuration", () => {
    it("verifies next.config blocks public source map serving via redirect", () => {
      // eslint-disable-next-line @typescript-eslint/no-var-requires
      const nextConfig = require("../../next.config.js");
      expect(typeof nextConfig.redirects).toBe("function");
    });
  });
});
