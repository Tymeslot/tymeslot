/**
 * Tests for the `AgendaCountdown` hook (agenda_countdown.js).
 *
 * Covers two regressions:
 *  - sub-second boundary: with under a second to go, the hook must render
 *    the "now" template, not flip backwards to "in 1m".
 *  - `updated()` must re-read the `data-tpl-*` attributes rather than reuse
 *    the templates cached at mount, since `phx-update="ignore"` still lets
 *    LiveView merge `data-*` attributes on the element.
 */

import { describe, expect, test, afterEach, vi } from 'vitest';
import { AgendaCountdown } from '../hooks/agenda_countdown';

function makeHook(el) {
  return Object.assign(Object.create(AgendaCountdown), { el });
}

function buildEl({ start, end, join } = {}) {
  const el = document.createElement('time');
  el.dataset.start = start;
  el.dataset.end = end;
  el.dataset.tplNow = 'now';
  el.dataset.tplMinutes = 'in __N__m';
  el.dataset.tplHours = 'in __N__h';
  el.dataset.tplDays = 'in __N__d';
  if (join) el.dataset.join = join;
  document.body.appendChild(el);
  return el;
}

afterEach(() => {
  document.body.innerHTML = '';
  vi.useRealTimers();
});

describe('AgendaCountdown mounted()', () => {
  test('renders the "now" template when under a second remains, not "in 1m"', () => {
    const now = Date.now();
    const el = buildEl({
      start: new Date(now + 500).toISOString(),
      end: new Date(now + 60_000).toISOString(),
    });
    const hook = makeHook(el);

    hook.mounted();
    hook.destroyed();

    expect(el.textContent).toBe('now');
  });

  test('still renders "in 1m" once a full second remains', () => {
    const now = Date.now();
    const el = buildEl({
      start: new Date(now + 1500).toISOString(),
      end: new Date(now + 60_000).toISOString(),
    });
    const hook = makeHook(el);

    hook.mounted();
    hook.destroyed();

    expect(el.textContent).toBe('in 1m');
  });
});

describe('AgendaCountdown updated()', () => {
  test('re-reads data-tpl-* attributes rather than reusing the mount-time cache', () => {
    vi.useFakeTimers();
    const now = Date.now();
    const el = buildEl({
      start: new Date(now + 5 * 60_000).toISOString(),
      end: new Date(now + 65 * 60_000).toISOString(),
    });
    const hook = makeHook(el);

    hook.mounted();
    expect(el.textContent).toBe('in 5m');

    // Simulate LiveView merging new data-* attributes onto the
    // phx-update="ignore" element (e.g. a locale change).
    el.dataset.tplMinutes = 'dans __N__m';
    hook.updated();

    expect(el.textContent).toBe('dans 5m');

    hook.destroyed();
  });
});
