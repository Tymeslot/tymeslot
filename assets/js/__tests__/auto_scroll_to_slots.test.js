/**
 * Tests for `AutoScrollToSlots.manageFocus` (utility_hooks.js).
 *
 * When the slots region finishes loading, a keyboard/screen-reader user who
 * just activated a calendar day should be carried forward to the "Available
 * Times" heading. The hook must NOT steal focus on the initial page load or
 * while the user is interacting elsewhere — it only moves focus when the
 * currently-focused element is a calendar-day button (Quill's
 * `[data-testid="calendar-day"]` or Rhythm's `.week-day-cell`), and only
 * once per load (the `focusMoved` latch), resetting when the loaded marker
 * disappears (e.g. the user picks a date with no slots).
 */

import { describe, expect, test, afterEach } from 'vitest';
import { AutoScrollToSlots } from '../utility_hooks';

function makeHook(el) {
  return Object.assign(Object.create(AutoScrollToSlots), { el });
}

// Quill's `.time-slots-panel` — heading is `.slots-heading[tabindex="-1"]`;
// the loaded grid carries `[data-slots-loaded]` only once slots render.
function buildQuillContainer({ loaded } = {}) {
  const el = document.createElement('div');
  el.className = 'time-slots-panel';
  el.id = 'slots-container';

  const heading = document.createElement('h2');
  heading.className = 'slots-heading';
  heading.setAttribute('tabindex', '-1');
  el.appendChild(heading);

  if (loaded) {
    const grid = document.createElement('div');
    grid.setAttribute('data-slots-loaded', '');
    el.appendChild(grid);
  }

  document.body.appendChild(el);
  return { el, heading };
}

// Rhythm's `.time-slots-section` — heading is
// `.time-slots-section-heading[tabindex="-1"]`; the grid always renders and
// carries `data-slots-loaded` only once truthy.
function buildRhythmContainer({ loaded } = {}) {
  const el = document.createElement('div');
  el.className = 'time-slots-section';
  el.id = 'slots-container';

  const heading = document.createElement('h3');
  heading.className = 'time-slots-section-heading';
  heading.setAttribute('tabindex', '-1');
  el.appendChild(heading);

  const grid = document.createElement('div');
  grid.className = 'time-slots-grid';
  if (loaded) grid.setAttribute('data-slots-loaded', '');
  el.appendChild(grid);

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

  test('moves focus to the Quill heading when slots load after a calendar-day activation', () => {
    const day = makeCalendarDay();
    day.focus();

    const { el, heading } = buildQuillContainer({ loaded: true });
    const hook = makeHook(el);

    // Drive it the way LiveView does: mount, then let the observer tick fire.
    hook.mounted();
    hook.handleSlotsUpdate();

    expect(document.activeElement).toBe(heading);
  });

  test('moves focus to the Rhythm heading when slots load after a week-day-cell activation', () => {
    const day = makeWeekDayCell();
    day.focus();

    const { el, heading } = buildRhythmContainer({ loaded: true });
    const hook = makeHook(el);

    hook.mounted();
    hook.handleSlotsUpdate();

    expect(document.activeElement).toBe(heading);
  });

  test('the focusMoved latch blocks a second move on a later tick', () => {
    const day = makeCalendarDay();
    day.focus();

    const { el, heading } = buildQuillContainer({ loaded: true });
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

    const { el } = buildQuillContainer({ loaded: true });
    const hook = makeHook(el);

    hook.manageFocus();

    expect(document.activeElement).toBe(other);
  });

  test('does nothing while slots have not loaded, and the latch resets once the marker disappears', () => {
    const day = makeCalendarDay();
    day.focus();

    const { el, heading } = buildQuillContainer({ loaded: false });
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
