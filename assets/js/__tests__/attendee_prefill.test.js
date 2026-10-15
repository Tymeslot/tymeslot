/**
 * Tests for attendee_prefill.js: reading a booking link's `#name=…&email=…`
 * fragment and removing it from the address bar.
 */

import { describe, expect, test, vi } from 'vitest';
import { takeAttendeePrefill } from '../attendee_prefill';

function fakeLocation(hash, { pathname = '/ada', search = '' } = {}) {
  return { hash, pathname, search };
}

function fakeHistory() {
  return { state: { live: true }, replaceState: vi.fn() };
}

describe('takeAttendeePrefill', () => {
  test('returns the decoded name and email', () => {
    const loc = fakeLocation('#name=Ada%20Lovelace&email=ada%40example.com');

    expect(takeAttendeePrefill(loc, fakeHistory())).toEqual({
      name: 'Ada Lovelace',
      email: 'ada@example.com',
    });
  });

  test('keeps a literal + in a value, as a fragment is not form-encoded', () => {
    const loc = fakeLocation('#name=Ada&email=ada+test@example.com');

    expect(takeAttendeePrefill(loc, fakeHistory())).toEqual({
      name: 'Ada',
      email: 'ada+test@example.com',
    });
  });

  test('drops a value with a malformed escape and still strips its key', () => {
    const hist = fakeHistory();

    expect(takeAttendeePrefill(fakeLocation('#name=%E0%A4%A&email=ada%40example.com'), hist)).toEqual({
      email: 'ada@example.com',
    });
    expect(hist.replaceState).toHaveBeenCalledWith({ live: true }, '', '/ada');
  });

  test('leaves the rest of the fragment exactly as it was', () => {
    const hist = fakeHistory();

    takeAttendeePrefill(fakeLocation('#a=1+2&name=Ada&b=%20x'), hist);

    expect(hist.replaceState).toHaveBeenCalledWith({ live: true }, '', '/ada#a=1+2&b=%20x');
  });

  test('strips the fragment from the URL, keeping path, query and history state', () => {
    const loc = fakeLocation('#name=Ada&email=ada%40example.com', {
      pathname: '/ada/intro',
      search: '?utm_source=crm',
    });
    const hist = fakeHistory();

    takeAttendeePrefill(loc, hist);

    expect(hist.replaceState).toHaveBeenCalledWith(
      { live: true },
      '',
      '/ada/intro?utm_source=crm'
    );
  });

  test('keeps fragment content that is not a prefill key', () => {
    const hist = fakeHistory();

    expect(takeAttendeePrefill(fakeLocation('#name=Ada&section=two'), hist)).toEqual({
      name: 'Ada',
    });
    expect(hist.replaceState).toHaveBeenCalledWith({ live: true }, '', '/ada#section=two');
  });

  test('drops an empty value but still strips its key', () => {
    const hist = fakeHistory();

    expect(takeAttendeePrefill(fakeLocation('#name=&email=ada%40example.com'), hist)).toEqual({
      email: 'ada@example.com',
    });
    expect(hist.replaceState).toHaveBeenCalledWith({ live: true }, '', '/ada');
  });

  test('drops an over-long value but keeps the other and still strips the fragment', () => {
    const hist = fakeHistory();
    const loc = fakeLocation(`#name=${'a'.repeat(10000)}&email=ada%40example.com`);

    expect(takeAttendeePrefill(loc, hist)).toEqual({ email: 'ada@example.com' });
    expect(hist.replaceState).toHaveBeenCalledWith({ live: true }, '', '/ada');
  });

  test('keeps values exactly at the limit and drops one character beyond it', () => {
    const email = (n) => 'a'.repeat(n - 12) + '%40example.com';

    expect(takeAttendeePrefill(fakeLocation(`#name=${'a'.repeat(100)}`), fakeHistory())).toEqual({
      name: 'a'.repeat(100),
    });
    expect(takeAttendeePrefill(fakeLocation(`#name=${'a'.repeat(101)}`), fakeHistory())).toEqual({});
    expect(Object.keys(takeAttendeePrefill(fakeLocation(`#email=${email(254)}`), fakeHistory()))).toEqual(['email']);
    expect(takeAttendeePrefill(fakeLocation(`#email=${email(255)}`), fakeHistory())).toEqual({});
  });

  test('counts characters, not UTF-16 units', () => {
    const name = encodeURIComponent('😀'.repeat(100));

    expect(takeAttendeePrefill(fakeLocation(`#name=${name}`), fakeHistory())).toEqual({
      name: '😀'.repeat(100),
    });
  });

  test.each(['', '#', '#section-two', '#utm=1'])(
    'leaves the URL alone when the fragment %j carries no prefill',
    (hash) => {
      const hist = fakeHistory();

      expect(takeAttendeePrefill(fakeLocation(hash), hist)).toEqual({});
      expect(hist.replaceState).not.toHaveBeenCalled();
    }
  );
});
