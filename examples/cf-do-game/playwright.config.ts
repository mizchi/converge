import { defineConfig } from "@playwright/test";

const baseURL = process.env.E2E_BASE_URL ?? "http://127.0.0.1:8787";

export default defineConfig({
  testDir: "./e2e",
  fullyParallel: false,
  retries: 0,
  timeout: 90_000,
  use: {
    baseURL,
    headless: true,
  },
  webServer: process.env.E2E_BASE_URL
    ? undefined
    : {
        command: "pnpm dev -- --port 8787 --ip 127.0.0.1 --local-protocol http --show-interactive-dev-session=false",
        url: `${baseURL}/health`,
        reuseExistingServer: true,
        timeout: 120_000,
      },
});
