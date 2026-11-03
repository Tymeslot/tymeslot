/**
 * Tests for the `ClampedText` hook (hooks/clamped_text.js), which marks a
 * meeting type's description `data-overflowing` while its clamped text runs
 * past the cut, so the stylesheet offers "Show more" only then.
 *
 * jsdom does no layout, so the text's `scrollHeight` and `clientHeight` are
 * set by hand.
 */

import { describe, expect, test, afterEach, vi } from 'vitest';
import { ClampedText, overflows } from '../hooks/clamped_text';

function mount({ scrollHeight, clientHeight }) {
  document.body.innerHTML = `
    <div id="desc">
      <p data-clamped-text>A description</p>
      <button type="button">Show more</button>
    </div>`;

  const el = document.getElementById('desc');
  const text = el.querySelector('[data-clamped-text]');
  Object.defineProperty(text, 'scrollHeight', { configurable: true, get: () => scrollHeight });
  Object.defineProperty(text, 'clientHeight', { configurable: true, get: () => clientHeight });

  const hook = Object.create(ClampedText);
  hook.el = el;
  hook.mounted();
  return { hook, el, text };
}

afterEach(() => {
  document.body.innerHTML = '';
  vi.unstubAllGlobals();
});

describe('overflows', () => {
  test('is true when the content is taller than the clamped box', () => {
    expect(overflows({ scrollHeight: 120, clientHeight: 72 })).toBe(true);
  });

  test('is false when the content fits, allowing a pixel of rounding', () => {
    expect(overflows({ scrollHeight: 72, clientHeight: 72 })).toBe(false);
    expect(overflows({ scrollHeight: 72.8, clientHeight: 72 })).toBe(false);
  });
});

describe('ClampedText', () => {
  test('marks a text that runs past the cut', () => {
    const { el } = mount({ scrollHeight: 120, clientHeight: 72 });
    expect(el.hasAttribute('data-overflowing')).toBe(true);
  });

  test('leaves a text that fits unmarked, so no toggle is offered', () => {
    const { el } = mount({ scrollHeight: 48, clientHeight: 48 });
    expect(el.hasAttribute('data-overflowing')).toBe(false);
  });

  test('measures again after a patch drops the mark', () => {
    const { hook, el } = mount({ scrollHeight: 120, clientHeight: 72 });
    el.removeAttribute('data-overflowing');

    hook.updated();

    expect(el.hasAttribute('data-overflowing')).toBe(true);
  });

  test('leaves the mark alone while the text is expanded', () => {
    const { hook, el, text } = mount({ scrollHeight: 120, clientHeight: 72 });
    el.classList.add('is-expanded');
    // Unclamped, the box is as tall as its content.
    Object.defineProperty(text, 'clientHeight', { configurable: true, get: () => 120 });

    hook.updated();

    expect(el.hasAttribute('data-overflowing')).toBe(true);
  });

  test('measures again when the text box resizes, and stops on destroy', () => {
    let notify;
    const observe = vi.fn();
    const disconnect = vi.fn();
    vi.stubGlobal(
      'ResizeObserver',
      class {
        constructor(callback) { notify = callback; }
        observe(target) { observe(target); }
        disconnect() { disconnect(); }
      }
    );

    let clientHeight = 72;
    const { hook, el, text } = mount({ scrollHeight: 120, clientHeight });
    Object.defineProperty(text, 'clientHeight', { configurable: true, get: () => clientHeight });
    expect(observe).toHaveBeenCalledWith(text);
    expect(el.hasAttribute('data-overflowing')).toBe(true);

    // The card widened: the whole text now fits inside the cut.
    clientHeight = 120;
    notify();
    expect(el.hasAttribute('data-overflowing')).toBe(false);

    hook.destroyed();
    expect(disconnect).toHaveBeenCalled();
  });
});
