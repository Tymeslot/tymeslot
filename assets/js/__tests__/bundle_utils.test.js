/**
 * Tests for Bundle Initialization Utilities
 *
 * Test Coverage:
 * - Bundle initialization and retry logic
 * - Timeout handling
 * - Error scenarios
 * - Telemetry events
 */

import { initializeBundle } from '../bundles/bundle_utils';
import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest';

describe('initializeBundle', () => {
  let telemetryEvents;
  let consoleErrorSpy;
  let telemetryListener;

  beforeEach(() => {
    // Reset window state
    delete window.liveSocket;
    delete window.CoreHooks;
    telemetryEvents = [];

    // Suppress console.error for cleaner test output (tests intentionally trigger errors)
    consoleErrorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});

    // Capture telemetry events
    telemetryListener = (e) => {
      telemetryEvents.push(e.detail);
    };
    window.addEventListener('tymeslot:bundle:loaded', telemetryListener);

    // Use fake timers for timeout control
    vi.useFakeTimers();
  });

  afterEach(() => {
    consoleErrorSpy.mockRestore();
    window.removeEventListener('tymeslot:bundle:loaded', telemetryListener);
    telemetryEvents = [];
    vi.useRealTimers();
  });

  test('initializes bundle immediately when core is ready', async () => {
    // Setup core
    const mockConnect = vi.fn();
    window.liveSocket = {
      isConnected: () => false,
      connect: mockConnect,
      hooks: {}
    };
    window.CoreHooks = { CoreHook1: {}, CoreHook2: {} };

    const bundleHooks = { BundleHook1: {} };

    await initializeBundle('test-bundle', bundleHooks);

    // Should extend hooks with bundle-specific hooks
    expect(window.liveSocket.hooks).toEqual({
      CoreHook1: {},
      CoreHook2: {},
      BundleHook1: {}
    });

    // Should connect LiveSocket
    expect(mockConnect).toHaveBeenCalledTimes(1);

    // Should emit success telemetry
    expect(telemetryEvents).toContainEqual({
      bundle: 'test-bundle',
      success: true,
      retries: 0
    });
  });

  test('retries when core is not ready and succeeds', async () => {
    const mockConnect = vi.fn();
    const bundleHooks = { BundleHook1: {} };

    // Start initialization (core not ready)
    const promise = initializeBundle('test-bundle', bundleHooks);

    // Advance time by 3 intervals (300ms)
    await vi.advanceTimersByTimeAsync(300);

    // Setup core after 3 retries
    window.liveSocket = {
      isConnected: () => false,
      connect: mockConnect,
      hooks: {}
    };
    window.CoreHooks = { CoreHook1: {} };

    // Advance one more interval to trigger check and wait for promise
    await vi.advanceTimersByTimeAsync(100);
    await promise;

    expect(mockConnect).toHaveBeenCalledTimes(1);
    expect(telemetryEvents.some(e =>
      e.bundle === 'test-bundle' &&
      e.success === true &&
      e.retries >= 3
    )).toBe(true);
  });

  test('times out after max retries and shows error', async () => {
    const bundleHooks = { BundleHook1: {} };

    // Start initialization (core never becomes ready) and catch rejection to prevent unhandled warning
    const promise = initializeBundle('test-bundle-timeout-main', bundleHooks).catch(e => e);

    // Advance time to exceed timeout (100 retries * 100ms = 10 seconds)
    await vi.runAllTimersAsync();

    const error = await promise;
    expect(error.message).toContain('Timeout waiting for core bundle');

    // Should emit failure telemetry
    expect(telemetryEvents.some(e =>
      e.bundle === 'test-bundle-timeout-main' &&
      e.success === false &&
      e.error && e.error.includes('Timeout waiting for core bundle') &&
      e.retries === 100
    )).toBe(true);

    // Should show user-visible error (check DOM)
    const errorDiv = document.querySelector('[role="alert"]');
    expect(errorDiv).toBeTruthy();
    expect(errorDiv.textContent).toContain('Core bundle failed to load');
  });

  test('does not connect if LiveSocket is already connected', async () => {
    const mockConnect = vi.fn();
    window.liveSocket = {
      isConnected: () => true, // Already connected
      connect: mockConnect,
      hooks: {}
    };
    window.CoreHooks = { CoreHook1: {} };

    await initializeBundle('test-bundle', {});

    expect(mockConnect).not.toHaveBeenCalled();
  });

  test('handles initialization errors gracefully', async () => {
    window.liveSocket = {
      isConnected: () => { throw new Error('isConnected failed'); },
      connect: vi.fn(),
      hooks: {}
    };
    window.CoreHooks = { CoreHook1: {} };

    await expect(initializeBundle('test-bundle', {})).rejects.toThrow('isConnected failed');

    expect(telemetryEvents.some(e =>
      e.bundle === 'test-bundle' &&
      e.success === false &&
      e.error === 'isConnected failed' &&
      e.retries === 0
    )).toBe(true);
  });

  test('merges bundle hooks with core hooks correctly', async () => {
    const overrideHook = { override() {} };
    window.liveSocket = {
      isConnected: () => false,
      connect: vi.fn(),
      hooks: { ExistingHook: {} }
    };
    window.CoreHooks = { CoreHook1: {}, CoreHook2: {} };

    const bundleHooks = {
      BundleHook1: { mounted() {} },
      CoreHook2: overrideHook // Override core hook
    };

    await initializeBundle('test-bundle', bundleHooks);

    expect(window.liveSocket.hooks.CoreHook1).toBeDefined();
    expect(window.liveSocket.hooks.CoreHook2).toBe(overrideHook); // Should be overridden
    expect(window.liveSocket.hooks.BundleHook1).toBeDefined();
  });

  test('works with empty bundle hooks', async () => {
    window.liveSocket = {
      isConnected: () => false,
      connect: vi.fn(),
      hooks: {}
    };
    window.CoreHooks = { CoreHook1: {} };

    await initializeBundle('test-bundle'); // No hooks passed

    expect(window.liveSocket.hooks).toEqual({
      CoreHook1: {}
    });
  });

  test('emits telemetry with correct retry count on first success', async () => {
    window.liveSocket = {
      isConnected: () => false,
      connect: vi.fn(),
      hooks: {}
    };
    window.CoreHooks = { CoreHook1: {} };

    await initializeBundle('test-bundle', {});

    expect(telemetryEvents[0].retries).toBe(0);
  });
});

// Note: The "times out after max retries and shows error" test above already
// verifies that showBundleError displays a user-visible error message with the
// correct structure and content. Additional tests for flash-group placement
// would require complex async timer manipulation and don't add significant value.
