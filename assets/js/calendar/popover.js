/**
 * Placement for the canvas's popovers (the event preview, the "+N more"
 * list). Beside the anchor when either side has room, so the popover never
 * covers the slot it refers to; otherwise below it, or above when below
 * would leave the viewport. Always clamped inside the viewport.
 */
const MARGIN = 8;
const clamp = (value, min, max) => Math.max(min, Math.min(max, value));

export function placePopover(anchor, size, viewport, gap = 8) {
  const maxLeft = viewport.width - size.width - MARGIN;
  const maxTop = viewport.height - size.height - MARGIN;

  if (anchor.right + gap + size.width <= viewport.width - MARGIN) {
    return { left: anchor.right + gap, top: clamp(anchor.top, MARGIN, maxTop) };
  }
  if (anchor.left - gap - size.width >= MARGIN) {
    return { left: anchor.left - gap - size.width, top: clamp(anchor.top, MARGIN, maxTop) };
  }

  const below = anchor.bottom + gap;
  const top = below + size.height <= viewport.height - MARGIN ? below : anchor.top - gap - size.height;
  return { left: clamp(anchor.left, MARGIN, maxLeft), top: clamp(top, MARGIN, maxTop) };
}
