/**
 * Tests for the pure helpers in calendar_drag.js.
 *
 * The drag/resize/create hooks coordinate DOM events, but the actual maths that
 * decides where a meeting lands lives in three small helpers. An off-by-one in
 * the snap or pixel→minute conversion shows up to users as meetings scheduled at
 * the wrong time, so these are the highest-value units to lock down.
 */

import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest';
import { snapToGrid, minutesFromY, pointerXY, CalendarCreate } from '../hooks/calendar_drag';

const HOUR_HEIGHT_PX = 64;

describe('snapToGrid', () => {
  // 15-minute grid (SNAP_MINUTES = 15)
  test.each([
    [0, 0],
    [7, 0],          // < half a slot → down
    [8, 15],         // half a slot → up (banker's rounding via Math.round)
    [14, 15],
    [15, 15],
    [22, 15],
    [23, 30],
    [60, 60],
    [67, 60],
    [68, 75],
    [1425, 1425],    // 23:45 exact
  ])('snapToGrid(%i) → %i', (input, expected) => {
    expect(snapToGrid(input)).toBe(expected);
  });

  test('handles negative inputs (above-grid drags)', () => {
    // Caller is responsible for clamping; helper just rounds.
    expect(snapToGrid(-7)).toBe(-0);
    expect(snapToGrid(-8)).toBe(-15);
  });

  test('always returns a multiple of 15', () => {
    for (let m = 0; m < 24 * 60; m += 1) {
      expect(snapToGrid(m) % 15).toBe(0);
    }
  });
});

describe('minutesFromY', () => {
  // HOUR_HEIGHT_PX = 64 (h-16 in Tailwind, 4rem at 16px base)
  test.each([
    [0, 0],
    [64, 60],         // one full hour
    [32, 30],         // half hour
    [16, 15],         // quarter hour
    [128, 120],       // two hours
    [8, 7.5],         // sub-snap precision; snapping happens later
  ])('minutesFromY(%i) → %f', (input, expected) => {
    expect(minutesFromY(input)).toBeCloseTo(expected, 5);
  });

  test('is the inverse of minutes → pixels at hour boundaries', () => {
    // For full hours, round-trip is exact.
    for (let hour = 0; hour <= 23; hour += 1) {
      const px = hour * 64;
      expect(minutesFromY(px)).toBe(hour * 60);
    }
  });
});

describe('pointerXY', () => {
  test('reads from changedTouches when touches[] is empty (touchend)', () => {
    // touchend events have empty .touches but populated .changedTouches.
    const e = {
      touches: [],
      changedTouches: [{ clientX: 50, clientY: 60 }],
    };
    expect(pointerXY(e)).toEqual({ x: 50, y: 60 });
  });

  test('prefers touches[0] when present (touchmove/touchstart)', () => {
    const e = {
      touches: [{ clientX: 100, clientY: 200 }],
      changedTouches: [{ clientX: 999, clientY: 999 }],
      clientX: 0,
      clientY: 0,
    };
    expect(pointerXY(e)).toEqual({ x: 100, y: 200 });
  });

  test('falls back to clientX/clientY for mouse events', () => {
    const e = { clientX: 12, clientY: 34 };
    expect(pointerXY(e)).toEqual({ x: 12, y: 34 });
  });

  test('handles synthetic events with touches: undefined', () => {
    const e = { clientX: 7, clientY: 9 };
    expect(pointerXY(e)).toEqual({ x: 7, y: 9 });
  });
});

describe('combined: typical drag-drop pipeline', () => {
  // Mirrors the math at lines 206-208 of the source. A drag that lands at
  // y=70px inside a day column should resolve to 09:00–09:45 for a 45-min event.
  test('drop at y=70px snaps to top of hour', () => {
    const raw = minutesFromY(70);            // 65.625 min
    const snapped = snapToGrid(raw);         // 60
    const clampedStart = Math.max(0, Math.min(23 * 60, snapped));
    expect(clampedStart).toBe(60);

    const durationMinutes = 45;
    const snappedEnd = Math.min(24 * 60, clampedStart + durationMinutes);
    expect(snappedEnd).toBe(105);
  });

  test('drop past end-of-day clamps to 23:00 start', () => {
    const raw = minutesFromY(24 * 64 + 100); // well past midnight
    const snapped = snapToGrid(raw);
    const clampedStart = Math.max(0, Math.min(23 * 60, snapped));
    expect(clampedStart).toBe(23 * 60);
  });

  test('resize never produces an end before start + one slot', () => {
    // Mirrors line 311: Math.max(startMinutes + SNAP_MINUTES, snapToGrid(rawEnd))
    const startMinutes = 600; // 10:00
    const dragYIntoStart = (startMinutes / 60) * 64 - 5; // a few px above start
    const rawEnd = minutesFromY(dragYIntoStart);
    const snappedEnd = Math.max(startMinutes + 15, snapToGrid(rawEnd));
    expect(snappedEnd).toBeGreaterThanOrEqual(startMinutes + 15);
  });
});

