/**
 * Tests for the Flash hook (utility_hooks.js), which dismisses a flash after
 * six seconds. It must do so by running the flash's own `phx-click` command:
 * a synthetic click would bubble to the window, and every open dialog's
 * `phx-click-away` would read it as a click outside and close.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { Flash } from '../utility_hooks';

const DISMISS = '[["push",{"event":"lv:clear-flash","value":{"key":"info"}}]]';

function mountHook({ phxClick = DISMISS, close } = {}) {
  const el = document.createElement('div');
  el.id = 'flash-info';
  if (phxClick) el.setAttribute('phx-click', phxClick);
  if (close !== undefined) el.dataset.close = close;
  document.body.append(el);

  const hook = Object.create(Flash);
  hook.el = el;
  hook.liveSocket = { execJS: vi.fn() };
  hook.mounted();
  return hook;
}

describe('Flash', () => {
  let hook;

  beforeEach(() => {
    vi.useFakeTimers();
    document.body.innerHTML = '';
  });

  afterEach(() => {
    hook?.destroyed();
    hook = null;
    vi.useRealTimers();
  });

  it('runs the dismiss command after six seconds', () => {
    hook = mountHook();

    vi.advanceTimersByTime(5999);
    expect(hook.liveSocket.execJS).not.toHaveBeenCalled();

    vi.advanceTimersByTime(1);
    expect(hook.liveSocket.execJS).toHaveBeenCalledWith(hook.el, DISMISS);
  });

  it('dispatches no click, so an open dialog is not dismissed by its click-away', () => {
    const clicks = vi.fn();
    window.addEventListener('click', clicks);
    hook = mountHook();

    vi.advanceTimersByTime(6000);

    expect(hook.liveSocket.execJS).toHaveBeenCalledTimes(1);
    expect(clicks).not.toHaveBeenCalled();
    window.removeEventListener('click', clicks);
  });

  it('leaves a flash without a dismiss command alone', () => {
    hook = mountHook({ phxClick: null });

    vi.advanceTimersByTime(6000);

    expect(hook.liveSocket.execJS).not.toHaveBeenCalled();
  });

  it('leaves a flash marked data-close="false" alone', () => {
    hook = mountHook({ close: 'false' });

    vi.advanceTimersByTime(6000);

    expect(hook.liveSocket.execJS).not.toHaveBeenCalled();
  });

  it('cancels the dismissal when the flash goes first', () => {
    hook = mountHook();
    hook.destroyed();

    vi.advanceTimersByTime(6000);

    expect(hook.liveSocket.execJS).not.toHaveBeenCalled();
    hook = null;
  });
});
