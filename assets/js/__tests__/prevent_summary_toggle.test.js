/**
 * Tests for the PreventSummaryToggle hook (ui_interaction_hooks.js), which sits
 * on the all-day event chips inside a <summary>. A click on a chip must not
 * toggle the surrounding <details>, yet must still bubble to window, where
 * LiveView dispatches phx-click.
 */

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { PreventSummaryToggle } from '../ui_interaction_hooks';

function mountHook() {
  document.body.innerHTML = `
    <details>
      <summary><div id="chip">All-day event</div></summary>
      <div>hidden events</div>
    </details>`;

  const hook = Object.create(PreventSummaryToggle);
  hook.el = document.getElementById('chip');
  hook.mounted();
  return hook;
}

describe('PreventSummaryToggle', () => {
  let hook;
  let onWindowClick;

  beforeEach(() => {
    hook = mountHook();
  });

  afterEach(() => {
    hook?.destroyed();
    if (onWindowClick) window.removeEventListener('click', onWindowClick);
    hook = null;
    onWindowClick = null;
  });

  it('lets the click bubble to window', () => {
    let reached = false;
    onWindowClick = () => { reached = true; };
    window.addEventListener('click', onWindowClick);

    hook.el.click();

    expect(reached).toBe(true);
  });

  it('keeps the click from toggling the surrounding details', () => {
    const event = new MouseEvent('click', { bubbles: true, cancelable: true });

    hook.el.dispatchEvent(event);

    expect(event.defaultPrevented).toBe(true);
    expect(document.querySelector('details').open).toBe(false);
  });

  it('stops intervening once destroyed', () => {
    hook.destroyed();
    const event = new MouseEvent('click', { bubbles: true, cancelable: true });

    hook.el.dispatchEvent(event);

    expect(event.defaultPrevented).toBe(false);
    hook = null;
  });
});
