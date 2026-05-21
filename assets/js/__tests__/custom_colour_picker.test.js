/**
 * Tests for the pure colour-math helpers in custom_colour_picker.js.
 *
 * The picker commits a hex value back to the server. A bug in hex→hsv→hex
 * conversion silently saves the wrong brand colour, so round-trip stability
 * across the full hue range is the main thing to lock down.
 */

import { describe, expect, test } from 'vitest';
import {
  clamp,
  hexToRgb,
  rgbToHsv,
  hsvToHex,
} from '../hooks/custom_colour_picker';

describe('clamp', () => {
  test.each([
    [5, 0, 10, 5],
    [-1, 0, 10, 0],
    [11, 0, 10, 10],
    [0, 0, 10, 0],
    [10, 0, 10, 10],
    [0.5, 0, 1, 0.5],
    [-0.1, 0, 1, 0],
    [1.1, 0, 1, 1],
  ])('clamp(%f, %f, %f) → %f', (n, lo, hi, expected) => {
    expect(clamp(n, lo, hi)).toBe(expected);
  });
});

describe('hexToRgb', () => {
  test('parses 6-character hex', () => {
    expect(hexToRgb('#000000')).toEqual({ r: 0, g: 0, b: 0 });
    expect(hexToRgb('#ffffff')).toEqual({ r: 255, g: 255, b: 255 });
    expect(hexToRgb('#06b6d4')).toEqual({ r: 6, g: 182, b: 212 });
  });

  test('expands 3-character shorthand', () => {
    expect(hexToRgb('#f00')).toEqual({ r: 255, g: 0, b: 0 });
    expect(hexToRgb('#0f0')).toEqual({ r: 0, g: 255, b: 0 });
    expect(hexToRgb('#abc')).toEqual({ r: 170, g: 187, b: 204 });
  });

  test('tolerates missing #', () => {
    expect(hexToRgb('06b6d4')).toEqual({ r: 6, g: 182, b: 212 });
    expect(hexToRgb('f00')).toEqual({ r: 255, g: 0, b: 0 });
  });

  test('is case-insensitive', () => {
    expect(hexToRgb('#FF00AA')).toEqual({ r: 255, g: 0, b: 170 });
    expect(hexToRgb('#ff00aa')).toEqual({ r: 255, g: 0, b: 170 });
  });

  test('returns null for invalid input', () => {
    expect(hexToRgb('not a hex')).toBeNull();
    expect(hexToRgb('#12345')).toBeNull();          // 5 chars
    expect(hexToRgb('#1234567')).toBeNull();        // 7 chars
    expect(hexToRgb('#gggggg')).toBeNull();         // non-hex chars
    expect(hexToRgb('')).toBeNull();
  });

  test('trims surrounding whitespace', () => {
    expect(hexToRgb('  #06b6d4  ')).toEqual({ r: 6, g: 182, b: 212 });
  });
});

describe('rgbToHsv', () => {
  test('black has zero value', () => {
    const { h, s, v } = rgbToHsv({ r: 0, g: 0, b: 0 });
    expect(s).toBe(0);
    expect(v).toBe(0);
    expect(h).toBe(0);
  });

  test('white has full value, zero saturation', () => {
    const { s, v } = rgbToHsv({ r: 255, g: 255, b: 255 });
    expect(s).toBe(0);
    expect(v).toBe(1);
  });

  test('pure primaries land on the correct hue', () => {
    expect(rgbToHsv({ r: 255, g: 0, b: 0 }).h).toBe(0);     // red
    expect(rgbToHsv({ r: 0, g: 255, b: 0 }).h).toBe(120);   // green
    expect(rgbToHsv({ r: 0, g: 0, b: 255 }).h).toBe(240);   // blue
  });

  test('pure secondaries land on the correct hue', () => {
    expect(rgbToHsv({ r: 255, g: 255, b: 0 }).h).toBe(60);  // yellow
    expect(rgbToHsv({ r: 0, g: 255, b: 255 }).h).toBe(180); // cyan
    expect(rgbToHsv({ r: 255, g: 0, b: 255 }).h).toBe(300); // magenta
  });

  test('hue is always non-negative', () => {
    // The internal `((g-b)/d) % 6` can go negative for some reds; the helper
    // adds 360 to keep it in [0, 360). Verify across the wheel.
    for (let r = 0; r <= 255; r += 17) {
      for (let g = 0; g <= 255; g += 17) {
        for (let b = 0; b <= 255; b += 17) {
          const { h } = rgbToHsv({ r, g, b });
          expect(h).toBeGreaterThanOrEqual(0);
          expect(h).toBeLessThan(360);
        }
      }
    }
  });
});

describe('hsvToHex', () => {
  test('grayscale (s=0)', () => {
    expect(hsvToHex({ h: 0, s: 0, v: 0 })).toBe('#000000');
    expect(hsvToHex({ h: 0, s: 0, v: 1 })).toBe('#ffffff');
    expect(hsvToHex({ h: 123, s: 0, v: 0.5 })).toBe('#808080');
  });

  test('pure primaries', () => {
    expect(hsvToHex({ h: 0, s: 1, v: 1 })).toBe('#ff0000');
    expect(hsvToHex({ h: 120, s: 1, v: 1 })).toBe('#00ff00');
    expect(hsvToHex({ h: 240, s: 1, v: 1 })).toBe('#0000ff');
  });

  test('pure secondaries', () => {
    expect(hsvToHex({ h: 60, s: 1, v: 1 })).toBe('#ffff00');
    expect(hsvToHex({ h: 180, s: 1, v: 1 })).toBe('#00ffff');
    expect(hsvToHex({ h: 300, s: 1, v: 1 })).toBe('#ff00ff');
  });

  test('output is always 7 chars and lower-cased hex', () => {
    for (let h = 0; h < 360; h += 23) {
      for (const s of [0, 0.25, 0.5, 0.75, 1]) {
        for (const v of [0, 0.25, 0.5, 0.75, 1]) {
          const hex = hsvToHex({ h, s, v });
          expect(hex).toMatch(/^#[0-9a-f]{6}$/);
        }
      }
    }
  });
});

describe('hex → hsv → hex round-trip', () => {
  // Round-trip should be stable: the value the user types is the value
  // committed to the server. A drift here = saved colour ≠ shown colour.
  const samples = [
    '#000000',
    '#ffffff',
    '#ff0000',
    '#00ff00',
    '#0000ff',
    '#ffff00',
    '#00ffff',
    '#ff00ff',
    '#06b6d4', // turquoise (the default seed)
    '#1f2937', // slate
    '#fbbf24', // amber
    '#a78bfa', // violet
    '#dc2626', // red
  ];

  test.each(samples)('%s survives hex → rgb → hsv → hex', (hex) => {
    const rgb = hexToRgb(hex);
    expect(rgb).not.toBeNull();
    const hsv = rgbToHsv(rgb);
    const back = hsvToHex(hsv);

    // Each channel may shift by ≤1 unit due to floating-point quantisation;
    // anything larger is a real bug.
    const r1 = rgb;
    const r2 = hexToRgb(back);
    expect(Math.abs(r1.r - r2.r)).toBeLessThanOrEqual(1);
    expect(Math.abs(r1.g - r2.g)).toBeLessThanOrEqual(1);
    expect(Math.abs(r1.b - r2.b)).toBeLessThanOrEqual(1);
  });

  test('round-trip is exact for grayscale', () => {
    for (const hex of ['#000000', '#808080', '#ffffff', '#404040', '#c0c0c0']) {
      const back = hsvToHex(rgbToHsv(hexToRgb(hex)));
      expect(back).toBe(hex);
    }
  });
});
