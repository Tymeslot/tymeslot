/**
 * Tests for the reCAPTCHA v3 Phoenix LiveView hook.
 *
 * Focus: every form submission triggers a fresh token fetch so retries after
 * a server-side error don't reuse the already-consumed token and hit Google's
 * "timeout-or-duplicate" failure path.
 */

import { beforeEach, afterEach, describe, expect, test, vi } from 'vitest';
import { RecaptchaV3Hook } from '../hooks/recaptcha_v3_hook';

// Drain the microtask queue so awaited .then chains resolve.
const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

function makeForm() {
  const form = document.createElement('form');
  form.dataset.siteKey = 'test-site-key';
  form.dataset.recaptchaAction = 'booking_submit';
  form.dataset.recaptchaParamRoot = 'booking';

  const hidden = document.createElement('input');
  hidden.type = 'hidden';
  hidden.name = 'booking[g-recaptcha-response]';
  form.appendChild(hidden);

  document.body.appendChild(form);
  return form;
}

function mountHook(form) {
  const hook = Object.create(RecaptchaV3Hook);
  hook.el = form;
  hook.mounted();
  return hook;
}

describe('RecaptchaV3Hook', () => {
  let executeMock;

  beforeEach(() => {
    executeMock = vi.fn();

    window.grecaptcha = {
      ready: (cb) => cb(),
      execute: executeMock,
    };
  });

  afterEach(() => {
    document.body.innerHTML = '';
    delete window.grecaptcha;
    vi.restoreAllMocks();
  });

  test('fetches a fresh token on mount', async () => {
    executeMock.mockResolvedValueOnce('token-initial');

    const form = makeForm();
    mountHook(form);

    // Wait a microtask so the async token resolves.
    await flush();

    expect(executeMock).toHaveBeenCalledTimes(1);
    expect(form.querySelector('input[name="booking[g-recaptcha-response]"]').value).toBe(
      'token-initial'
    );
  });

  test('regenerates the token on every submit event', async () => {
    executeMock
      .mockResolvedValueOnce('token-first')
      .mockResolvedValueOnce('token-second')
      .mockResolvedValueOnce('token-third');

    const form = makeForm();
    const hook = mountHook(form);

    await flush();
    expect(hook.currentToken).toBe('token-first');

    // First submit — server rejects (e.g. slot conflict)
    form.dispatchEvent(new Event('submit'));
    await flush();
    expect(hook.currentToken).toBe('token-second');

    // Second submit (user retries) — fresh token again
    form.dispatchEvent(new Event('submit'));
    await flush();
    expect(hook.currentToken).toBe('token-third');

    // Three total executions: one on mount + one per submit.
    expect(executeMock).toHaveBeenCalledTimes(3);
  });

  test('updated() writes the most recent token back into the hidden field', async () => {
    executeMock
      .mockResolvedValueOnce('token-first')
      .mockResolvedValueOnce('token-second');

    const form = makeForm();
    const hook = mountHook(form);

    await flush();

    form.dispatchEvent(new Event('submit'));
    await flush();

    // Simulate LiveView clearing the hidden field as part of re-render.
    form.querySelector('input[name="booking[g-recaptcha-response]"]').value = '';

    hook.updated();

    expect(form.querySelector('input[name="booking[g-recaptcha-response]"]').value).toBe(
      'token-second'
    );
  });

  test('destroyed() removes the submit listener', async () => {
    executeMock.mockResolvedValue('token');

    const form = makeForm();
    const hook = mountHook(form);

    await flush();

    const callsBefore = executeMock.mock.calls.length;

    hook.destroyed();

    // After destroy, submit events should no longer trigger refetches.
    form.dispatchEvent(new Event('submit'));
    await flush();

    expect(executeMock.mock.calls.length).toBe(callsBefore);
  });
});
