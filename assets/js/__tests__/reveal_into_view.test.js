/**
 * Tests for the reveal request (reveal_into_view.js): a target is scrolled
 * to the top unless it sits in the top third with the field under it wholly
 * in view; nothing scrolls before the observer reports, and a page inside a
 * frame checks again once the frame has resized.
 */

import { describe, expect, test, beforeEach, afterEach, vi } from 'vitest';
import { installRevealIntoView, REVEAL_EVENT } from '../reveal_into_view';

// A stand-in IntersectionObserver whose reports the test writes: each
// observed element is reported with the ratio and top the test gave it.
let geometry;
let observers;

class FakeObserver {
  constructor(callback) {
    this.callback = callback;
    this.targets = [];
    this.disconnected = false;
    observers.push(this);
  }

  observe(el) {
    this.targets.push(el);
  }

  disconnect() {
    this.disconnected = true;
  }

  report() {
    this.callback(
      this.targets.map((target) => ({
        target,
        intersectionRatio: geometry.get(target).ratio,
        boundingClientRect: { top: geometry.get(target).top },
      }))
    );
  }
}

let uninstall;
let heading;
let field;

function dispatch(detail = { until: '#field' }) {
  heading.dispatchEvent(new CustomEvent(REVEAL_EVENT, { bubbles: true, detail }));
}

beforeEach(() => {
  geometry = new Map();
  observers = [];
  window.IntersectionObserver = FakeObserver;
  document.body.innerHTML = '<h2 id="heading">Enter your details</h2><input id="field">';
  heading = document.getElementById('heading');
  field = document.getElementById('field');
  heading.scrollIntoView = vi.fn();
  uninstall = installRevealIntoView();
});

afterEach(() => {
  uninstall();
  delete window.IntersectionObserver;
  vi.restoreAllMocks();
});

describe('reveal request', () => {
  test('scrolls the target to the top when the field under it is cut off', () => {
    geometry.set(heading, { ratio: 1, top: 700 });
    geometry.set(field, { ratio: 0.4, top: 760 });

    dispatch();
    expect(heading.scrollIntoView).not.toHaveBeenCalled();
    observers[0].report();

    expect(heading.scrollIntoView).toHaveBeenCalledWith({ block: 'start', inline: 'nearest' });
    expect(observers[0].disconnected).toBe(true);
  });

  test('scrolls a target in view but below the top third', () => {
    geometry.set(heading, { ratio: 1, top: window.innerHeight / 2 });
    geometry.set(field, { ratio: 1, top: window.innerHeight / 2 + 50 });

    dispatch();
    observers[0].report();

    expect(heading.scrollIntoView).toHaveBeenCalledTimes(1);
  });

  test('leaves a settled target where it is', () => {
    geometry.set(heading, { ratio: 1, top: 73 });
    geometry.set(field, { ratio: 1, top: 280 });

    dispatch();
    observers[0].report();

    expect(heading.scrollIntoView).not.toHaveBeenCalled();
  });

  test('watches the target alone when the field is not on the page', () => {
    geometry.set(heading, { ratio: 0, top: 900 });

    dispatch({ until: '#missing' });

    expect(observers[0].targets).toEqual([heading]);
    observers[0].report();
    expect(heading.scrollIntoView).toHaveBeenCalledTimes(1);
  });

  test('an event from anywhere but an element does nothing', () => {
    window.dispatchEvent(new CustomEvent(REVEAL_EVENT, { detail: {} }));
    expect(observers).toEqual([]);
  });

  test('inside a frame, checks again once the frame has resized', () => {
    vi.spyOn(window, 'top', 'get').mockReturnValue({});
    geometry.set(heading, { ratio: 1, top: 73 });
    geometry.set(field, { ratio: 1, top: 280 });

    dispatch();
    observers[0].report();
    expect(heading.scrollIntoView).not.toHaveBeenCalled();

    // The frame grows, and the heading is now below the embedding page's fold.
    geometry.set(heading, { ratio: 0, top: 1028 });
    geometry.set(field, { ratio: 0, top: 1248 });
    window.dispatchEvent(new Event('resize'));

    expect(observers).toHaveLength(2);
    observers[1].report();
    expect(heading.scrollIntoView).toHaveBeenCalledTimes(1);

    // Only the first resize after the request counts.
    window.dispatchEvent(new Event('resize'));
    expect(observers).toHaveLength(2);
  });

  test('a top-level page does not wait for a resize', () => {
    geometry.set(heading, { ratio: 1, top: 73 });
    geometry.set(field, { ratio: 1, top: 280 });

    dispatch();
    window.dispatchEvent(new Event('resize'));

    expect(observers).toHaveLength(1);
  });
});
