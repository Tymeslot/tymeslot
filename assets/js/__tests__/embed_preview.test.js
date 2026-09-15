/**
 * Tests for the dashboard "Live Preview" hook (Embed & Share).
 *
 * Focus: every mode that can reach the booking form carries the owner-preview
 * token, so pressing "Book Meeting" in a preview simulates instead of
 * persisting a meeting, mailing the address the organiser typed and creating a
 * calendar event. The four modes reach the booking page by two different
 * routes — Inline builds its own iframe URL, Popup and Floating delegate to
 * embed.js — and the token has to survive both.
 */

import { beforeEach, describe, expect, test, vi } from 'vitest';
import { EmbedPreview } from '../hooks/embed_preview';

// Worded rather than realistic: a token shaped like real Phoenix.Token output
// carries enough entropy to trip the repository's secret scanner. This still
// exercises what matters — three dot-separated segments spanning the URL-safe
// base64 alphabet, hyphen and underscore included — which is the whole of what
// embed.js validates before it will append the token.
const TOKEN = 'test-token.fake-preview-payload.test_signature';

function mountHook(embedType, overrides = {}) {
  const el = document.createElement('div');
  Object.assign(el.dataset, {
    username: 'alice',
    baseUrl: 'https://tymeslot.test',
    previewToken: TOKEN,
    embedType,
    isReady: 'true',
    layout: 'column',
    ...overrides
  });
  document.body.appendChild(el);

  const hook = Object.create(EmbedPreview);
  hook.el = el;
  hook.mounted();
  return hook;
}

describe('EmbedPreview', () => {
  let open;
  let windowOpen;

  beforeEach(() => {
    document.body.innerHTML = '';
    open = vi.fn();
    window.TymeslotBooking = { open };
    windowOpen = vi.spyOn(window, 'open').mockImplementation(() => {});
  });

  test('Inline builds an iframe carrying both halves of the preview contract', () => {
    const hook = mountHook('inline');
    const url = new URL(hook.el.querySelector('iframe').src);

    expect(url.searchParams.get('preview')).toBe('true');
    expect(url.searchParams.get('preview_token')).toBe(TOKEN);
  });

  test('Popup hands the preview token to the embed script', () => {
    const hook = mountHook('popup');
    hook.el.querySelector('button').click();

    expect(open).toHaveBeenCalledTimes(1);
    const [username, options] = open.mock.calls[0];
    expect(username).toBe('alice');
    expect(options.previewToken).toBe(TOKEN);
  });

  test('Floating hands the preview token to the embed script', () => {
    const hook = mountHook('floating');
    hook.el.querySelector('div.absolute div').click();

    expect(open).toHaveBeenCalledTimes(1);
    expect(open.mock.calls[0][1].previewToken).toBe(TOKEN);
  });

  test('Link renders no href a visitor could copy the preview token from', () => {
    // A real <a href> is trivially copyable ("Copy link address", or the new
    // tab's own address bar) and would hand a real visitor a token-bearing
    // URL that silently simulates their booking for up to an hour. There must
    // be no anchor at all, and the element that stands in for it must expose
    // no href/src attribute carrying the token.
    const hook = mountHook('link');

    expect(hook.el.querySelector('a')).toBeNull();
    const html = hook.el.innerHTML;
    expect(html).not.toContain('preview_token');
    expect(html).not.toContain(TOKEN);
  });

  test('Link opens both halves of the preview contract, but only from a click', () => {
    const hook = mountHook('link');
    const button = hook.el.querySelector('button');

    expect(windowOpen).not.toHaveBeenCalled();

    button.click();

    expect(windowOpen).toHaveBeenCalledTimes(1);
    const url = new URL(windowOpen.mock.calls[0][0]);
    expect(url.searchParams.get('preview')).toBe('true');
    expect(url.searchParams.get('preview_token')).toBe(TOKEN);
  });

  test('Link says its anchor is a short-lived preview, not the link to share', () => {
    // The anchor carries a token that expires after an hour, so an organiser
    // who right-clicks and copies it must not be told it is their link.
    const hint = mountHook('link').el.querySelector('p').textContent;

    expect(hint).toMatch(/preview only/i);
    expect(hint).not.toMatch(/direct link/i);
  });

  test('the modal opens at the height cap, because a preview never self-reports', () => {
    // iframe_embed.js bails out of embedded mode on ?preview=true, so no
    // resize message ever arrives and embed.js would leave its wrapper at the
    // 400px placeholder — a letterbox over a full-height standalone page.
    const hook = mountHook('popup');
    hook.el.querySelector('button').click();

    expect(open.mock.calls[0][1].initialHeight).toBe(
      Math.max(window.innerHeight - 100, 200)
    );
  });

  test('a deactivated link previews nothing at all', () => {
    const hook = mountHook('popup', { isReady: 'false' });

    expect(hook.el.querySelector('button')).toBeNull();
    expect(open).not.toHaveBeenCalled();
  });
});
