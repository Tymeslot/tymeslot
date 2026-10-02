/**
 * Tests for the `ScrollStrip` hook (hooks/scroll_strip.js), which marks the
 * clipped edges of a sideways-scrolling tab strip or segmented control and
 * gives a tablist its arrow-key navigation.
 */

import { describe, expect, test, afterEach, vi } from 'vitest';
import { ScrollStrip, overflowEdges, nextTabIndex } from '../hooks/scroll_strip';

describe('overflowEdges', () => {
  test('is null when everything fits', () => {
    expect(overflowEdges({ scrollLeft: 0, scrollWidth: 300, clientWidth: 300 })).toBeNull();
  });

  test('marks the end while more lies to the right', () => {
    expect(overflowEdges({ scrollLeft: 0, scrollWidth: 500, clientWidth: 300 })).toBe('end');
  });

  test('marks both edges part way along', () => {
    expect(overflowEdges({ scrollLeft: 100, scrollWidth: 500, clientWidth: 300 })).toBe('both');
  });

  test('marks the start once scrolled to the end', () => {
    expect(overflowEdges({ scrollLeft: 200, scrollWidth: 500, clientWidth: 300 })).toBe('start');
  });

  test('ignores sub-pixel rounding', () => {
    expect(overflowEdges({ scrollLeft: 0.5, scrollWidth: 300.5, clientWidth: 300 })).toBeNull();
  });
});

describe('nextTabIndex', () => {
  test('moves right and left, wrapping round', () => {
    expect(nextTabIndex('ArrowRight', 0, 3)).toBe(1);
    expect(nextTabIndex('ArrowRight', 2, 3)).toBe(0);
    expect(nextTabIndex('ArrowLeft', 0, 3)).toBe(2);
  });

  test('jumps to either end', () => {
    expect(nextTabIndex('Home', 2, 3)).toBe(0);
    expect(nextTabIndex('End', 0, 3)).toBe(2);
  });

  test('ignores other keys', () => {
    expect(nextTabIndex('Enter', 0, 3)).toBeNull();
  });
});

function buildTablist() {
  const el = document.createElement('div');
  el.setAttribute('role', 'tablist');

  const tabs = ['a', 'b', 'c'].map((id, index) => {
    const tab = document.createElement('button');
    tab.setAttribute('role', 'tab');
    tab.id = `tab-${id}`;
    tab.setAttribute('aria-selected', String(index === 0));
    el.appendChild(tab);
    return tab;
  });

  document.body.appendChild(el);
  return { el, tabs };
}

function mount(el) {
  const hook = Object.assign(Object.create(ScrollStrip), { el });
  hook.mounted();
  return hook;
}

describe('ScrollStrip hook', () => {
  afterEach(() => {
    document.body.innerHTML = '';
  });

  test('ArrowRight focuses and selects the next tab', () => {
    const { el, tabs } = buildTablist();
    const clicked = vi.fn();
    tabs[1].addEventListener('click', clicked);
    mount(el);

    tabs[0].focus();
    tabs[0].dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }));

    expect(document.activeElement).toBe(tabs[1]);
    expect(clicked).toHaveBeenCalledTimes(1);
  });

  test('skips disabled tabs', () => {
    const { el, tabs } = buildTablist();
    tabs[1].disabled = true;
    mount(el);

    tabs[0].focus();
    tabs[0].dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }));

    expect(document.activeElement).toBe(tabs[2]);
  });

  test('leaves the arrow keys alone outside a tablist', () => {
    const { el, tabs } = buildTablist();
    el.setAttribute('role', 'group');
    mount(el);

    tabs[0].focus();
    tabs[0].dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }));

    expect(document.activeElement).toBe(tabs[0]);
  });

  test('marks and clears the overflow as the strip scrolls', () => {
    const { el } = buildTablist();
    Object.defineProperty(el, 'scrollWidth', { value: 500, configurable: true });
    Object.defineProperty(el, 'clientWidth', { value: 300, configurable: true });
    mount(el);

    expect(el.dataset.overflow).toBe('end');

    el.scrollLeft = 200;
    el.dispatchEvent(new Event('scroll'));
    expect(el.dataset.overflow).toBe('start');

    Object.defineProperty(el, 'scrollWidth', { value: 300, configurable: true });
    el.scrollLeft = 0;
    el.dispatchEvent(new Event('scroll'));
    expect(el.dataset.overflow).toBeUndefined();
  });

  test('stops listening once destroyed', () => {
    const { el, tabs } = buildTablist();
    const hook = mount(el);
    hook.destroyed();

    tabs[0].focus();
    tabs[0].dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }));

    expect(document.activeElement).toBe(tabs[0]);
  });

  test('updated() re-marks the overflow a patch removed', () => {
    const { el } = buildTablist();
    Object.defineProperty(el, 'scrollWidth', { value: 500, configurable: true });
    Object.defineProperty(el, 'clientWidth', { value: 300, configurable: true });
    const hook = mount(el);

    // A LiveView patch drops attributes the server did not render.
    delete el.dataset.overflow;
    hook.updated();

    expect(el.dataset.overflow).toBe('end');
  });

  describe('bringing the selected tab into view', () => {
    // jsdom lays nothing out, so the row is 100px wide and the tabs sit at
    // fixed offsets from its scroll position.
    function layOut(el, tabs) {
      el.getBoundingClientRect = () => ({ left: 0, right: 100 });
      tabs.forEach((tab, index) => {
        tab.getBoundingClientRect = () => {
          const left = index * 80 - el.scrollLeft;
          return { left, right: left + 80 };
        };
      });
    }

    function select(tabs, index) {
      tabs.forEach((tab, i) => tab.setAttribute('aria-selected', String(i === index)));
    }

    test('scrolls a selected tab past the edge into view on mount', () => {
      const { el, tabs } = buildTablist();
      layOut(el, tabs);
      select(tabs, 2);

      mount(el);

      // The third tab spans 160-240; the row shows 0-100.
      expect(el.scrollLeft).toBe(140);
    });

    test('leaves the scroll position alone when an update keeps the selection', () => {
      const { el, tabs } = buildTablist();
      layOut(el, tabs);
      select(tabs, 2);
      const hook = mount(el);

      // The reader scrolls back to the start to look at the other tabs.
      el.scrollLeft = 0;
      hook.updated();

      expect(el.scrollLeft).toBe(0);
    });

    test('scrolls again once the selection changes', () => {
      const { el, tabs } = buildTablist();
      layOut(el, tabs);
      select(tabs, 0);
      const hook = mount(el);
      expect(el.scrollLeft).toBe(0);

      select(tabs, 2);
      hook.updated();

      expect(el.scrollLeft).toBe(140);
    });
  });
});
