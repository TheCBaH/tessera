'use strict';

const { defineConfig, devices } = require('@playwright/test');

// One pinned Chromium project, fixed viewport, deviceScaleFactor 1, fixed theme, disabled animation
// and cursor blinking, and no external network. Baselines are created in that same environment.
module.exports = defineConfig({
  testDir: './tests',
  // *.node.test.js files (tests/driver.node.test.js, tests/trace-decoder.node.test.js) run standalone
  // under plain `node --test`, not under Playwright -- they use node:test/node:assert, not this
  // runner's own `test` global, and are deliberately browser-free. Only *.spec.js is a Playwright test.
  testMatch: '**/*.spec.js',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: 0,
  reporter: [['list']],
  timeout: 30000,
  expect: {
    toHaveScreenshot: { maxDiffPixelRatio: 0.01 },
  },
  use: {
    baseURL: 'http://localhost:4173',
    viewport: { width: 800, height: 400 },
    deviceScaleFactor: 1,
    trace: 'off',
  },
  webServer: {
    command: 'node server.js',
    port: 4173,
    reuseExistingServer: !process.env.CI,
    timeout: 30000,
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
});
