/**
 * Tests for the slow-connection detector in video_hooks.js.
 *
 * The decision to load the background videos hinges on this single function,
 * and the thresholds are easy to get wrong silently. Each branch is exercised
 * here so a regression (e.g. flipping a `<` to `<=`) breaks the build.
 */

import { describe, expect, test } from 'vitest';
import { isSlowConnection } from '../video_hooks';

describe('isSlowConnection', () => {
  test('returns false when the API is unavailable (no connection object)', () => {
    expect(isSlowConnection(null)).toBe(false);
    expect(isSlowConnection(undefined)).toBe(false);
  });

  test('returns true when the user has Data Saver enabled', () => {
    // saveData wins regardless of other fields — respect the user's preference.
    expect(isSlowConnection({ saveData: true })).toBe(true);
    expect(
      isSlowConnection({ saveData: true, effectiveType: '4g', downlink: 50, rtt: 10 })
    ).toBe(true);
  });

  test.each([
    ['slow-2g', true],
    ['2g', true],
    ['3g', false],
    ['4g', false],
    ['', false],
  ])('effectiveType "%s" → slow=%s', (effectiveType, expected) => {
    expect(isSlowConnection({ effectiveType })).toBe(expected);
  });

  describe('downlink threshold (< 1.5 Mbps is slow)', () => {
    test('1.49 Mbps → slow', () => {
      expect(isSlowConnection({ downlink: 1.49 })).toBe(true);
    });

    test('1.5 Mbps → not slow (boundary is strict <)', () => {
      expect(isSlowConnection({ downlink: 1.5 })).toBe(false);
    });

    test('5 Mbps → not slow', () => {
      expect(isSlowConnection({ downlink: 5 })).toBe(false);
    });

    test('downlink: 0 → slow', () => {
      expect(isSlowConnection({ downlink: 0 })).toBe(true);
    });

    test('non-numeric downlink is ignored', () => {
      expect(isSlowConnection({ downlink: null })).toBe(false);
      expect(isSlowConnection({ downlink: 'fast' })).toBe(false);
      expect(isSlowConnection({ downlink: undefined })).toBe(false);
    });
  });

  describe('RTT threshold (> 300ms is slow)', () => {
    test('301ms → slow', () => {
      expect(isSlowConnection({ rtt: 301 })).toBe(true);
    });

    test('300ms → not slow (boundary is strict >)', () => {
      expect(isSlowConnection({ rtt: 300 })).toBe(false);
    });

    test('50ms → not slow', () => {
      expect(isSlowConnection({ rtt: 50 })).toBe(false);
    });

    test('non-numeric rtt is ignored', () => {
      expect(isSlowConnection({ rtt: null })).toBe(false);
      expect(isSlowConnection({ rtt: 'slow' })).toBe(false);
      expect(isSlowConnection({ rtt: undefined })).toBe(false);
    });
  });

  test('healthy 4g connection → not slow', () => {
    expect(
      isSlowConnection({
        saveData: false,
        effectiveType: '4g',
        downlink: 10,
        rtt: 50,
      })
    ).toBe(false);
  });

  test('4g labelled but slow downlink → slow (catches slow WiFi)', () => {
    // The motivating case: device reports "4g" but downlink says otherwise.
    expect(
      isSlowConnection({
        saveData: false,
        effectiveType: '4g',
        downlink: 0.8,
        rtt: 80,
      })
    ).toBe(true);
  });

  test('4g labelled but high RTT → slow', () => {
    expect(
      isSlowConnection({
        saveData: false,
        effectiveType: '4g',
        downlink: 10,
        rtt: 450,
      })
    ).toBe(true);
  });

  test('empty object → not slow', () => {
    expect(isSlowConnection({})).toBe(false);
  });
});
