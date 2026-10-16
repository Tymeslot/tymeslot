/**
 * Tests for `AutoScrollToSlots` (utility_hooks.js): `manageFocus` and the
 * mobile/tablet auto-scroll driven by its MutationObserver.
 *
 * When the slots region finishes loading, a keyboard/screen-reader user who
 * just activated a calendar day should be carried forward to the "Available
 * Times" heading (`.slot-list__heading`). The hook must NOT steal focus on
 * the initial page load or while the user is interacting elsewhere — it only
 * moves focus when the currently-focused element is a calendar-day button
 * (Quill's `[data-testid="calendar-day"]` or Rhythm's `.week-day-cell`), and
 * only once per load (the `focusMoved` latch), resetting when the loaded marker
 * disappears (e.g. the user picks a date with no slots).
 *
 * The auto-scroll observes `childList`/`subtree` mutations under the slots
 * container, which also fire for DOM churn unrelated to a new slots view —
 * notably the two-tier hour picker's minutes panel expanding/collapsing.
 * `data-slots-loaded` carries the selected date once slots render (e.g.
 * `data-slots-loaded="2026-09-01"`), and the hook keys its "did the view
 * actually change" check off that value, not off the mutation firing at all.
 */

import { describe, expect, test, afterEach, beforeEach, vi } from 'vitest';
import { AutoScrollToSlots } from '../utility_hooks';

function makeHook(el) {
  return Object.assign(Object.create(AutoScrollToSlots), { el });
}

// The shared slot list (`Shared.Components.SlotList`): `#slots-container`,
// a `.slot-list__heading[tabindex="-1"]` at the theme's heading level, and,
// once slots render, a `.slot-list__groups` carrying `data-slots-loaded` set to
// the selected date (e.g. "2026-09-01"). `loaded` may be `true` (bare
// attribute), a date string, or falsy (not yet loaded).
function buildSlotList({ loaded, headingTag = 'h2' } = {}) {
  const el = document.createElement('div');
  el.className = 'slot-list';
  el.id = 'slots-container';

  const heading = document.createElement(headingTag);
  heading.className = 'slot-list__heading';
  heading.setAttribute('tabindex', '-1');
  el.appendChild(heading);

  const body = document.createElement('div');
  body.className = 'slot-list__body';
  el.appendChild(body);

  if (loaded) {
    const groups = document.createElement('div');
    groups.className = 'slot-list__groups';
    groups.setAttribute('data-slots-loaded', loaded === true ? '' : loaded);
    body.appendChild(groups);
  }

  document.body.appendChild(el);
  return { el, heading };
}

function makeCalendarDay() {
  const day = document.createElement('button');
  day.setAttribute('data-testid', 'calendar-day');
  document.body.appendChild(day);
  return day;
}

function makeWeekDayCell() {
  const day = document.createElement('button');
  day.className = 'week-day-cell';
  document.body.appendChild(day);
  return day;
}

describe('AutoScrollToSlots.manageFocus', () => {
  afterEach(() => {
    document.body.innerHTML = '';
  });

  test('moves focus to the heading when slots load after a calendar-day activation', () => {
    const day = makeCalendarDay();
    day.focus();

    const { el, heading } = buildSlotList({ loaded: true });
    const hook = makeHook(el);

    // Drive it the way LiveView does: mount, then let the observer tick fire.
    hook.mounted();
    hook.handleSlotsUpdate();

    expect(document.activeElement).toBe(heading);
  });

  test('moves focus to an h3 heading when slots load after a week-day-cell activation', () => {
    const day = makeWeekDayCell();
    day.focus();

    const { el, heading } = buildSlotList({ loaded: true, headingTag: 'h3' });
    const hook = makeHook(el);

    hook.mounted();
    hook.handleSlotsUpdate();

    expect(document.activeElement).toBe(heading);
  });

  test('the focusMoved latch blocks a second move on a later tick', () => {
    const day = makeCalendarDay();
    day.focus();

    const { el, heading } = buildSlotList({ loaded: true });
    const hook = makeHook(el);

    hook.manageFocus();
    expect(document.activeElement).toBe(heading);

    // A later mutation tick re-focuses a day cell while slots are still
    // loaded (e.g. an unrelated re-render) — the latch must not steal focus
    // back to the heading a second time.
    day.focus();
    hook.manageFocus();

    expect(document.activeElement).toBe(day);
  });

  test('does not move focus when the active element is not a calendar day', () => {
    const other = document.createElement('button');
    document.body.appendChild(other);
    other.focus();

    const { el } = buildSlotList({ loaded: true });
    const hook = makeHook(el);

    hook.manageFocus();

    expect(document.activeElement).toBe(other);
  });

  test('does nothing while slots have not loaded, and the latch resets once the marker disappears', () => {
    const day = makeCalendarDay();
    day.focus();

    const { el, heading } = buildSlotList({ loaded: false });
    const hook = makeHook(el);

    hook.manageFocus();
    expect(document.activeElement).toBe(day);
    expect(hook.focusMoved).toBeFalsy();

    // Slots load — focus moves and the latch engages.
    const grid = document.createElement('div');
    grid.setAttribute('data-slots-loaded', '');
    el.appendChild(grid);
    hook.manageFocus();
    expect(document.activeElement).toBe(heading);
    expect(hook.focusMoved).toBe(true);

    // The loaded marker disappears again (e.g. the user picked a new date
    // with no slots) — the latch must reset so the next load can move focus.
    grid.remove();
    hook.manageFocus();
    expect(hook.focusMoved).toBe(false);
  });
});

