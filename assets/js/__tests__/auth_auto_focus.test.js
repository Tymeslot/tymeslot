/**
 * Tests for the AuthAutoFocus hook in utility_hooks.js.
 *
 * The auth LiveView switches between login/signup/reset-password states via
 * push_patch within the same view. LiveView morphs the existing DOM node in
 * place rather than recreating it, so the browser's native `autofocus`
 * attribute never re-triggers on that patch — it only fires when a node is
 * first inserted. This hook re-focuses the marked field itself whenever the
 * root's `data-state` actually changes, while ignoring unrelated patches
 * (e.g. the validate round-trip on every keystroke) that leave it unchanged.
 */

import { describe, expect, test } from 'vitest';
import { AuthAutoFocus } from '../utility_hooks';

function buildEl(state) {
  const el = document.createElement('div');
  el.dataset.state = state;
  const input = document.createElement('input');
  input.setAttribute('autofocus', '');
  el.appendChild(input);
  // jsdom only honours .focus() on elements attached to the document.
  document.body.appendChild(el);
  return { el, input };
}

function makeHook(el, extra = {}) {
  return Object.assign(Object.create(AuthAutoFocus), { el, ...extra });
}

describe('AuthAutoFocus lifecycle', () => {
  test('mounted focuses the [autofocus] descendant and records the state', () => {
    const { el, input } = buildEl('login');
    const hook = makeHook(el);

    hook.mounted();

    expect(document.activeElement).toBe(input);
    expect(hook.lastState).toBe('login');
  });

  test('updated refocuses only when data-state changes', () => {
    const { el, input } = buildEl('signup');
    const hook = makeHook(el, { lastState: 'signup' });
    input.blur();

    // Unrelated patch (e.g. a validate round-trip) — state unchanged, must not steal focus back.
    hook.updated();
    expect(document.activeElement).not.toBe(input);

    // State actually changed (switched forms) — refocus the new form's field.
    el.dataset.state = 'login';
    hook.updated();
    expect(document.activeElement).toBe(input);
    expect(hook.lastState).toBe('login');
  });

  test('does nothing when there is no [autofocus] descendant', () => {
    const el = document.createElement('div');
    el.dataset.state = 'verify_email';
    const hook = makeHook(el, { lastState: 'signup' });

    expect(() => hook.updated()).not.toThrow();
  });
});
