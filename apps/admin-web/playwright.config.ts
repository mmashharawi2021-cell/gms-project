import { defineConfig } from "@playwright/test";

const API = 8011;
const WEB = 3011;
export default defineConfig({
  testDir: "./e2e",
  timeout: 120_000,
  workers: 1,
  reporter: [["list"]],
  use: { baseURL: `http://127.0.0.1:${WEB}`, locale: "ar", timezoneId: "Asia/Gaza", screenshot: "only-on-failure", trace: "retain-on-failure" },
  webServer: [
    { command: `${process.env.E2E_PYTHON ?? "..\\..\\services\\api\\.venv\\Scripts\\python"} ../../services/api/scripts/e2e_server.py`, url: `http://127.0.0.1:${API}/health`, timeout: 120_000, reuseExistingServer: false, env: { E2E_API_PORT: String(API) } },
    { command: `npx next start -p ${WEB} -H 127.0.0.1`, url: `http://127.0.0.1:${WEB}/login`, timeout: 120_000, reuseExistingServer: false, env: { GMS_API_INTERNAL_URL: `http://127.0.0.1:${API}` } },
  ],
});
