/**
 * Tests for the `ServerUrlField` hook (hooks/server_url_field.js).
 *
 * The behaviour under test is the one a self-hoster hits first: typing the
 * bare host of their server (`cloud.example.com`) into a `type="url"` field.
 * Before the hook, that produced the browser's "Please enter a URL" and
 * nothing else, because the native constraint blocks the submit before
 * `phx-submit` ever fires.
 */

import { describe, expect, test, beforeEach, afterEach } from 'vitest';
import { ServerUrlField, normaliseUrlScheme } from '../hooks/server_url_field';

const HINT = 'Enter a full address starting with https://, for example https://cloud.example.com';

function buildField({ value = '', hint = HINT } = {}) {
  const form = document.createElement('form');
  const el = document.createElement('input');
  el.type = 'url';
  el.required = true;
  el.value = value;
  if (hint !== null) el.dataset.schemeHint = hint;
  form.appendChild(el);
  document.body.appendChild(form);
  return el;
}

function mount(el) {
  const hook = Object.assign(Object.create(ServerUrlField), { el });
  hook.mounted();
  return hook;
}

let hook;

beforeEach(() => {
  hook = null;
});

afterEach(() => {
  if (hook) hook.destroyed();
  document.body.innerHTML = '';
});

describe('normaliseUrlScheme()', () => {
  test('prefixes https:// onto a bare host', () => {
    expect(normaliseUrlScheme('cloud.example.com')).toBe('https://cloud.example.com');
  });

  test('prefixes https:// onto a host with a port and a path', () => {
    expect(normaliseUrlScheme('cloud.example.com:8443/remote.php/dav')).toBe(
      'https://cloud.example.com:8443/remote.php/dav'
    );
  });

  test('leaves an address that already names a scheme alone', () => {
    expect(normaliseUrlScheme('http://cloud.example.com')).toBe('http://cloud.example.com');
    expect(normaliseUrlScheme('https://cloud.example.com')).toBe('https://cloud.example.com');
  });

  test('leaves a wrong scheme alone so the server can name it', () => {
    expect(normaliseUrlScheme('ftp://files.example.com')).toBe('ftp://files.example.com');
  });

  test('completes a scheme-relative address', () => {
    expect(normaliseUrlScheme('//cloud.example.com')).toBe('https://cloud.example.com');
  });

  test('trims surrounding whitespace, which the server refuses outright', () => {
    expect(normaliseUrlScheme('  cloud.example.com  ')).toBe('https://cloud.example.com');
  });

  test('leaves an empty value empty rather than inventing an address', () => {
    expect(normaliseUrlScheme('')).toBe('');
    expect(normaliseUrlScheme('   ')).toBe('');
  });
});

describe('ServerUrlField on commit', () => {
  test('rewrites a bare host in the field, where the person can see it', () => {
    const el = buildField({ value: 'cloud.example.com' });
    hook = mount(el);

    el.dispatchEvent(new Event('change'));

    expect(el.value).toBe('https://cloud.example.com');
  });

  test('the rewritten value satisfies the native constraint the bare host failed', () => {
    const el = buildField({ value: 'cloud.example.com' });
    expect(el.validity.typeMismatch).toBe(true);

    hook = mount(el);
    el.dispatchEvent(new Event('change'));

    expect(el.validity.typeMismatch).toBe(false);
    expect(el.checkValidity()).toBe(true);
  });

  test('leaves a value that already has a scheme untouched', () => {
    const el = buildField({ value: 'https://cloud.example.com' });
    hook = mount(el);

    el.dispatchEvent(new Event('change'));

    expect(el.value).toBe('https://cloud.example.com');
  });
});

describe('ServerUrlField on invalid', () => {
  test('replaces the browser wording for a value that is still not an address', () => {
    const el = buildField({ value: 'my server.example.com' });
    hook = mount(el);

    el.checkValidity();

    expect(el.validationMessage).toBe(HINT);
  });

  test('names the correction when a submit beats the commit', () => {
    // Clicking submit does not always blur the field first (Safari), so the
    // bare host can reach the native check before `change` has corrected it.
    const el = buildField({ value: 'cloud.example.com' });
    hook = mount(el);

    el.checkValidity();

    expect(el.validationMessage).toBe(HINT);
  });

  test('leaves an empty required field to the browser, which already says the right thing', () => {
    const el = buildField({ value: '' });
    hook = mount(el);

    el.checkValidity();

    expect(el.validity.valueMissing).toBe(true);
    expect(el.validity.customError).toBe(false);
  });

  test('clears the custom message as soon as the value is edited', () => {
    const el = buildField({ value: 'my server.example.com' });
    hook = mount(el);

    el.checkValidity();
    expect(el.validity.customError).toBe(true);

    el.value = 'https://files.example.com';
    el.dispatchEvent(new Event('input'));

    expect(el.validity.customError).toBe(false);
    expect(el.checkValidity()).toBe(true);
  });

  test('falls back to the browser message when no hint was rendered', () => {
    const el = buildField({ value: 'my server.example.com', hint: null });
    hook = mount(el);

    el.checkValidity();

    expect(el.validity.customError).toBe(false);
  });
});

describe('ServerUrlField lifecycle', () => {
  test('a patch clears a stale custom message rather than refusing the new value', () => {
    const el = buildField({ value: 'my server.example.com' });
    hook = mount(el);

    el.checkValidity();
    expect(el.validity.customError).toBe(true);

    el.value = 'https://files.example.com';
    hook.updated();

    expect(el.validity.customError).toBe(false);
  });

  test('stops listening once destroyed', () => {
    const el = buildField({ value: 'cloud.example.com' });
    const detached = mount(el);
    detached.destroyed();

    el.dispatchEvent(new Event('change'));

    expect(el.value).toBe('cloud.example.com');
  });
});
