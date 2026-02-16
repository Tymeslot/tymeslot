/**
 * Tests for Dynamic Hook Loader
 *
 * Test Coverage:
 * - Hook loading and caching
 * - Error handling and recovery
 * - Lifecycle management (mount, update, destroy)
 * - Race conditions and edge cases
 */

import { lazyHook, loadHook } from '../dynamic_hooks';
import { beforeEach, afterEach, describe, expect, test, vi } from 'vitest';

describe('loadHook', () => {
  // Suppress console.error for tests that intentionally trigger errors
  let consoleErrorSpy;

  beforeEach(() => {
    consoleErrorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
  });

  afterEach(() => {
    consoleErrorSpy.mockRestore();
  });

  test('loads hook module and caches result', async () => {
    const mockHook = { mounted() {}, updated() {} };
    const mockModule = { default: mockHook };
    const loader = vi.fn(() => Promise.resolve(mockModule));

    // Use unique name to avoid cache interference
    const uniqueName = 'TestHookCache' + Date.now();
    const hook1 = await loadHook(uniqueName, loader);
    const hook2 = await loadHook(uniqueName, loader);

    expect(hook1).toBe(mockHook);
    expect(hook2).toBe(mockHook);
    expect(loader).toHaveBeenCalledTimes(1); // Only loaded once, then cached
  });

  test('uses default export when available', async () => {
    const defaultExport = { mounted() {} };
    const mockModule = { default: defaultExport, SomeOtherExport: { other() {} } };
    const loader = () => Promise.resolve(mockModule);

    const uniqueName = 'TestHookDefault' + Date.now();
    const hook = await loadHook(uniqueName, loader);
    expect(hook).toBe(defaultExport);
  });

  test('falls back to named export when default is null/undefined', async () => {
    const namedExport = { mounted() {} };
    const uniqueName = 'TestHookNamed' + Date.now();
    const mockModule = { default: null, [uniqueName]: namedExport };
    const loader = () => Promise.resolve(mockModule);

    const hook = await loadHook(uniqueName, loader);
    expect(hook).toBe(namedExport);
  });

  test('falls back to module itself when neither default nor named export exists', async () => {
    const mockModule = { mounted() {}, updated() {} };
    const loader = () => Promise.resolve(mockModule);

    const uniqueName = 'TestHookModule' + Date.now();
    const hook = await loadHook(uniqueName, loader);
    expect(hook).toBe(mockModule);
  });

  test('throws error when loader returns null/undefined', async () => {
    const uniqueName = 'TestHookNull' + Date.now();
    // Loader returns null directly (not a module object)
    const loader = () => Promise.resolve(null);

    // Will throw "Cannot read properties of null" when trying to access .default
    await expect(loadHook(uniqueName, loader)).rejects.toThrow();
  });

  test('handles loading errors gracefully', async () => {
    const error = new Error('Network error');
    const loader = () => Promise.reject(error);

    const uniqueName = 'TestHookError' + Date.now();
    await expect(loadHook(uniqueName, loader)).rejects.toThrow('Network error');
  });

  test('deduplicates concurrent loading requests', async () => {
    let resolveLoader;
    const loaderPromise = new Promise(resolve => { resolveLoader = resolve; });
    const loader = vi.fn(() => loaderPromise);

    const uniqueName = 'TestHookConcurrent' + Date.now();

    // Start two concurrent loads
    const promise1 = loadHook(uniqueName, loader);
    const promise2 = loadHook(uniqueName, loader);

    // Resolve loader
    const mockHook = { mounted() {} };
    const mockModule = { default: mockHook };
    resolveLoader(mockModule);

    const [hook1, hook2] = await Promise.all([promise1, promise2]);

    expect(hook1).toBe(mockHook);
    expect(hook2).toBe(mockHook);
    expect(loader).toHaveBeenCalledTimes(1); // Only one actual load
  });
});

