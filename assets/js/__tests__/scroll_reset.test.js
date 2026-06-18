/**
 * Tests for the scroll-to-top behaviour in utility_hooks.js.
 *
 * Two regressions are guarded here:
 *
 *  1. The page scroll container is <body>, not the window (base.css forces it
 *     via `html, body { height: 100% }` + `overflow-x: hidden`). A reset that
 *     only calls `window.scrollTo` silently does nothing — so we assert that
 *     documentElement AND body scroll are reset too.
 *
 *  2. The global `phx:navigate` listener must scroll to top on forward
 *     `navigate` redirects only — never on patches (filters/tabs/steps) or
 *     back/forward (`pop`), which must keep their scroll position.
 */

import { describe, expect, test, vi, beforeEach } from 'vitest';
import {
  ScrollReset,
  scrollPageToTop,
  shouldScrollToTopOnNavigate,
} from '../utility_hooks';

// Replace the three scroll roots with spies so we can observe writes without
// depending on jsdom's (stubbed) scrollTop layout behaviour.
function spyScrollRoots() {
  const writes = { window: [], documentElement: [], body: [] };
  window.scrollTo = vi.fn((arg) => writes.window.push(arg));
  Object.defineProperty(document.documentElement, 'scrollTop', {
    configurable: true,
    get: () => 0,
    set: (v) => writes.documentElement.push(v),
  });
  Object.defineProperty(document.body, 'scrollTop', {
    configurable: true,
    get: () => 0,
    set: (v) => writes.body.push(v),
  });
  return writes;
}

describe('scrollPageToTop', () => {
  test('resets every scroll root, not just the window', () => {
    const writes = spyScrollRoots();

    scrollPageToTop();

    expect(window.scrollTo).toHaveBeenCalledWith({ top: 0, behavior: 'instant' });
    expect(writes.documentElement).toEqual([0]);
    expect(writes.body).toEqual([0]); // the body-scroller case — the original bug
  });
});

describe('shouldScrollToTopOnNavigate', () => {
  test('true for a forward navigate redirect', () => {
    expect(shouldScrollToTopOnNavigate({ pop: false, patch: false })).toBe(true);
    // pop/patch absent (forward redirect) behaves the same
    expect(shouldScrollToTopOnNavigate({})).toBe(true);
  });

  test('false for back/forward (pop) navigation — scroll is restored', () => {
    expect(shouldScrollToTopOnNavigate({ pop: true, patch: false })).toBe(false);
  });

  test('false for patch navigation — scroll position is preserved', () => {
    expect(shouldScrollToTopOnNavigate({ pop: false, patch: true })).toBe(false);
  });
});

describe('ScrollReset.scrollToTop', () => {
  let writes;

  beforeEach(() => {
    writes = spyScrollRoots();
  });

  test('full-page view (data-scroll-window) scrolls the whole page', () => {
    const el = document.createElement('div');
    el.dataset.scrollWindow = 'true';

    ScrollReset.scrollToTop.call({ el });

    expect(window.scrollTo).toHaveBeenCalledOnce();
    expect(writes.body).toEqual([0]);
  });

  test('inner scroll container resets only its own scrollTop', () => {
    const el = document.createElement('div');
    // No data-scroll-window, and the element genuinely overflows.
    Object.defineProperty(el, 'scrollHeight', { value: 1000 });
    Object.defineProperty(el, 'clientHeight', { value: 400 });
    const elWrites = [];
    Object.defineProperty(el, 'scrollTop', {
      configurable: true,
      get: () => 0,
      set: (v) => elWrites.push(v),
    });

    ScrollReset.scrollToTop.call({ el });

    expect(elWrites).toEqual([0]);
    expect(window.scrollTo).not.toHaveBeenCalled();
    expect(writes.body).toEqual([]);
  });
});

describe('ScrollReset lifecycle', () => {
  test('mounted scrolls to top and records the current action', () => {
    const el = document.createElement('div');
    el.dataset.action = 'pricing';
    const ctx = { el, scrollToTop: vi.fn() };

    ScrollReset.mounted.call(ctx);

    expect(ctx.scrollToTop).toHaveBeenCalledOnce();
    expect(ctx.currentAction).toBe('pricing');
  });

  test('updated scrolls only when the action changes', () => {
    const el = document.createElement('div');
    el.dataset.action = 'docs-intro';
    const ctx = { el, currentAction: 'docs-intro', scrollToTop: vi.fn() };

    // Same action (e.g. an unrelated patch) — must not scroll.
    ScrollReset.updated.call(ctx);
    expect(ctx.scrollToTop).not.toHaveBeenCalled();

    // Action changes (navigated to a different doc) — scroll and remember it.
    el.dataset.action = 'docs-themes';
    ScrollReset.updated.call(ctx);
    expect(ctx.scrollToTop).toHaveBeenCalledOnce();
    expect(ctx.currentAction).toBe('docs-themes');
  });
});
