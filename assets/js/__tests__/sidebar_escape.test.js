/**
 * Tests for the SidebarEscape hook (ui_interaction_hooks.js), which closes the
 * mobile dashboard drawer on Escape by running the dismiss command the server
 * rendered into `data-dismiss`, and only while the drawer is open.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { SidebarEscape } from '../ui_interaction_hooks';

function mountHook({ open }) {
  const el = document.createElement('aside');
  el.dataset.dismiss = '[["focus",{"to":"#dashboard-sidebar-toggle"}]]';
  if (open) el.classList.add('dashboard-sidebar-open');
  document.body.append(el);

  const hook = Object.create(SidebarEscape);
  hook.el = el;
  hook.liveSocket = { execJS: vi.fn() };
  hook.mounted();
  return hook;
}

function press(key, init = {}) {
  const event = new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true, ...init });
  window.dispatchEvent(event);
  return event;
}

describe('SidebarEscape', () => {
  let hook;

  beforeEach(() => {
    document.body.innerHTML = '';
  });

  afterEach(() => {
    hook?.destroyed();
    hook = null;
  });

  it('runs the dismiss command on Escape while the drawer is open', () => {
    hook = mountHook({ open: true });

    press('Escape');

    expect(hook.liveSocket.execJS).toHaveBeenCalledWith(hook.el, hook.el.dataset.dismiss);
  });

  it('ignores Escape while the drawer is closed', () => {
    hook = mountHook({ open: false });

    press('Escape');

    expect(hook.liveSocket.execJS).not.toHaveBeenCalled();
  });

  it('ignores other keys', () => {
    hook = mountHook({ open: true });

    press('Enter');

    expect(hook.liveSocket.execJS).not.toHaveBeenCalled();
  });

  it('stops listening once destroyed', () => {
    hook = mountHook({ open: true });
    hook.destroyed();

    press('Escape');

    expect(hook.liveSocket.execJS).not.toHaveBeenCalled();
    hook = null;
  });
});
