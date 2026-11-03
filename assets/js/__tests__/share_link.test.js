/**
 * Tests for the `ShareLink` hook (hooks/share_link.js), the onboarding live
 * step's "Send them your link" button: the share sheet where there is one,
 * the mail client otherwise, and never a keep for a dismissed sheet.
 */

import { describe, expect, test, afterEach, vi } from 'vitest';
import {
  ShareLink,
  StageIframe,
  STAGE_READY_MESSAGE,
  SETTLE_MS,
  mailtoHref,
  canUseShareSheet
} from '../hooks/share_link';

describe('mailtoHref', () => {
  test('percent-encodes the subject and body, spaces as %20', () => {
    expect(mailtoHref('Book a time', 'Hi Sam, here: https://x.test/sam?a=1&b=2')).toBe(
      'mailto:?subject=Book%20a%20time&body=Hi%20Sam%2C%20here%3A%20https%3A%2F%2Fx.test%2Fsam%3Fa%3D1%26b%3D2'
    );
  });
});

describe('canUseShareSheet', () => {
  const data = { text: 't' };

  test('is false without navigator.share', () => {
    expect(canUseShareSheet({}, data)).toBe(false);
  });

  test('is true with share and no canShare', () => {
    expect(canUseShareSheet({ share: () => {} }, data)).toBe(true);
  });

  test('is false when canShare refuses the data', () => {
    expect(canUseShareSheet({ share: () => {}, canShare: () => false }, data)).toBe(false);
  });
});

describe('ShareLink hook', () => {
  const originalShare = navigator.share;

  afterEach(() => {
    document.body.innerHTML = '';
    Object.defineProperty(navigator, 'share', { value: originalShare, configurable: true });
    vi.restoreAllMocks();
  });

  function setup() {
    document.body.innerHTML = `
      <div class="onboarding-keep-card">
        <button id="send" data-share-text="Hi Sam, pick a time: https://x.test/sam"
          data-share-subject="Book a time with me">Send</button>
      </div>`;
    const el = document.getElementById('send');
    const handlers = {};
    const hook = Object.assign(Object.create(ShareLink), {
      el,
      pushEvent: vi.fn(),
      handleEvent: (name, fun) => {
        handlers[name] = fun;
      }
    });
    hook.mounted();
    return { el, hook, handlers };
  }

  function stubShare(impl) {
    Object.defineProperty(navigator, 'share', { value: vi.fn(impl), configurable: true });
  }

  test('a completed share sheet counts as a share_sheet keep', async () => {
    stubShare(() => Promise.resolve());
    const { hook } = setup();

    await hook.share();

    // The text already ends with the link; given a url too, targets paste it twice.
    expect(navigator.share).toHaveBeenCalledWith({ text: 'Hi Sam, pick a time: https://x.test/sam' });
    // The sheet is not the mail client: no `via`, so it confirms as sent.
    expect(hook.pushEvent).toHaveBeenCalledWith('keep_link', { method: 'share_sheet' });
  });

  test('a dismissed share sheet counts as nothing and opens no mail', async () => {
    stubShare(() => Promise.reject(new DOMException('cancelled', 'AbortError')));
    const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {});
    const { hook } = setup();

    await hook.share();

    expect(hook.pushEvent).not.toHaveBeenCalled();
    expect(click).not.toHaveBeenCalled();
  });

  test('a failing share sheet falls back to the mail client', async () => {
    stubShare(() => Promise.reject(new DOMException('nope', 'NotAllowedError')));
    const hrefs = [];
    vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(function () {
      hrefs.push(this.href);
    });
    const { hook } = setup();

    await hook.share();

    expect(hrefs).toHaveLength(1);
    expect(hrefs[0]).toMatch(/^mailto:\?subject=Book%20a%20time%20with%20me&body=Hi%20Sam/);
    expect(hook.pushEvent).toHaveBeenCalledWith('keep_link', { method: 'first_person', via: 'mail' });
  });

  test('without a share sheet it opens the mail client', async () => {
    Object.defineProperty(navigator, 'share', { value: undefined, configurable: true });
    const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {});
    const { hook } = setup();

    await hook.share();

    expect(click).toHaveBeenCalledTimes(1);
    // Opening the mail client sends nothing yet, so it says how it went.
    expect(hook.pushEvent).toHaveBeenCalledWith('keep_link', { method: 'first_person', via: 'mail' });
    expect(hook.pushEvent).toHaveBeenCalledTimes(1);
  });

  test('the focus event focuses the button and pulses its card', () => {
    const { el, handlers } = setup();

    handlers['share_link:focus']();

    expect(document.activeElement).toBe(el);
    expect(el.closest('.onboarding-keep-card').classList).toContain('onboarding-keep-pulse');
  });
});

