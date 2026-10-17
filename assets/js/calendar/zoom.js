/**
 * Ctrl + scroll zoom for the calendar canvas: the hour height a wheel step
 * leads to. Exponential, so a trackpad's many small steps and a mouse
 * wheel's few large ones zoom alike. Lasts for the visit; the saved density
 * is what a reload, or a density change, comes back to.
 */
export const MIN_HOUR = 24;
export const MAX_HOUR = 128;
const RATE = 0.002;

export function zoomedHour(hourHeight, deltaY) {
  return Math.round(Math.min(MAX_HOUR, Math.max(MIN_HOUR, hourHeight * Math.exp(-deltaY * RATE))));
}
