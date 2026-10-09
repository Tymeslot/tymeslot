/**
 * Tests for the keyboard activation of `data-keyboard-click` elements
 * (keyboard_click.js): Enter and Space click the marked element, and nothing
 * else is touched.
 */

import { describe, expect, test, beforeEach, afterEach } from 'vitest';
import { installKeyboardClick } from '../keyboard_click';

let uninstall;
let clicks;

function build(marked = true) {
  const el = document.createElement('div');
  el.setAttribute('role', 'button');
  el.tabIndex = 0;
  if (marked) el.setAttribute('data-keyboard-click', '');
  el.addEventListener('click', () => clicks.push(el));
  document.body.appendChild(el);
  return el;
}

function press(el, key, opts = {}) {
  const event = new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true, ...opts });
  el.dispatchEvent(event);
  return event;
}

beforeEach(() => {
  clicks = [];
  uninstall = installKeyboardClick(document);
});

afterEach(() => {
  uninstall();
  document.body.innerHTML = '';
});

describe('installKeyboardClick', () => {
  test('Enter clicks the marked element', () => {
    const el = build();
    press(el, 'Enter');
    expect(clicks).toEqual([el]);
  });

  test('Space clicks it too, without scrolling the page', () => {
    const el = build();
    const event = press(el, ' ');
    expect(clicks).toEqual([el]);
    expect(event.defaultPrevented).toBe(true);
  });

  test('other keys, modified keys and held keys do nothing', () => {
    const el = build();
    press(el, 'a');
    press(el, 'Enter', { ctrlKey: true });
    press(el, 'Enter', { repeat: true });
    expect(clicks).toEqual([]);
  });

  test('an unmarked element is left to its own handling', () => {
    const el = build(false);
    const event = press(el, ' ');
    expect(clicks).toEqual([]);
    expect(event.defaultPrevented).toBe(false);
  });

  test('a key pressed on a link inside the marked element is not taken over', () => {
    const el = build();
    const link = document.createElement('a');
    link.href = '#';
    el.appendChild(link);
    press(link, 'Enter');
    expect(clicks).toEqual([]);
  });
});
