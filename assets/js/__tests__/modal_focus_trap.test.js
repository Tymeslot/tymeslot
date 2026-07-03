/**
 * Tests for the ModalFocusTrap hook (ui_interaction_hooks.js).
 *
 * The hook is what makes every core <.modal> keyboard-accessible: when the
 * overlay becomes visible it moves focus into the dialog and traps Tab within
 * it; when it hides it restores focus to the element that opened it. jsdom has
 * no layout engine, so we simulate `offsetParent` on the focusable elements and
 * run requestAnimationFrame synchronously to make the focus moves observable.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { ModalFocusTrap } from '../ui_interaction_hooks';

function simulateLayout(...els) {
  for (const el of els) {
    Object.defineProperty(el, 'offsetParent', {
      configurable: true,
      get: () => document.body,
    });
  }
}

function makeOverlay() {
  const overlay = document.createElement('div');
  overlay.style.display = 'none';

  const dialog = document.createElement('div');
  dialog.setAttribute('role', 'dialog');
  dialog.setAttribute('tabindex', '-1');

  const first = document.createElement('button');
  first.textContent = 'First';
  const last = document.createElement('button');
  last.textContent = 'Last';

  dialog.append(first, last);
  overlay.append(dialog);
  document.body.append(overlay);

  simulateLayout(dialog, first, last);
  return { overlay, dialog, first, last };
}

function mount(overlay) {
  const hook = Object.assign(Object.create(ModalFocusTrap), { el: overlay });
  hook.mounted();
  return hook;
}

function pressTab({ shiftKey = false } = {}) {
  const event = new KeyboardEvent('keydown', {
    key: 'Tab',
    shiftKey,
    bubbles: true,
    cancelable: true,
  });
  document.dispatchEvent(event);
  return event;
}

describe('ModalFocusTrap hook', () => {
  beforeEach(() => {
    // Run the deferred focus immediately so assertions are synchronous.
    vi.stubGlobal('requestAnimationFrame', (cb) => cb());
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    document.body.innerHTML = '';
  });

  it('moves focus into the dialog on show and restores it on hide', () => {
    const trigger = document.createElement('button');
    document.body.append(trigger);
    trigger.focus();

    const { overlay, first } = makeOverlay();
    const hook = mount(overlay);

    // Becomes visible → focus lands on the first focusable element.
    overlay.style.display = 'flex';
    hook.syncVisibility();
    expect(document.activeElement).toBe(first);

    // Hides again → focus returns to whatever opened it.
    overlay.style.display = 'none';
    hook.syncVisibility();
    expect(document.activeElement).toBe(trigger);
  });

  it('wraps Tab from the last focusable back to the first', () => {
    const { overlay, first, last } = makeOverlay();
    const hook = mount(overlay);

    overlay.style.display = 'flex';
    hook.syncVisibility();

    last.focus();
    const event = pressTab();
    expect(event.defaultPrevented).toBe(true);
    expect(document.activeElement).toBe(first);
  });

  it('wraps Shift+Tab from the first focusable back to the last', () => {
    const { overlay, first, last } = makeOverlay();
    const hook = mount(overlay);

    overlay.style.display = 'flex';
    hook.syncVisibility();

    first.focus();
    const event = pressTab({ shiftKey: true });
    expect(event.defaultPrevented).toBe(true);
    expect(document.activeElement).toBe(last);
  });

  it('leaves non-Tab keys alone', () => {
    const { overlay } = makeOverlay();
    const hook = mount(overlay);
    overlay.style.display = 'flex';
    hook.syncVisibility();

    const event = new KeyboardEvent('keydown', { key: 'Enter', bubbles: true });
    document.dispatchEvent(event);
    expect(event.defaultPrevented).toBe(false);
  });

  it('stops trapping once destroyed', () => {
    const trigger = document.createElement('button');
    document.body.append(trigger);
    trigger.focus();

    const { overlay } = makeOverlay();
    const hook = mount(overlay);
    overlay.style.display = 'flex';
    hook.syncVisibility();

    hook.destroyed();
    // Focus restored on teardown...
    expect(document.activeElement).toBe(trigger);

    // ...and Tab is no longer intercepted.
    const event = pressTab();
    expect(event.defaultPrevented).toBe(false);
  });
});
