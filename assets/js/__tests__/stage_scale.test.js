/**
 * Tests for the `StageScale` hook (hooks/stage_scale.js), which fits the
 * onboarding stage's 400px page miniature to its frame and reserves the
 * scaled height.
 */

import { describe, expect, test, afterEach, vi } from 'vitest';
import { StageScale, stageScale, heightForPage, focusShift } from '../hooks/stage_scale';

describe('stageScale', () => {
  test('fills a narrow frame below lg', () => {
    expect(stageScale({ width: 300, wide: false })).toBe(0.75);
  });

  test('never grows past the design size below lg', () => {
    expect(stageScale({ width: 700, wide: false })).toBe(1);
  });

  test('grows to fill the frame from lg', () => {
    expect(stageScale({ width: 440, wide: true })).toBe(1.1);
  });

  test('stops at 1.2 from lg', () => {
    expect(stageScale({ width: 900, wide: true })).toBe(1.2);
  });

  test('shrinks so the whole page fits the height left for it', () => {
    expect(stageScale({ width: 900, wide: true, availableHeight: 550, innerHeight: 550 })).toBe(1);
  });

  test('is 1 while the frame has no width', () => {
    expect(stageScale({ width: 0, wide: true })).toBe(1);
  });
});

describe('heightForPage', () => {
  test('takes off what the box holds besides the page', () => {
    // A frame from 48 to 648 holding a 556px page (so 44px of browser bar),
    // then a 16px gap and a 40px caption: 100px of chrome.
    const frame = { top: 48, bottom: 648 };
    const caption = { top: 664, bottom: 704 };

    expect(heightForPage(704, [frame, caption], 556)).toBe(604);
  });

  test('leaves the height unbounded with nothing to measure', () => {
    expect(heightForPage(704, [], 556)).toBe(Infinity);
  });
});

describe('focusShift', () => {
  test('leaves a region already in view where it is', () => {
    expect(focusShift({ viewport: 300, top: 100, bottom: 250, pageHeight: 600 })).toBe(0);
  });

  test('shifts just enough to show the bottom of a region below the card', () => {
    expect(focusShift({ viewport: 300, top: 250, bottom: 450, pageHeight: 600 })).toBe(162);
  });

  test('never cuts the top of a region taller than the card', () => {
    expect(focusShift({ viewport: 300, top: 250, bottom: 700, pageHeight: 800 })).toBe(238);
  });

  test('never shifts past the end of the page', () => {
    expect(focusShift({ viewport: 300, top: 500, bottom: 590, pageHeight: 600 })).toBe(300);
  });
});

function build({ width, innerHeight }) {
  const el = document.createElement('div');
  const inner = document.createElement('div');
  el.appendChild(inner);
  document.body.appendChild(el);

  Object.defineProperty(el, 'clientWidth', { value: width, configurable: true });
  Object.defineProperty(inner, 'offsetHeight', { value: innerHeight, configurable: true });
  return { el, inner };
}

function mount(el, { wide }) {
  window.matchMedia = vi.fn(() => ({
    matches: wide,
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
  }));

  const hook = Object.assign(Object.create(StageScale), { el });
  hook.mounted();
  return hook;
}

describe('StageScale hook', () => {
  afterEach(() => {
    document.body.innerHTML = '';
  });

  test('sets the scale and reserves the scaled height', () => {
    const { el } = build({ width: 300, innerHeight: 500 });
    mount(el, { wide: false });

    expect(el.style.getPropertyValue('--stage-scale')).toBe('0.75');
    expect(el.style.height).toBe('375px');
  });

  test('refits after an update changes the page height', () => {
    const { el, inner } = build({ width: 800, innerHeight: 400 });
    const hook = mount(el, { wide: true });
    expect(el.style.height).toBe('480px');

    Object.defineProperty(inner, 'offsetHeight', { value: 500, configurable: true });
    hook.updated();

    expect(el.style.height).toBe('600px');
  });

  // A phone card 300px tall holding a 600px page whose focused region runs
  // from 350 to 450.
  function buildCard({ focus }) {
    const card = document.createElement('div');
    card.className = 'stage-frame-body';
    const { el, inner } = build({ width: 400, innerHeight: 600 });
    card.appendChild(el);
    document.body.appendChild(card);
    Object.defineProperty(card, 'clientHeight', { value: 300, configurable: true });
    inner.getBoundingClientRect = () => ({ top: 0, bottom: 600, height: 600 });

    if (focus) {
      const region = document.createElement('div');
      region.setAttribute('data-stage-focus', '');
      region.getBoundingClientRect = () => ({ top: 350, bottom: 450, height: 100 });
      inner.appendChild(region);
    }

    return el;
  }

  test('below lg, shifts the page to bring the focused region into the card', () => {
    const el = buildCard({ focus: true });
    mount(el, { wide: false });

    expect(el.style.getPropertyValue('--stage-shift')).toBe('162px');
  });

  test('keeps the top of the page with nothing focused', () => {
    const el = buildCard({ focus: false });
    mount(el, { wide: false });

    expect(el.style.getPropertyValue('--stage-shift')).toBe('0px');
  });

  test('never shifts from lg, where the whole page shows', () => {
    const el = buildCard({ focus: true });
    mount(el, { wide: true });

    expect(el.style.getPropertyValue('--stage-shift')).toBe('0px');
  });

  test('watches the phone card, so a change in its height refits the shift', () => {
    const observed = [];
    const original = globalThis.ResizeObserver;
    globalThis.ResizeObserver = class {
      observe(target) { observed.push(target); }
      unobserve() {}
      disconnect() {}
    };

    try {
      const el = buildCard({ focus: true });
      mount(el, { wide: false });
      expect(observed).toContain(el.parentElement);
    } finally {
      globalThis.ResizeObserver = original;
    }
  });
});
