/**
 * Tests for the reCAPTCHA v3 Phoenix LiveView hook.
 *
 * Focus:
 * - Google is not contacted until the visitor interacts with the form, and the
 *   script is injected once only.
 * - every form submission triggers a fresh token fetch, so retries after a
 *   server-side error don't reuse the already-consumed token;
 * - a submit made before any token exists is held back and re-dispatched once
 *   one is in place, never posted empty;
 * - token refresh pauses while the form is idle and resumes on interaction.
 */

import { beforeEach, afterEach, describe, expect, test, vi } from 'vitest';
import { RecaptchaV3Hook } from '../hooks/recaptcha_v3_hook';

// Drain the microtask queue so awaited .then chains resolve.
const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

const scriptSelector = 'script[src*="recaptcha/api.js"]';

function makeForm() {
  const form = document.createElement('form');
  form.dataset.siteKey = 'test-site-key';
  form.dataset.recaptchaAction = 'booking_submit';
  form.dataset.recaptchaParamRoot = 'booking';

  const name = document.createElement('input');
  name.type = 'text';
  name.name = 'booking[name]';
  form.appendChild(name);

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

const tokenField = (form) => form.querySelector('input[name="booking[g-recaptcha-response]"]');
const focusField = (form) => form.querySelector('input[name="booking[name]"]').focus();

// Stands in for LiveView's window-level submit listener: records the token
// the form carried at the moment the submit reached it.
function captureSubmits() {
  const posted = [];
  const listener = (event) => {
    event.preventDefault();
    posted.push(tokenField(event.target).value);
  };
  window.addEventListener('submit', listener);
  return { posted, stop: () => window.removeEventListener('submit', listener) };
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
    document.head.querySelectorAll(scriptSelector).forEach((script) => script.remove());
    delete window.grecaptcha;
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  describe('loading on interaction', () => {
    beforeEach(() => {
      // Force the script-injection branch.
      delete window.grecaptcha;
    });

    test('does not inject the script on mount', () => {
      mountHook(makeForm());

      expect(document.head.querySelector(scriptSelector)).toBeNull();
    });

    test('injects the script on the first focus inside the form', () => {
      const form = makeForm();
      mountHook(form);

      focusField(form);

      expect(document.head.querySelectorAll(scriptSelector)).toHaveLength(1);
    });

    test('injects the script on the first input inside the form', () => {
      const form = makeForm();
      mountHook(form);

      form.querySelector('input[name="booking[name]"]').dispatchEvent(
        new Event('input', { bubbles: true })
      );

      expect(document.head.querySelectorAll(scriptSelector)).toHaveLength(1);
    });

    test('injects the script once only, however many interactions follow', () => {
      const form = makeForm();
      mountHook(form);
      const field = form.querySelector('input[name="booking[name]"]');

      field.focus();
      field.dispatchEvent(new Event('input', { bubbles: true }));
      field.blur();
      field.focus();

      expect(document.head.querySelectorAll(scriptSelector)).toHaveLength(1);
    });

    test('propagates the page CSP nonce onto the injected reCAPTCHA script', () => {
      const meta = document.createElement('meta');
      meta.name = 'csp-nonce';
      meta.content = 'test-nonce-123';
      document.head.appendChild(meta);

      const form = makeForm();
      mountHook(form);
      focusField(form);

      const script = document.head.querySelector(scriptSelector);
      expect(script).not.toBeNull();
      expect(script.nonce || script.getAttribute('nonce')).toBe('test-nonce-123');

      meta.remove();
    });
  });

  test('does not fetch a token until the visitor interacts', async () => {
    executeMock.mockResolvedValueOnce('token-initial');

    const form = makeForm();
    mountHook(form);
    await flush();

    expect(executeMock).not.toHaveBeenCalled();

    focusField(form);
    await flush();

    expect(executeMock).toHaveBeenCalledTimes(1);
    expect(tokenField(form).value).toBe('token-initial');
  });

  test('regenerates the token on every submit event', async () => {
    executeMock
      .mockResolvedValueOnce('token-first')
      .mockResolvedValueOnce('token-second')
      .mockResolvedValueOnce('token-third');

    const form = makeForm();
    const hook = mountHook(form);

    focusField(form);
    await flush();
    expect(hook.currentToken).toBe('token-first');

    // First submit; server rejects (e.g. slot conflict)
    form.dispatchEvent(new Event('submit', { cancelable: true }));
    await flush();
    expect(hook.currentToken).toBe('token-second');

    // Second submit (user retries); fresh token again
    form.dispatchEvent(new Event('submit', { cancelable: true }));
    await flush();
    expect(hook.currentToken).toBe('token-third');

    // Three total executions: one on first focus + one per submit.
    expect(executeMock).toHaveBeenCalledTimes(3);
  });

  test('updated() writes the most recent token back into the hidden field', async () => {
    executeMock
      .mockResolvedValueOnce('token-first')
      .mockResolvedValueOnce('token-second');

    const form = makeForm();
    const hook = mountHook(form);

    focusField(form);
    await flush();

    form.dispatchEvent(new Event('submit', { cancelable: true }));
    await flush();

    // Simulate LiveView clearing the hidden field as part of re-render.
    tokenField(form).value = '';

    hook.updated();

    expect(tokenField(form).value).toBe('token-second');
  });

  describe('submitting before any token exists', () => {
    test('holds the submit back and re-dispatches it once a token arrives', async () => {
      executeMock.mockResolvedValueOnce('token-late');
      const submits = captureSubmits();

      const form = makeForm();
      mountHook(form);

      // Autofill plus Enter: no field was ever focused.
      form.requestSubmit();

      expect(submits.posted).toEqual([]);

      await flush();

      expect(submits.posted).toEqual(['token-late']);
      submits.stop();
    });

    test('loads the script for a held submit and posts once it has loaded', async () => {
      delete window.grecaptcha;
      const submits = captureSubmits();

      const form = makeForm();
      mountHook(form);
      form.requestSubmit();

      const script = document.head.querySelector(scriptSelector);
      expect(script).not.toBeNull();
      expect(submits.posted).toEqual([]);

      window.grecaptcha = {
        ready: (cb) => cb(),
        execute: vi.fn().mockResolvedValue('token-after-load'),
      };
      script.onload();
      await flush();

      expect(submits.posted).toEqual(['token-after-load']);
      submits.stop();
    });

    test('posts the blocked marker when the script fails to load', () => {
      delete window.grecaptcha;
      vi.spyOn(console, 'error').mockImplementation(() => {});
      const submits = captureSubmits();

      const form = makeForm();
      mountHook(form);
      form.requestSubmit();

      document.head.querySelector(scriptSelector).onerror();

      expect(submits.posted).toEqual(['RECAPTCHA_SCRIPT_BLOCKED']);
      submits.stop();
    });

    test('still posts, without a token, when execute fails, so the server can reject it', async () => {
      vi.spyOn(console, 'error').mockImplementation(() => {});
      executeMock.mockRejectedValueOnce(new Error('network'));
      const submits = captureSubmits();

      const form = makeForm();
      mountHook(form);
      form.requestSubmit();
      await flush();

      expect(submits.posted).toEqual(['']);
      submits.stop();
    });

    test('posts a double submit only once', async () => {
      executeMock.mockResolvedValue('token');
      const submits = captureSubmits();

      const form = makeForm();
      mountHook(form);
      form.requestSubmit();
      form.requestSubmit();
      await flush();

      expect(submits.posted).toEqual(['token']);
      submits.stop();
    });
  });

  describe('token refresh', () => {
    test('keeps refreshing while the visitor is active', async () => {
      vi.useFakeTimers();
      executeMock.mockResolvedValue('token');

      const form = makeForm();
      mountHook(form);
      focusField(form);
      await vi.advanceTimersByTimeAsync(0);
      expect(executeMock).toHaveBeenCalledTimes(1);

      await vi.advanceTimersByTimeAsync(90 * 1000);

      expect(executeMock).toHaveBeenCalledTimes(2);
    });

    test('pauses when the form is idle and resumes on the next interaction', async () => {
      vi.useFakeTimers();
      executeMock.mockResolvedValue('token');

      const form = makeForm();
      const hook = mountHook(form);
      focusField(form);
      await vi.advanceTimersByTimeAsync(0);

      // Well past the idle threshold without any interaction.
      await vi.advanceTimersByTimeAsync(30 * 60 * 1000);
      const callsWhileIdle = executeMock.mock.calls.length;
      await vi.advanceTimersByTimeAsync(30 * 60 * 1000);

      expect(executeMock.mock.calls.length).toBe(callsWhileIdle);
      // The about-to-expire token is dropped rather than posted later.
      expect(hook.currentToken).toBeNull();
      expect(tokenField(form).value).toBe('');

      form.querySelector('input[name="booking[name]"]').dispatchEvent(
        new Event('input', { bubbles: true })
      );
      await vi.advanceTimersByTimeAsync(0);

      expect(executeMock.mock.calls.length).toBe(callsWhileIdle + 1);
      expect(tokenField(form).value).toBe('token');
    });
  });

  test('destroyed() removes the submit and interaction listeners', async () => {
    executeMock.mockResolvedValue('token');

    const form = makeForm();
    const hook = mountHook(form);

    focusField(form);
    await flush();

    const callsBefore = executeMock.mock.calls.length;

    hook.destroyed();

    // After destroy, neither submits nor interactions trigger fetches.
    form.dispatchEvent(new Event('submit', { cancelable: true }));
    form.querySelector('input[name="booking[name]"]').dispatchEvent(
      new Event('input', { bubbles: true })
    );
    await flush();

    expect(executeMock.mock.calls.length).toBe(callsBefore);
  });
});
