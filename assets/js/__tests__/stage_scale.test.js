/**
 * Tests for the `StageScale` hook (hooks/stage_scale.js), which fits the
 * onboarding stage's 400px page miniature to its frame and reserves the
 * scaled height.
 */

import { describe, expect, test, afterEach, vi } from 'vitest';
import { StageScale, stageScale } from '../hooks/stage_scale';

describe('stageScale', () => {
  test('fills a narrow frame below lg', () => {
    expect(stageScale(300, false)).toBe(0.75);
  });

  test('never grows past the design size below lg', () => {
    expect(stageScale(700, false)).toBe(1);
  });

  test('grows to fill the frame from lg', () => {
    expect(stageScale(520, true)).toBe(1.3);
  });

  test('stops at 1.6 from lg', () => {
    expect(stageScale(900, true)).toBe(1.6);
  });

  test('is 1 while the frame has no width', () => {
    expect(stageScale(0, true)).toBe(1);
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
  const listeners = [];
  window.matchMedia = vi.fn(() => ({
    matches: wide,
    addEventListener: (_type, fn) => listeners.push(fn),
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
    expect(el.style.height).toBe('640px');

    Object.defineProperty(inner, 'offsetHeight', { value: 500, configurable: true });
    hook.updated();

    expect(el.style.height).toBe('800px');
  });
});
