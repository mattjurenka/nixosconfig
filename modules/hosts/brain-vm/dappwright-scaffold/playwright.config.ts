import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  // One worker. dAppwright drives a single browser profile with a single
  // wallet in it, and two workers racing that profile is the first
  // mysterious failure anyone hits.
  workers: 1,
  // Onboarding a wallet is slow -- it is a real UI being clicked through,
  // not an API call. The default 30s expires mid-import.
  timeout: 120_000,
  use: {
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
  },
});