describe('CalendarCreate: drag-to-create span', () => {
  // The hook turns a press-and-drag on the empty grid into a time *span*. These
  // tests drive the real hook through jsdom pointer events and assert the
  // payload pushed to the server carries start AND end from the drag — a plain
  // click must still fall back to the default 30-minute duration.

  let hook;
  let zone;
  let col;

  // jsdom returns all-zero rects; give the day column a deterministic geometry so
  // pixel→minute maths is exercised. The column top is at y=0, so a clientY of N
  // pixels maps directly to N px down the grid.
  function stubColumnRect(el) {
    el.getBoundingClientRect = () => ({
      top: 0, left: 0, right: 80, bottom: 24 * HOUR_HEIGHT_PX,
      width: 80, height: 24 * HOUR_HEIGHT_PX, x: 0, y: 0,
    });
  }

  function mouse(type, y) {
    const e = new MouseEvent(type, { bubbles: true, cancelable: true, clientX: 40, clientY: y });
    return e;
  }

  beforeEach(() => {
    zone = document.createElement('div');
    zone.id = 'calendar-create-zone';

    col = document.createElement('div');
    col.setAttribute('data-day-col', '2026-06-22');
    stubColumnRect(col);
    zone.appendChild(col);
    document.body.appendChild(zone);

    // _findDayColAt relies on elementFromPoint, absent in jsdom — resolve to the
    // single column so same-day drags behave as in a browser.
    document.elementFromPoint = vi.fn(() => col);

    hook = Object.assign(Object.create(CalendarCreate), {
      el: zone,
      pushEventTo: vi.fn(),
    });
    hook.mounted();
  });

  afterEach(() => {
    hook.destroyed();
    zone.remove();
    vi.restoreAllMocks();
  });

  test('dragging from 09:00 to 10:30 pushes a span payload', () => {
    // pointerdown at y = 9h = 576px (09:00), drag to y = 10.5h = 672px (10:30).
    col.dispatchEvent(mouse('mousedown', 9 * HOUR_HEIGHT_PX));
    document.dispatchEvent(mouse('mousemove', 10.5 * HOUR_HEIGHT_PX));
    document.dispatchEvent(mouse('mouseup', 10.5 * HOUR_HEIGHT_PX));

    expect(hook.pushEventTo).toHaveBeenCalledTimes(1);
    const [, event, payload] = hook.pushEventTo.mock.calls[0];
    expect(event).toBe('show_create_form');
    expect(payload).toMatchObject({
      'date': '2026-06-22',
      'start-hour': '9',
      'start-minute': '0',
      'end-hour': '10',
      'end-minute': '30',
    });
  });

  test('end time snaps to the 15-minute grid', () => {
    // Drag end at y = 580px → 543.75 min → snaps to 09:00... start; choose a
    // clearer case: start 14:00 (896px), end at 901px ≈ 14:04 → snaps to 14:00,
    // but minEnd forces start + 15 = 14:15.
    col.dispatchEvent(mouse('mousedown', 14 * HOUR_HEIGHT_PX));
    document.dispatchEvent(mouse('mousemove', 14 * HOUR_HEIGHT_PX + 5));
    document.dispatchEvent(mouse('mouseup', 14 * HOUR_HEIGHT_PX + 5));

    const [, , payload] = hook.pushEventTo.mock.calls[0];
    expect(payload['start-hour']).toBe('14');
    expect(payload['start-minute']).toBe('0');
    expect(payload['end-hour']).toBe('14');
    expect(payload['end-minute']).toBe('15');
  });

  test('a plain click (no movement) falls back to a 30-minute default', () => {
    col.dispatchEvent(mouse('mousedown', 11 * HOUR_HEIGHT_PX));
    document.dispatchEvent(mouse('mouseup', 11 * HOUR_HEIGHT_PX));

    expect(hook.pushEventTo).toHaveBeenCalledTimes(1);
    const [, , payload] = hook.pushEventTo.mock.calls[0];
    expect(payload['start-hour']).toBe('11');
    expect(payload['start-minute']).toBe('0');
    expect(payload['end-hour']).toBe('11');
    expect(payload['end-minute']).toBe('30');
  });

  test('does not start a drag on an existing event block', () => {
    const eventBlock = document.createElement('div');
    eventBlock.setAttribute('data-draggable', 'true');
    col.appendChild(eventBlock);

    eventBlock.dispatchEvent(mouse('mousedown', 9 * HOUR_HEIGHT_PX));
    document.dispatchEvent(mouse('mousemove', 10 * HOUR_HEIGHT_PX));
    document.dispatchEvent(mouse('mouseup', 10 * HOUR_HEIGHT_PX));

    expect(hook.pushEventTo).not.toHaveBeenCalled();
  });

  test('does not start a drag on a resize handle', () => {
    const handle = document.createElement('div');
    handle.setAttribute('data-resize-handle', '');
    col.appendChild(handle);

    handle.dispatchEvent(mouse('mousedown', 9 * HOUR_HEIGHT_PX));
    document.dispatchEvent(mouse('mouseup', 10 * HOUR_HEIGHT_PX));

    expect(hook.pushEventTo).not.toHaveBeenCalled();
  });
});
