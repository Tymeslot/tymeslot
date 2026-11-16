/**
 * Placement for the canvas's popovers (the event preview, the "+N more"
 * list). Beside the anchor when either side has room, so the popover never
 * covers the slot it refers to; otherwise below it, or above when below
 * would leave the viewport. When no side fits in full, the larger one is used
 * with a `maxHeight` for the caller to scroll; failing that, the anchor's
 * title stays clear. Always clamped inside the viewport.
 */
const MARGIN = 8;
const MIN_SCROLL_HEIGHT = 120;
const MIN_TITLE_VISIBLE = 120;
const TITLE_STRIP = 24;
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

  const left = clamp(anchor.left, MARGIN, maxLeft);
  const below = anchor.bottom + gap;
  const above = anchor.top - gap - size.height;
  if (below + size.height <= viewport.height - MARGIN) return { left, top: clamp(below, MARGIN, maxTop) };
  if (above >= MARGIN) return { left, top: clamp(above, MARGIN, maxTop) };

  // Neither side fits in full: use the larger one and ask the caller to
  // scroll the popover body, as long as it keeps a usable height.
  const spaceBelow = viewport.height - MARGIN - anchor.bottom - gap;
  const spaceAbove = anchor.top - MARGIN - gap;
  const space = Math.max(spaceBelow, spaceAbove);
  if (space >= MIN_SCROLL_HEIGHT) {
    return { left, top: spaceBelow >= spaceAbove ? below : MARGIN, maxHeight: space };
  }

  // Overlap is unavoidable. Right-align inside a wide anchor so its left
  // edge (the title) stays visible; otherwise start below the first line.
  const alignedLeft = Math.min(maxLeft, anchor.right - size.width);
  if (alignedLeft - anchor.left >= MIN_TITLE_VISIBLE) {
    return { left: Math.max(alignedLeft, MARGIN), top: clamp(above, MARGIN, maxTop) };
  }
  return { left, top: clamp(Math.max(anchor.top, MARGIN) + TITLE_STRIP + gap, MARGIN, maxTop) };
}