describe('StageIframe hook', () => {
  afterEach(() => {
    document.body.innerHTML = '';
    vi.useRealTimers();
  });

  function mount({ narrow = false, inStage = true } = {}) {
    window.matchMedia = vi.fn(() => ({
      matches: narrow,
      addEventListener: () => {},
      removeEventListener: () => {}
    }));
    document.body.innerHTML = `<div class="${inStage ? 'onboarding-stage' : 'modal'}">
      <iframe id="f" src="/anna?t=1" data-src="/anna?t=1" data-page="/anna"></iframe></div>`;
    const el = document.getElementById('f');
    const hook = Object.assign(Object.create(StageIframe), { el });
    hook.mounted();
    return { el, hook };
  }

  // What the framed page posts once its LiveView has painted.
  function ready(el, { source = el.contentWindow, origin = window.location.origin, type = STAGE_READY_MESSAGE } = {}) {
    window.dispatchEvent(new MessageEvent('message', { data: { type }, origin, source }));
  }

  test('load alone does not switch the page on: the miniature stays until it has painted', () => {
    vi.useFakeTimers();
    const { el } = mount();

    el.dispatchEvent(new Event('load'));
    vi.advanceTimersByTime(SETTLE_MS - 1);

    expect(el.hasAttribute('data-loaded')).toBe(false);
  });

  test('the framed page reporting ready switches it on at once', () => {
    vi.useFakeTimers();
    const { el } = mount();

    el.dispatchEvent(new Event('load'));
    ready(el);

    expect(el.hasAttribute('data-loaded')).toBe(true);
  });

  test('a page that never reports ready is switched on after the settle delay', () => {
    vi.useFakeTimers();
    const { el } = mount();

    el.dispatchEvent(new Event('load'));
    vi.advanceTimersByTime(SETTLE_MS);

    expect(el.hasAttribute('data-loaded')).toBe(true);
  });

  test('ignores a ready message from another window, origin or of another type', () => {
    const { el } = mount();

    ready(el, { source: window });
    ready(el, { origin: 'https://evil.test' });
    ready(el, { type: 'tymeslot-resize' });

    expect(el.hasAttribute('data-loaded')).toBe(false);
  });

  test('stops listening once destroyed', () => {
    vi.useFakeTimers();
    const { el, hook } = mount();

    el.dispatchEvent(new Event('load'));
    hook.destroyed();
    ready(el);
    vi.advanceTimersByTime(SETTLE_MS);

    expect(el.hasAttribute('data-loaded')).toBe(false);
  });

  test('keeps the loaded page when only the token changes, as on a reconnect', () => {
    const { el, hook } = mount();
    el.setAttribute('data-loaded', '');
    el.dataset.src = '/anna?t=2';
    hook.updated();
    expect(el.getAttribute('src')).toBe('/anna?t=1');
    expect(el.hasAttribute('data-loaded')).toBe(true);
  });

  test('loads the new page when the page itself changes', () => {
    const { el, hook } = mount();
    el.setAttribute('data-loaded', '');
    el.dataset.src = '/ada?t=3';
    el.dataset.page = '/ada';
    hook.updated();
    expect(el.getAttribute('src')).toBe('/ada?t=3');
    expect(el.hasAttribute('data-loaded')).toBe(false);
  });

  test('leaves the tab order below lg on the stage, not in the modal', () => {
    expect(mount({ narrow: true }).el.getAttribute('tabindex')).toBe('-1');
    expect(mount({ narrow: true, inStage: false }).el.hasAttribute('tabindex')).toBe(false);
    expect(mount({ narrow: false }).el.hasAttribute('tabindex')).toBe(false);
  });
});
