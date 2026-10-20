"use client";

import { useEffect } from "react";
import { datadogRum } from "@datadog/browser-rum";
import { useConsentStore } from "@/hooks/useConsentStore";
import { redactContext, redactPii, scrubUrl } from "@/lib/pii";

// Fallback flag in case the installed @datadog/browser-rum version doesn't
// expose getInitConfiguration().
let rumInitialized = false;

function isRumInitialized(): boolean {
  if (typeof datadogRum.getInitConfiguration === "function") {
    return Boolean(datadogRum.getInitConfiguration());
  }
  return rumInitialized;
}

export function RumProvider({ children }: { children: React.ReactNode }) {
  const { hasAnalyticsConsent } = useConsentStore();

  useEffect(() => {
    if (hasAnalyticsConsent) {
      if (isRumInitialized()) return;

      const releaseVersion =
        process.env.NEXT_PUBLIC_APP_VERSION ||
        process.env.NEXT_PUBLIC_RELEASE_ID ||
        "1.0.0";
      const appEnv =
        process.env.NEXT_PUBLIC_APP_ENV ||
        process.env.NODE_ENV ||
        "production";

      datadogRum.init({
        applicationId: process.env.NEXT_PUBLIC_DATADOG_APP_ID || "dummy-app-id",
        clientToken: process.env.NEXT_PUBLIC_DATADOG_CLIENT_TOKEN || "dummy-client-token",
        site: process.env.NEXT_PUBLIC_DATADOG_SITE || "datadoghq.com",
        service: process.env.NEXT_PUBLIC_DATADOG_SERVICE || "arenax-frontend",
        env: appEnv,
        version: releaseVersion,
        sessionSampleRate: Number(process.env.NEXT_PUBLIC_RUM_SAMPLE_RATE || "100"),
        sessionReplaySampleRate: Number(process.env.NEXT_PUBLIC_REPLAY_SAMPLE_RATE || "20"),
        trackUserInteractions: true,
        trackResources: true,
        trackLongTasks: true,
        defaultPrivacyLevel: "mask-user-input",
        beforeSend: (event) => {
          // Scrub view URLs for query parameters containing tokens, OTPs, or evidence
          if (event.view?.url) {
            event.view.url = scrubUrl(event.view.url);
          }

          // Scrub general context
          if (event.context) {
            event.context = redactContext(event.context) as typeof event.context;
          }

          // Scrub error messages, stacks, and resource URLs if present
          const eventAny = event as Record<string, unknown>;
          if (eventAny.error && typeof eventAny.error === "object") {
            const errObj = eventAny.error as Record<string, unknown>;
            if (typeof errObj.message === "string") {
              errObj.message = redactPii(errObj.message);
            }
            if (typeof errObj.stack === "string") {
              errObj.stack = redactPii(errObj.stack);
            }
          }

          if (eventAny.action && typeof eventAny.action === "object") {
            const actObj = eventAny.action as Record<string, unknown>;
            if (actObj.target && typeof actObj.target === "object") {
              const tgt = actObj.target as Record<string, unknown>;
              if (typeof tgt.name === "string") {
                tgt.name = redactPii(tgt.name);
              }
            }
          }

          if (eventAny.resource && typeof eventAny.resource === "object") {
            const resObj = eventAny.resource as Record<string, unknown>;
            if (typeof resObj.url === "string") {
              resObj.url = scrubUrl(resObj.url);
            }
          }

          return true;
        },
      });
      rumInitialized = true;
    } else if (isRumInitialized()) {
      // Consent revoked (or never granted) — stop tracking and clear any
      // identified user so no further data is collected/associated.
      datadogRum.stopSession();
      datadogRum.clearUser();
      rumInitialized = false;
    }
  }, [hasAnalyticsConsent]);

  return <>{children}</>;
}
