/**
 * Ctrl + scroll zoom for the calendar canvas: the hour height a wheel step
 * leads to. Exponential, so a trackpad's many small steps and a mouse
 * wheel's few large ones zoom alike. Lasts for the visit; the saved density
 * is what a reload, or a density change, comes back to.
 *
 * The height stays fractional here: a trackpad's steps are far smaller than a
 * pixel of hour height, so rounding each one would stall the zoom. Round
 * where it is drawn.
 */
export const MIN_HOUR = 24;
export const MAX_HOUR = 128;
const RATE = 0.002;

export function zoomedHour(hourHeight, deltaY) {
  return Math.min(MAX_HOUR, Math.max(MIN_HOUR, hourHeight * Math.exp(-deltaY * RATE)));
}

// A wheel delta in pixels: Firefox reports lines (deltaMode 1) and some
// devices pages (2), which would otherwise zoom 16 or hundreds of times too
// little or too much.
const LINE_PX = 16;
export function wheelPixels(delta, deltaMode, pageHeight) {
  if (deltaMode === 1) return delta * LINE_PX;
  if (deltaMode === 2) return delta * pageHeight;
  return delta;
}