describe('lazyHook', () => {
  let mockElement;
  let telemetryEvents;
  let consoleErrorSpy;
  let consoleDebugSpy;
  let consoleWarnSpy;
  let telemetryListener;

  beforeEach(() => {
    mockElement = document.createElement('div');
    telemetryEvents = [];

    // Suppress console output for cleaner test results
    consoleErrorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
    consoleDebugSpy = vi.spyOn(console, 'debug').mockImplementation(() => {});
    consoleWarnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});

    // Capture telemetry events
    telemetryListener = (e) => {
      telemetryEvents.push(e.detail);
    };
    window.addEventListener('tymeslot:hook:loaded', telemetryListener);
  });

  afterEach(() => {
    consoleErrorSpy.mockRestore();
    consoleDebugSpy.mockRestore();
    consoleWarnSpy.mockRestore();
    window.removeEventListener('tymeslot:hook:loaded', telemetryListener);
  });

  test('loads hook on first mount and calls mounted lifecycle', async () => {
    const mockHook = {
      mounted: vi.fn(),
      updated: vi.fn(),
      destroyed: vi.fn()
    };
    const loader = () => Promise.resolve({ default: mockHook });

    const uniqueName = 'TestHookMount' + Date.now();
    const lazy = lazyHook(uniqueName, loader);

    // Set up LiveView context
    lazy.el = mockElement;
    lazy.pushEvent = vi.fn();
    lazy.pushEventTo = vi.fn();
    lazy.handleEvent = vi.fn();

    await lazy.mounted();

    expect(mockHook.mounted).toHaveBeenCalledTimes(1);
    expect(telemetryEvents.some(e => e.hook === uniqueName && e.success === true)).toBe(true);
  });

  test('prevents duplicate initialization if mounted multiple times during load', async () => {
    let resolveLoader;
    const loaderPromise = new Promise(resolve => { resolveLoader = resolve; });
    const mockHook = { mounted: vi.fn() };
    const loader = () => loaderPromise;

    const uniqueName = 'TestHookDupe' + Date.now();
    const lazy = lazyHook(uniqueName, loader);
    lazy.el = mockElement;
    lazy.pushEvent = vi.fn();
    lazy.pushEventTo = vi.fn();
    lazy.handleEvent = vi.fn();

    // Call mounted twice before loader resolves
    const mount1 = lazy.mounted();
    const mount2 = lazy.mounted(); // Should skip with warning

    // Resolve loader
    resolveLoader({ default: mockHook });
    await Promise.all([mount1, mount2]);

    expect(mockHook.mounted).toHaveBeenCalledTimes(1); // Only once, not twice
  });

  test('aborts initialization if destroyed during loading', async () => {
    let resolveLoader;
    const loaderPromise = new Promise(resolve => { resolveLoader = resolve; });
    const mockHook = { mounted: vi.fn(), destroyed: vi.fn() };
    const loader = () => loaderPromise;

    const uniqueName = 'TestHookAbort' + Date.now();
    const lazy = lazyHook(uniqueName, loader);
    lazy.el = mockElement;
    lazy.pushEvent = vi.fn();
    lazy.pushEventTo = vi.fn();
    lazy.handleEvent = vi.fn();

    // Start loading
    const mountPromise = lazy.mounted();

    // Destroy before loading completes
    lazy.destroyed();

    // Resolve loader
    resolveLoader({ default: mockHook });
    await mountPromise;

    // Hook should not be initialized since it was destroyed
    expect(mockHook.mounted).not.toHaveBeenCalled();
  });

  test('transfers LiveView context to actual hook', async () => {
    const mockHook = { mounted: vi.fn() };
    const loader = () => Promise.resolve({ default: mockHook });

    const uniqueName = 'TestHookContext' + Date.now();
    const lazy = lazyHook(uniqueName, loader);

    const mockPushEvent = vi.fn();
    lazy.el = mockElement;
    lazy.pushEvent = mockPushEvent;
    lazy.pushEventTo = vi.fn();
    lazy.handleEvent = vi.fn();
    lazy.upload = vi.fn();
    lazy.uploadTo = vi.fn();

    await lazy.mounted();

    expect(mockHook.el).toBe(mockElement);
    expect(typeof mockHook.pushEvent).toBe('function');
    expect(typeof mockHook.upload).toBe('function');
    expect(typeof mockHook.uploadTo).toBe('function');
  });

  test('handles loading errors and emits telemetry', async () => {
    const error = new Error('Load failed');
    const loader = () => Promise.reject(error);

    const uniqueName = 'TestHookError' + Date.now();
    const lazy = lazyHook(uniqueName, loader);
    const mockPushEvent = vi.fn();
    lazy.el = mockElement;
    lazy.pushEvent = mockPushEvent;
    lazy.pushEventTo = vi.fn();
    lazy.handleEvent = vi.fn();

    await lazy.mounted();

    expect(telemetryEvents.some(e =>
      e.hook === uniqueName &&
      e.success === false &&
      e.error === 'Load failed'
    )).toBe(true);

    expect(mockPushEvent).toHaveBeenCalledWith('hook-load-error', {
      hook: uniqueName,
      error: 'Load failed'
    });
  });

  test('silently skips lifecycle calls when hook failed to load', async () => {
    const loader = () => Promise.reject(new Error('Load failed'));

    const uniqueName = 'TestHookSkip' + Date.now();
    const lazy = lazyHook(uniqueName, loader);
    lazy.el = mockElement;
    lazy.pushEvent = vi.fn();
    lazy.pushEventTo = vi.fn();
    lazy.handleEvent = vi.fn();

    await lazy.mounted();

    // Should not throw even though hook failed to load
    expect(() => {
      lazy.updated();
      lazy.disconnected();
      lazy.reconnected();
      lazy.destroyed();
    }).not.toThrow();
  });

  test('validates that loaded hook is an object', async () => {
    const loader = () => Promise.resolve({ default: 'not-an-object' });

    const uniqueName = 'TestHookInvalid' + Date.now();
    const lazy = lazyHook(uniqueName, loader);
    lazy.el = mockElement;
    lazy.pushEvent = vi.fn();
    lazy.pushEventTo = vi.fn();
    lazy.handleEvent = vi.fn();

    await lazy.mounted();

    expect(telemetryEvents.some(e =>
      e.hook === uniqueName &&
      e.success === false &&
      e.error && e.error.includes('Invalid hook module')
    )).toBe(true);
  });

  test('cleans up references on destroy to prevent memory leaks', async () => {
    const mockHook = { mounted: vi.fn(), destroyed: vi.fn() };
    const loader = () => Promise.resolve({ default: mockHook });

    const uniqueName = 'TestHookCleanup' + Date.now();
    const lazy = lazyHook(uniqueName, loader);
    lazy.el = mockElement;
    lazy.pushEvent = vi.fn();
    lazy.pushEventTo = vi.fn();
    lazy.handleEvent = vi.fn();

    await lazy.mounted();
    expect(lazy.__actualHook).toBeTruthy();

    lazy.destroyed();

    expect(lazy.__actualHook).toBeNull();
    expect(mockHook.destroyed).toHaveBeenCalledTimes(1);
  });
});
