import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: process.env.CI ? "github" : "list",
  // Visual regression baselines are platform-specific (font rendering and
  // anti-aliasing differ across OSes), so keep them in a dedicated snapshot
  // directory that can be reviewed and approved per platform.
  snapshotDir: "./e2e/__screenshots__",
  // Fail the run when a committed baseline is missing instead of silently
  // writing a new one, so intentional visual changes must be reviewed and
  // approved rather than masked by an auto-generated baseline.
  updateSnapshots: process.env.UPDATE_SNAPSHOTS ? "all" : "missing",
  expect: {
    // Allow a tiny, deterministic pixel tolerance for sub-pixel rendering
    // differences while still surfacing real layout regressions (text
    // overflow, obscured bracket state, money amounts, primary actions).
    toHaveScreenshot: {
      maxDiffPixelRatio: 0.01,
      animations: "disabled",
      caret: "hide",
      scale: "css",
    },
  },
  use: {
    baseURL: process.env.PLAYWRIGHT_BASE_URL ?? "http://localhost:3000",
    trace: "on-first-retry",
    // Deterministic rendering for screenshots: fixed viewport, fixed device
    // scale factor, and a fixed color scheme so baselines are stable.
    viewport: { width: 1280, height: 720 },
    deviceScaleFactor: 1,
    colorScheme: "light",
    locale: "en-US",
    timezoneId: "UTC",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
    {
      name: "chromium-mobile",
      use: { ...devices["Pixel 5"] },
    },
  ],
  webServer: {
    command: "npm run dev",
    // NOTE: with next-intl `localePrefix: "always"`, "/" is a 307 redirect to
    // "/en", so probing "/" never yields a 200 and Playwright waits until
    // timeout. Probe the default-locale home (public, renders 200) instead.
    url: "http://localhost:3000/en",
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
});
