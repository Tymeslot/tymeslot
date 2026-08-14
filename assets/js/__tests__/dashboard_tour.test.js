/**
 * Tests for the DashboardTour hook's positioning cache.
 *
 * The hook short-circuits in updated() when the step's anchor/placement are
 * unchanged, to avoid re-running layout work on unrelated LiveView patches.
 * The cache must be kept in sync for *every* layout path — including the
 * centered (anchorless) welcome step. A regression here is invisible in the
 * happy path but breaks Back-then-forward navigation: returning to a centered
 * step and then advancing to the same anchored step would leave the spotlight
 * unpositioned (full-page dim, no cut-out).
 */

import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest';
import { DashboardTour } from '../hooks/dashboard_tour';

function buildOverlay(anchor, placement) {
  const el = document.createElement('div');
  el.id = 'dashboard-tour';
  if (anchor) el.dataset.anchor = anchor;
  if (placement) el.dataset.placement = placement;

  el.innerHTML = `
    <div class="dashboard-tour__backdrop"></div>
    <div class="dashboard-tour__spotlight"></div>
    <div class="dashboard-tour__tooltip"></div>
  `;
  document.body.appendChild(el);
  return el;
}

function makeHook(el) {
  const hook = Object.assign(Object.create(DashboardTour), {
    el,
    pushEvent: vi.fn(),
  });
  return hook;
}