describe('AutoScrollToSlots auto-scroll', () => {
  const MOBILE_WIDTH = 500;

  beforeEach(() => {
    vi.stubGlobal('innerWidth', MOBILE_WIDTH);
    vi.useFakeTimers();
    Element.prototype.scrollIntoView = vi.fn();
  });

  afterEach(() => {
    vi.runOnlyPendingTimers();
    vi.useRealTimers();
    vi.unstubAllGlobals();
    document.body.innerHTML = '';
  });

  test('picking a new date scrolls once slots are loaded', () => {
    const { el } = buildSlotList({ loaded: false });
    const hook = makeHook(el);
    hook.mounted();

    // The date pick lands: the loaded grid appears, carrying the date.
    const grid = document.createElement('div');
    grid.setAttribute('data-slots-loaded', '2026-09-01');
    el.appendChild(grid);
    hook.handleSlotsUpdate();
    vi.advanceTimersByTime(100);

    expect(el.scrollIntoView).toHaveBeenCalledOnce();
  });

  test('expanding an hour does not scroll — the loaded date is unchanged', () => {
    const { el } = buildSlotList({ loaded: '2026-09-01' });
    const hook = makeHook(el);
    hook.mounted();

    // Two-tier picker: tapping an hour adds a minutes panel under the
    // already-loaded grid without touching `data-slots-loaded`.
    const grid = el.querySelector('[data-slots-loaded]');
    const minutesPanel = document.createElement('div');
    minutesPanel.className = 'slot-list__grid slot-list__grid--minutes';
    grid.appendChild(minutesPanel);
    hook.handleSlotsUpdate();
    vi.advanceTimersByTime(100);

    expect(el.scrollIntoView).not.toHaveBeenCalled();

    // Tapping the hour again to collapse it removes the panel — still the
    // same loaded date, still no scroll.
    minutesPanel.remove();
    hook.handleSlotsUpdate();
    vi.advanceTimersByTime(100);

    expect(el.scrollIntoView).not.toHaveBeenCalled();
  });

  test('picking a different date after one is already loaded scrolls again', () => {
    const { el } = buildSlotList({ loaded: '2026-09-01' });
    const hook = makeHook(el);
    hook.mounted();

    const grid = el.querySelector('[data-slots-loaded]');
    grid.setAttribute('data-slots-loaded', '2026-09-02');
    hook.handleSlotsUpdate();
    vi.advanceTimersByTime(100);

    expect(el.scrollIntoView).toHaveBeenCalledOnce();
  });

  test('does not scroll when embedded, even for a genuinely new date', () => {
    document.documentElement.setAttribute('data-embedded', 'true');

    const { el } = buildSlotList({ loaded: false });
    const hook = makeHook(el);
    hook.mounted();

    const grid = document.createElement('div');
    grid.setAttribute('data-slots-loaded', '2026-09-01');
    el.appendChild(grid);
    hook.handleSlotsUpdate();
    vi.advanceTimersByTime(100);

    expect(el.scrollIntoView).not.toHaveBeenCalled();

    document.documentElement.removeAttribute('data-embedded');
  });
});
