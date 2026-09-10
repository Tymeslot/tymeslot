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

  beforeEach(() => {
    document.body.innerHTML = '';
    open = vi.fn();
    window.TymeslotBooking = { open };
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
