import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: ['./vitest.setup.js'],
    // The precommit gate runs this suite under `nice`, below the Elixir
    // partitions, so on a loaded machine a test that takes milliseconds alone
    // can be held off the CPU for seconds. The defaults (5 s per test, 10 s
    // per hook) would turn that wait into a failure; these leave room for it
    // while still stopping a test that genuinely hangs.
    testTimeout: 30_000,
    hookTimeout: 30_000,
  },
})
