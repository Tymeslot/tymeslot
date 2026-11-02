/**
 * Tests for the `WeekGridScroll` hook (hooks/week_grid_scroll.js), which
 * keeps the day named in `data-reveal-date` in view in a narrow week grid
 * that scrolls sideways (`.week-grid__days`, `Shared.Components.WeekGrid`).
 *
 * jsdom does no layout, so each column's `offsetLeft`/`offsetWidth` and the
 * row's `clientWidth` are set by hand: seven 100px columns with a 10px gap,
 * in a 320px row that shows three of them.
 */

import { describe, expect, test, afterEach, vi } from 'vitest';
import { WeekGridScroll, revealLeft } from '../hooks/week_grid_scroll';

const WIDTH = 100;
const STEP = 110;
const ROW = 320;
const DATES = ['2027-06-07', '2027-06-08', '2027-06-09', '2027-06-10', '2027-06-11', '2027-06-12', '2027-06-13'];

const columnsAt = (count = 7) =>
  Array.from({ length: count }, (_, i) => ({ offsetLeft: i * STEP, offsetWidth: WIDTH }));

describe('revealLeft', () => {
  const columns = columnsAt();

  test('is null for a column already wholly in view', () => {
    expect(revealLeft({ scrollLeft: 0, clientWidth: ROW }, columns, 2)).toBeNull();
    expect(revealLeft({ scrollLeft: 2 * STEP, clientWidth: ROW }, columns, 3)).toBeNull();
  });

  test('scrolls back to a column before the view, putting it first', () => {
    expect(revealLeft({ scrollLeft: 3 * STEP, clientWidth: ROW }, columns, 1)).toBe(STEP);
  });

  test('scrolls on to a column past the view, landing on a column start that ends with it', () => {
    // Friday (index 4) past a view of Mon to Wed: the view starts at Wednesday.
    expect(revealLeft({ scrollLeft: 0, clientWidth: ROW }, columns, 4)).toBe(2 * STEP);
  });

  test('scrolls on to the last day without overshooting the row', () => {
    expect(revealLeft({ scrollLeft: 0, clientWidth: ROW }, columns, 6)).toBe(4 * STEP);
  });

  test('puts a column wider than the row at its start (one day in view)', () => {
    const wide = Array.from({ length: 7 }, (_, i) => ({ offsetLeft: i * 330, offsetWidth: 330 }));
    expect(revealLeft({ scrollLeft: 0, clientWidth: ROW }, wide, 3)).toBe(3 * 330);
  });

  test('ignores sub-pixel rounding at the edge', () => {
    expect(revealLeft({ scrollLeft: 0.5, clientWidth: ROW }, columns, 0)).toBeNull();
    expect(revealLeft({ scrollLeft: 0, clientWidth: ROW - 0.5 }, columns, 2)).toBeNull();
  });

  test('is null for a day the row does not hold', () => {
    expect(revealLeft({ scrollLeft: 0, clientWidth: ROW }, columns, -1)).toBeNull();
  });
});

function buildRow(revealDate) {
  const el = document.createElement('div');
  el.className = 'week-grid__days';
  if (revealDate) el.dataset.revealDate = revealDate;
  Object.defineProperty(el, 'clientWidth', { configurable: true, value: ROW });

  DATES.forEach((date, i) => {
    const day = document.createElement('section');
    day.className = 'week-grid__day';
    day.dataset.date = date;
    Object.defineProperty(day, 'offsetLeft', { configurable: true, value: i * STEP });
    Object.defineProperty(day, 'offsetWidth', { configurable: true, value: WIDTH });
    el.appendChild(day);
  });

  el.scrollTo = vi.fn(({ left }) => {
    el.scrollLeft = left;
  });

  document.body.appendChild(el);
  return el;
}

function mount(el) {
  const hook = Object.assign(Object.create(WeekGridScroll), { el });
  hook.mounted();
  return hook;
}

function setReducedMotion(reduce) {
  window.matchMedia = vi.fn().mockImplementation((query) => ({
    matches: reduce && query === '(prefers-reduced-motion: reduce)',
    media: query
  }));
}

describe('WeekGridScroll', () => {
  afterEach(() => {
    document.body.innerHTML = '';
    delete window.matchMedia;
  });

  test('on mount, brings the named day into view at once, without animating', () => {
    setReducedMotion(false);
    const el = buildRow('2027-06-11');

    mount(el);

    expect(el.scrollLeft).toBe(2 * STEP);
    expect(el.scrollTo).not.toHaveBeenCalled();
  });

  test('on mount, leaves a row whose named day is in view where it is', () => {
    const el = buildRow('2027-06-08');

    mount(el);

    expect(el.scrollLeft).toBe(0);
  });

  test('does nothing when no day is named', () => {
    const el = buildRow(null);

    mount(el);

    expect(el.scrollLeft).toBe(0);
    expect(el.scrollTo).not.toHaveBeenCalled();
  });

  test('glides to a newly named day on an update', () => {
    setReducedMotion(false);
    const el = buildRow('2027-06-07');
    const hook = mount(el);

    el.dataset.revealDate = '2027-06-13';
    hook.updated();

    expect(el.scrollTo).toHaveBeenCalledWith({ left: 4 * STEP, behavior: 'smooth' });
    expect(el.scrollLeft).toBe(4 * STEP);
  });

  test('jumps instead of gliding when the visitor asks for reduced motion', () => {
    setReducedMotion(true);
    const el = buildRow('2027-06-07');
    const hook = mount(el);

    el.dataset.revealDate = '2027-06-13';
    hook.updated();

    expect(el.scrollTo).not.toHaveBeenCalled();
    expect(el.scrollLeft).toBe(4 * STEP);
  });

  test('leaves a visitor browsing the row where they are while the named day stays the same', () => {
    setReducedMotion(false);
    const el = buildRow('2027-06-11');
    const hook = mount(el);

    // The visitor scrolls back to the start; a patch (a refetch of the week)
    // names the same day.
    el.scrollLeft = 0;
    hook.updated();

    expect(el.scrollLeft).toBe(0);
    expect(el.scrollTo).not.toHaveBeenCalled();
  });

  test('never scrolls the page', () => {
    const el = buildRow('2027-06-13');
    const scrollIntoView = vi.fn();
    Array.from(el.children).forEach((day) => {
      day.scrollIntoView = scrollIntoView;
    });
    const windowScroll = vi.spyOn(window, 'scrollTo').mockImplementation(() => {});

    mount(el);

    expect(scrollIntoView).not.toHaveBeenCalled();
    expect(windowScroll).not.toHaveBeenCalled();
    windowScroll.mockRestore();
  });
});
