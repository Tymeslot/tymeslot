/**
 * Tests for the `StickyNavClearance` hook (hooks/sticky_nav_clearance.js),
 * which scrolls a focused field out from under the onboarding's sticky nav.
 */

import { describe, expect, test, afterEach, vi } from 'vitest';
import { StickyNavClearance, clearanceOffset } from '../hooks/sticky_nav_clearance';

describe('clearanceOffset', () => {
  const nav = { top: 1000, bottom: 1080 };

  test('is 0 for a field above the nav', () => {
    expect(clearanceOffset({ top: 900, bottom: 948 }, nav)).toBe(0);
  });

  test('lifts a field under the nav clear of it', () => {
    expect(clearanceOffset({ top: 1004, bottom: 1052 }, nav)).toBe(68);
  });

  test('is 0 for a field below the screen, which the browser scrolls itself', () => {
    expect(clearanceOffset({ top: 1150, bottom: 1200 }, nav)).toBe(0);
  });
});

describe('StickyNavClearance hook', () => {
  afterEach(() => {
    document.body.innerHTML = '';
  });

  function setup({ sticky }) {
    const nav = document.createElement('div');
    nav.style.position = sticky ? 'sticky' : 'static';
    const input = document.createElement('input');
    document.body.append(input, nav);
    nav.getBoundingClientRect = () => ({ top: 1000, bottom: 1080 });
    input.getBoundingClientRect = () => ({ top: 1004, bottom: 1052 });
    window.scrollBy = vi.fn();

    const hook = Object.assign(Object.create(StickyNavClearance), { el: nav });
    hook.mounted();
    return { hook, input };
  }

  test('does nothing while the nav is not sticky', () => {
    const { hook, input } = setup({ sticky: false });
    input.focus();

    expect(window.scrollBy).not.toHaveBeenCalled();
    hook.destroyed();
  });

  test('scrolls when a focused field sits under the nav', () => {
    const nav = document.createElement('div');
    nav.style.position = 'sticky';
    const input = document.createElement('input');
    document.body.append(input, nav);
    nav.getBoundingClientRect = () => ({ top: 1000, bottom: 1080 });
    input.getBoundingClientRect = () => ({ top: 1004, bottom: 1052 });
    window.scrollBy = vi.fn();

    const hook = Object.assign(Object.create(StickyNavClearance), { el: nav });
    hook.mounted();
    input.focus();

    expect(window.scrollBy).toHaveBeenCalledWith({ top: 68, behavior: 'instant' });
    hook.destroyed();
  });
});
