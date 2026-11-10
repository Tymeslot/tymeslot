/**
 * Floating panels: a popover anchored to a control.
 *
 * The panel is shown through the Popover API (`popover="manual"`), which lifts
 * it into the browser's top layer: no ancestor's `overflow`, `transform` or
 * stacking context can clip or cover it, so the same panel works inside a
 * scrolling modal, a glass card and the embed iframe. Placement is then only a
 * question of the viewport, and always keeps the whole panel inside it: it
 * opens on whichever side of the anchor has room and scrolls within itself
 * when neither side holds all of it. In an embed that viewport is the iframe,
 * so the panel can never be cut off at the iframe's edge (nor does it change
 * the height the auto-resize loop measures, since it is out of flow).
 *
 * Nothing here knows what the panel holds: a list of options today, a date or
 * time picker later. The owner decides what to put in it and what happens on
 * dismissal; `openFloatingPanel` returns the handle to close it.
 */

const GAP = 4;
const MARGIN = 8;
const MIN_USABLE_HEIGHT = 120;

export const floatingPanelsSupported = () =>
  typeof HTMLElement !== "undefined" && "showPopover" in HTMLElement.prototype;

/**
 * Where a panel goes, as viewport coordinates.
 *
 * @param {{top: number, bottom: number, left: number, width: number}} anchor the anchor's rect
 * @param {{width: number, height: number}} panel the panel's natural size
 * @param {{width: number, height: number}} viewport
 * @returns {{top: number, left: number, maxHeight: number, placement: string}}
 */
export function computePlacement(anchor, panel, viewport) {
  const below = viewport.height - anchor.bottom - GAP - MARGIN;
  const above = anchor.top - GAP - MARGIN;
  const left = Math.max(
    MARGIN,
    Math.min(anchor.left, viewport.width - MARGIN - panel.width)
  );

  // Neither side is usable (a short embed, a phone in landscape): cover the
  // anchor rather than draw a sliver. The panel still fits and still scrolls.
  if (below < MIN_USABLE_HEIGHT && above < MIN_USABLE_HEIGHT) {
    return {
      top: MARGIN,
      left,
      maxHeight: Math.min(panel.height, viewport.height - 2 * MARGIN),
      placement: "cover",
    };
  }

  if (panel.height <= below || below >= above) {
    return {
      top: anchor.bottom + GAP,
      left,
      maxHeight: Math.min(panel.height, below),
      placement: "below",
    };
  }

  const maxHeight = Math.min(panel.height, above);

  return {
    top: anchor.top - GAP - maxHeight,
    left,
    maxHeight,
    placement: "above",
  };
}

/**
 * Shows `panel` anchored to `anchor` until the handle's `close()` is called.
 *
 * The panel closes itself on a press outside it and its anchor, on Escape, and
 * when the anchor scrolls out of view; `onDismiss` then says it has closed, so
 * the owner can put its own state straight.
 *
 * @param {{panel: HTMLElement, anchor: HTMLElement, onDismiss?: function(string): void}} options
 * @returns {{close: function(): void, reposition: function(): void, closed: function(): boolean}}
 */
export function openFloatingPanel({ panel, anchor, onDismiss = () => {} }) {
  let frame = null;
  let closed = false;

  const reposition = () => {
    const rect = anchor.getBoundingClientRect();
    const viewport = {
      width: document.documentElement.clientWidth,
      height: document.documentElement.clientHeight,
    };

    if (rect.bottom < 0 || rect.top > viewport.height) {
      dismiss("scroll");
      return;
    }

    panel.style.maxHeight = "";
    panel.style.minWidth = `${Math.min(rect.width, viewport.width - 2 * MARGIN)}px`;
    panel.style.maxWidth = `${viewport.width - 2 * MARGIN}px`;

    const { top, left, maxHeight, placement } = computePlacement(
      rect,
      { width: panel.offsetWidth, height: panel.offsetHeight },
      viewport
    );

    panel.style.top = `${top}px`;
    panel.style.left = `${left}px`;
    panel.style.maxHeight = `${maxHeight}px`;
    panel.dataset.placement = placement;
  };

  const schedule = (event) => {
    if (event?.target === panel) return;
    if (frame) return;

    frame = requestAnimationFrame(() => {
      frame = null;
      if (!closed) reposition();
    });
  };

  const onPointerDown = (event) => {
    if (panel.contains(event.target) || anchor.contains(event.target)) return;
    dismiss("outside");
  };

  // Capture, and stopped: Escape closes the panel alone, not the modal the
  // select sits in.
  const onKeydown = (event) => {
    if (event.key !== "Escape") return;

    event.preventDefault();
    event.stopPropagation();
    dismiss("escape");
  };

  function close() {
    if (closed) return;

    closed = true;
    if (frame) cancelAnimationFrame(frame);
    document.removeEventListener("pointerdown", onPointerDown, true);
    document.removeEventListener("keydown", onKeydown, true);
    window.removeEventListener("scroll", schedule, true);
    window.removeEventListener("resize", schedule);
    if (panel.isConnected && panel.matches(":popover-open")) panel.hidePopover();
  }

  function dismiss(reason) {
    close();
    onDismiss(reason);
  }

  document.addEventListener("pointerdown", onPointerDown, true);
  document.addEventListener("keydown", onKeydown, true);
  window.addEventListener("scroll", schedule, { capture: true, passive: true });
  window.addEventListener("resize", schedule, { passive: true });

  panel.showPopover();

  // First, with the listeners in place: it can dismiss straight away, for an
  // anchor out of view, and `close()` then has them to remove.
  reposition();

  return { close, reposition, closed: () => closed };
}