describe('DashboardTour layout cache', () => {
  beforeEach(() => {
    // Force the >= 1024px branch so the hook does not bail to viewport-too-small.
    window.matchMedia = vi.fn().mockReturnValue({ matches: true });
    // Run rAF callbacks synchronously so applySpotlightLayout completes.
    vi.stubGlobal('requestAnimationFrame', (cb) => {
      cb();
      return 1;
    });
    vi.stubGlobal('cancelAnimationFrame', vi.fn());
  });

  afterEach(() => {
    document.body.innerHTML = '';
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  test('applyCenteredLayout records the centered step in the cache', () => {
    const el = buildOverlay(null, null);
    const hook = makeHook(el);
    // Pretend a previous anchored step left a stale cache.
    hook.lastAnchor = 'meetings';
    hook.lastPlacement = 'right';

    hook.applyCenteredLayout();

    expect(hook.lastAnchor).toBeUndefined();
    expect(hook.lastPlacement).toBe('bottom');
  });

  test('Back to centered then forward to the same anchored step repositions', async () => {
    // Step starts anchored.
    const el = buildOverlay('meetings', 'right');
    const target = document.createElement('div');
    target.dataset.tour = 'meetings';
    document.body.appendChild(target);

    const hook = makeHook(el);
    // position() resolves the anchor via a Promise; await it so the spotlight
    // layout (and the cache update inside it) has run before asserting.
    await hook.position({ scroll: false });

    // After positioning the anchored step, the cache reflects it.
    expect(hook.lastAnchor).toBe('meetings');
    expect(hook.lastPlacement).toBe('right');

    // Back to the centered welcome step: anchor/placement removed.
    delete el.dataset.anchor;
    delete el.dataset.placement;
    hook.updated();

    // The cache must no longer claim the anchored step.
    expect(hook.lastAnchor).toBeUndefined();

    // Forward again to the same anchored step.
    el.dataset.anchor = 'meetings';
    el.dataset.placement = 'right';
    const positionSpy = vi.spyOn(hook, 'position');
    hook.updated();

    // updated() must NOT early-return — it must re-run positioning so the
    // spotlight is placed over the anchor again.
    expect(positionSpy).toHaveBeenCalled();
  });
});

describe('DashboardTour tooltip placement', () => {
  const VIEWPORT_WIDTH = 1280;
  const VIEWPORT_HEIGHT = 800;
  const TOOLTIP_WIDTH = 352;
  const TOOLTIP_HEIGHT = 180;

  // Places a tooltip of a fixed size against `rect` and returns the resulting
  // box, so assertions can talk about where the card actually landed.
  function place(rect, placement) {
    const el = buildOverlay(null, null);
    const hook = makeHook(el);
    const tooltip = el.querySelector('.dashboard-tour__tooltip');
    tooltip.getBoundingClientRect = () => ({
      width: TOOLTIP_WIDTH,
      height: TOOLTIP_HEIGHT,
    });

    hook.placeTooltip(tooltip, rect, placement);

    const top = parseFloat(tooltip.style.top);
    const left = parseFloat(tooltip.style.left);
    return { top, left, bottom: top + TOOLTIP_HEIGHT, right: left + TOOLTIP_WIDTH };
  }

  function anchorRect({ top, left, width = 200, height = 40 }) {
    return { top, left, width, height, bottom: top + height, right: left + width };
  }

  beforeEach(() => {
    vi.stubGlobal('innerWidth', VIEWPORT_WIDTH);
    vi.stubGlobal('innerHeight', VIEWPORT_HEIGHT);
  });

  afterEach(() => {
    document.body.innerHTML = '';
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  test('a tooltip that would overflow the top is flipped below its anchor', () => {
    // The calendar's setup-checklist strip: pinned just under the 64px header,
    // so a card placed above it has nowhere to go.
    const rect = anchorRect({ top: 72, left: 300 });

    const box = place(rect, 'top');

    expect(box.top).toBeGreaterThanOrEqual(0);
    // Flipped, not merely nudged: it now sits below the anchor.
    expect(box.top).toBeGreaterThanOrEqual(rect.bottom);
  });

  test('a tooltip that would overflow the bottom is flipped above its anchor', () => {
    const rect = anchorRect({ top: VIEWPORT_HEIGHT - 60, left: 300 });

    const box = place(rect, 'bottom');

    expect(box.bottom).toBeLessThanOrEqual(VIEWPORT_HEIGHT);
    expect(box.bottom).toBeLessThanOrEqual(rect.top);
  });

  test('a tooltip is clamped when neither side of the anchor has room', () => {
    // Anchor taller than the viewport leaves no room above or below, so the
    // flip cannot help and only the clamp keeps the card readable.
    const rect = anchorRect({ top: -50, left: 300, height: VIEWPORT_HEIGHT + 100 });

    const box = place(rect, 'top');

    expect(box.top).toBeGreaterThanOrEqual(0);
    expect(box.bottom).toBeLessThanOrEqual(VIEWPORT_HEIGHT);
  });

  test('a tooltip beside an edge-hugging anchor stays within the viewport', () => {
    // `right` placement against an anchor flush to the right edge.
    const rect = anchorRect({ top: 300, left: VIEWPORT_WIDTH - 210 });

    const box = place(rect, 'right');

    expect(box.left).toBeGreaterThanOrEqual(0);
    expect(box.right).toBeLessThanOrEqual(VIEWPORT_WIDTH);
  });

  test('bottom_end right-aligns the card with its anchor and stays on screen', () => {
    // The user menu: top-right of the header, tooltip hangs down and left.
    const rect = anchorRect({ top: 12, left: VIEWPORT_WIDTH - 60, width: 48 });

    const box = place(rect, 'bottom_end');

    expect(box.top).toBeGreaterThanOrEqual(rect.bottom);
    expect(box.right).toBeLessThanOrEqual(VIEWPORT_WIDTH);
    expect(box.left).toBeGreaterThanOrEqual(0);
  });

  test('a placement with room to spare is left where it was asked for', () => {
    const rect = anchorRect({ top: 400, left: 500 });

    const box = place(rect, 'bottom');

    // 12px gap below the anchor, horizontally centred on it — no flip, no clamp.
    expect(box.top).toBe(rect.bottom + 12);
    expect(box.left).toBe(rect.left + rect.width / 2 - TOOLTIP_WIDTH / 2);
  });
});

describe('DashboardTour per-step fade', () => {
  beforeEach(() => {
    window.matchMedia = vi.fn().mockReturnValue({ matches: true });
    vi.stubGlobal('requestAnimationFrame', (cb) => {
      cb();
      return 1;
    });
    vi.stubGlobal('cancelAnimationFrame', vi.fn());
  });

  afterEach(() => {
    document.body.innerHTML = '';
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  test('a step change fades the card in', () => {
    const el = buildOverlay(null, null);
    el.dataset.stepIndex = '1';
    const hook = makeHook(el);
    hook.lastStepIndex = '0';

    const beginSpy = vi.spyOn(hook, 'beginStepEnter');
    hook.updated();

    // The step changed, so the fade was kicked off and the cache advanced.
    expect(beginSpy).toHaveBeenCalled();
    expect(hook.lastStepIndex).toBe('1');
    // With rAF running synchronously, the card has already been released back
    // to fully visible after positioning.
    const tooltip = el.querySelector('.dashboard-tour__tooltip');
    expect(tooltip.classList.contains('is-entering')).toBe(false);
  });

  test('beginStepEnter hides the card until the next frame releases it', () => {
    // Do NOT run rAF callbacks: the card must stay hidden until repositioned.
    vi.stubGlobal('requestAnimationFrame', () => 1);
    const el = buildOverlay(null, null);
    const hook = makeHook(el);
    const tooltip = el.querySelector('.dashboard-tour__tooltip');

    hook.beginStepEnter();
    expect(tooltip.classList.contains('is-entering')).toBe(true);

    // finishStepEnter only schedules the release for the next frame, so the
    // card is still hidden until that frame actually runs.
    hook.finishStepEnter();
    expect(tooltip.classList.contains('is-entering')).toBe(true);
  });

  test('an unrelated patch with no step change does not re-fade', async () => {
    const el = buildOverlay('meetings', 'right');
    el.dataset.stepIndex = '2';
    const target = document.createElement('div');
    target.dataset.tour = 'meetings';
    document.body.appendChild(target);

    const hook = makeHook(el);
    await hook.position({ scroll: false });
    hook.lastStepIndex = '2';

    const beginSpy = vi.spyOn(hook, 'beginStepEnter');
    const positionSpy = vi.spyOn(hook, 'position');
    hook.updated();

    expect(beginSpy).not.toHaveBeenCalled();
    expect(positionSpy).not.toHaveBeenCalled();
  });
});
