/**
 * Tests for the reveal request (reveal_into_view.js): a target is scrolled
 * to the top unless it sits in the top third with the field under it wholly
 * in view; nothing scrolls before the observer reports, a page inside a
 * frame checks again once the frame has resized and held its size, a scroll
 * the end of the page cut short is finished once the page has grown, and a
 * framed page whose own document scrolls never moves the embedding page.
 */

import { describe, expect, test, beforeEach, afterEach, vi } from 'vitest';
import { installRevealIntoView, REVEAL_EVENT, FRAME_SETTLE_MS } from '../reveal_into_view';

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
    vi.useFakeTimers();
    vi.spyOn(window, 'top', 'get').mockReturnValue({});
    geometry.set(heading, { ratio: 1, top: 73 });
    geometry.set(field, { ratio: 1, top: 280 });

    dispatch();
    observers[0].report();
    expect(heading.scrollIntoView).not.toHaveBeenCalled();

    // The frame grows, in steps, and the heading is now below the embedding
    // page's fold.
    geometry.set(heading, { ratio: 0, top: 1028 });
    geometry.set(field, { ratio: 0, top: 1248 });
    window.dispatchEvent(new Event('resize'));
    vi.advanceTimersByTime(FRAME_SETTLE_MS - 1);
    window.dispatchEvent(new Event('resize'));
    vi.advanceTimersByTime(FRAME_SETTLE_MS - 1);

    // Not while the frame is still growing: a frame shorter than its page
    // would pass for a modal.
    expect(observers).toHaveLength(1);
    vi.advanceTimersByTime(1);

    // Once it has held its size, one check.
    expect(observers).toHaveLength(2);
    observers[1].report();
    expect(heading.scrollIntoView).toHaveBeenCalledTimes(1);

    vi.runAllTimers();
    vi.useRealTimers();
  });

  describe('a scroll cut short by the end of the page', () => {
    // A stand-in ResizeObserver the test triggers, as the document grows.
    let resized;
    let scrollHeight;
    let scrollY;
    let scrollTo;

    class FakeResizeObserver {
      constructor(callback) {
        this.callback = callback;
        this.observing = false;
        resized = this;
      }

      observe() {
        this.observing = true;
      }

      disconnect() {
        this.observing = false;
      }

      grow(height) {
        scrollHeight = height;
        if (this.observing) this.callback([]);
      }
    }

    beforeEach(() => {
      vi.useFakeTimers();
      resized = null;
      window.ResizeObserver = FakeResizeObserver;
      vi.spyOn(window, 'top', 'get').mockReturnValue({});
      // A modal embed: the frame's own document scrolls, and is only 300px
      // longer than the view while the times below the heading still load.
      scrollHeight = window.innerHeight + 300;
      scrollY = 0;
      Object.defineProperty(document.documentElement, 'scrollHeight', {
        configurable: true,
        get: () => scrollHeight,
      });
      Object.defineProperty(window, 'scrollY', { configurable: true, get: () => scrollY });
      scrollTo = vi.spyOn(window, 'scrollTo').mockImplementation(() => {});
      heading.getBoundingClientRect = () => ({ top: 900 - scrollY });
      geometry.set(heading, { ratio: 0, top: 900 });
    });

    afterEach(() => {
      vi.runAllTimers();
      vi.useRealTimers();
      delete window.ResizeObserver;
      delete document.documentElement.scrollHeight;
      delete window.scrollY;
    });

    test('is finished once the page has grown enough', () => {
      dispatch({});
      observers[0].report();
      expect(scrollTo).toHaveBeenCalledTimes(1);

      // Still too short: the heading cannot reach the top yet.
      resized.grow(window.innerHeight + 600);
      expect(scrollTo).toHaveBeenCalledTimes(1);

      resized.grow(window.innerHeight + 1200);
      expect(scrollTo).toHaveBeenCalledTimes(2);
      expect(scrollTo).toHaveBeenLastCalledWith({ top: 900, left: window.scrollX });
      expect(resized.observing).toBe(false);
    });

    test('is left alone once the visitor scrolls for themselves', () => {
      dispatch({});
      observers[0].report();

      window.dispatchEvent(new Event('wheel'));
      expect(resized.observing).toBe(false);
    });

    test('is not waited for when the page is long enough', () => {
      scrollHeight = window.innerHeight + 1200;

      dispatch({});
      observers[0].report();

      expect(scrollTo).toHaveBeenCalledTimes(1);
      expect(resized).toBeNull();
    });
  });

  describe('inside a frame', () => {
    let scrollTo;

    beforeEach(() => {
      vi.useFakeTimers();
      vi.spyOn(window, 'top', 'get').mockReturnValue({});
      scrollTo = vi.spyOn(window, 'scrollTo').mockImplementation(() => {});
      geometry.set(heading, { ratio: 1, top: 520 });
      geometry.set(field, { ratio: 0.2, top: 680 });
    });

    afterEach(() => {
      // Let the wait for the frame's resize lapse, dropping its listener.
      vi.runAllTimers();
      vi.useRealTimers();
      delete document.documentElement.scrollHeight;
      delete window.scrollY;
    });

    test('whose document scrolls, scrolls that document alone, never the page around it', () => {
      // A modal embed: the frame is capped, and its own page scrolls inside it.
      Object.defineProperty(document.documentElement, 'scrollHeight', {
        configurable: true,
        value: window.innerHeight + 900,
      });
      Object.defineProperty(window, 'scrollY', { configurable: true, value: 150 });
      heading.style.scrollMarginTop = '24px';
      heading.getBoundingClientRect = () => ({ top: 520 });

      dispatch();
      observers[0].report();

      expect(heading.scrollIntoView).not.toHaveBeenCalled();
      expect(scrollTo).toHaveBeenCalledWith({ top: 150 + 520 - 24, left: window.scrollX });
    });

    test('as tall as its page, asks the embedding page to scroll', () => {
      // An inline embed: the frame has grown to its page, so only the
      // embedding page can bring the heading up.
      Object.defineProperty(document.documentElement, 'scrollHeight', {
        configurable: true,
        value: window.innerHeight,
      });

      dispatch();
      observers[0].report();

      expect(scrollTo).not.toHaveBeenCalled();
      expect(heading.scrollIntoView).toHaveBeenCalledWith({ block: 'start', inline: 'nearest' });
    });
  });

  test('a top-level page does not wait for a resize', () => {
    geometry.set(heading, { ratio: 1, top: 73 });
    geometry.set(field, { ratio: 1, top: 280 });

    dispatch();
    window.dispatchEvent(new Event('resize'));

    expect(observers).toHaveLength(1);
  });
});
