import { defineConfig } from 'vitest/config';

// Vitest 3+ no longer excludes dist/ by default: after `npm run build` the
// compiled copies of the tests would be collected (and fail) as well.
export default defineConfig({
  test: {
    include: ['src/**/*.test.ts'],
  },
});
