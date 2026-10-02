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

  test.each(['', '#', '#section-two', '#utm=1'])(
    'leaves the URL alone when the fragment %j carries no prefill',
    (hash) => {
      const hist = fakeHistory();

      expect(takeAttendeePrefill(fakeLocation(hash), hist)).toEqual({});
      expect(hist.replaceState).not.toHaveBeenCalled();
    }
  );
});
