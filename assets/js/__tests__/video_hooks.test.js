/**
 * Tests for the slow-connection detector in video_hooks.js.
 *
 * The decision to load the background videos hinges on this single function,
 * and the thresholds are easy to get wrong silently. Each branch is exercised
 * here so a regression (e.g. flipping a `<` to `<=`) breaks the build.
 */

import { beforeEach, describe, expect, test, vi } from 'vitest';
import {
  AuthVideo,
  BackgroundMotionToggle,
  QuillVideo,
  RhythmVideo,
  backgroundMotionStopped,
  isSlowConnection,
} from '../video_hooks';

describe('isSlowConnection', () => {
  test('returns false when the API is unavailable (no connection object)', () => {
    expect(isSlowConnection(null)).toBe(false);
    expect(isSlowConnection(undefined)).toBe(false);
  });

  test('returns true when the user has Data Saver enabled', () => {
    // saveData wins regardless of other fields — respect the user's preference.
    expect(isSlowConnection({ saveData: true })).toBe(true);
    expect(
      isSlowConnection({ saveData: true, effectiveType: '4g', downlink: 50, rtt: 10 })
    ).toBe(true);
  });

  test.each([
    ['slow-2g', true],
    ['2g', true],
    ['3g', false],
    ['4g', false],
    ['', false],
  ])('effectiveType "%s" → slow=%s', (effectiveType, expected) => {
    expect(isSlowConnection({ effectiveType })).toBe(expected);
  });

  describe('downlink threshold (< 1.5 Mbps is slow)', () => {
    test('1.49 Mbps → slow', () => {
      expect(isSlowConnection({ downlink: 1.49 })).toBe(true);
    });

    test('1.5 Mbps → not slow (boundary is strict <)', () => {
      expect(isSlowConnection({ downlink: 1.5 })).toBe(false);
    });

    test('5 Mbps → not slow', () => {
      expect(isSlowConnection({ downlink: 5 })).toBe(false);
    });

    test('downlink: 0 → slow', () => {
      expect(isSlowConnection({ downlink: 0 })).toBe(true);
    });

    test('non-numeric downlink is ignored', () => {
      expect(isSlowConnection({ downlink: null })).toBe(false);
      expect(isSlowConnection({ downlink: 'fast' })).toBe(false);
      expect(isSlowConnection({ downlink: undefined })).toBe(false);
    });
  });

  describe('RTT threshold (> 300ms is slow)', () => {
    test('301ms → slow', () => {
      expect(isSlowConnection({ rtt: 301 })).toBe(true);
    });

    test('300ms → not slow (boundary is strict >)', () => {
      expect(isSlowConnection({ rtt: 300 })).toBe(false);
    });

    test('50ms → not slow', () => {
      expect(isSlowConnection({ rtt: 50 })).toBe(false);
    });

    test('non-numeric rtt is ignored', () => {
      expect(isSlowConnection({ rtt: null })).toBe(false);
      expect(isSlowConnection({ rtt: 'slow' })).toBe(false);
      expect(isSlowConnection({ rtt: undefined })).toBe(false);
    });
  });

  test('healthy 4g connection → not slow', () => {
    expect(
      isSlowConnection({
        saveData: false,
        effectiveType: '4g',
        downlink: 10,
        rtt: 50,
      })
    ).toBe(false);
  });

  test('4g labelled but slow downlink → slow (catches slow WiFi)', () => {
    // The motivating case: device reports "4g" but downlink says otherwise.
    expect(
      isSlowConnection({
        saveData: false,
        effectiveType: '4g',
        downlink: 0.8,
        rtt: 80,
      })
    ).toBe(true);
  });

  test('4g labelled but high RTT → slow', () => {
    expect(
      isSlowConnection({
        saveData: false,
        effectiveType: '4g',
        downlink: 10,
        rtt: 450,
      })
    ).toBe(true);
  });

  test('empty object → not slow', () => {
    expect(isSlowConnection({})).toBe(false);
  });
});

/**
 * The background-video pause control (WCAG 2.2.2).
 *
 * The behaviour that matters is entirely client-side — the server renders one
 * fixed state and the hook corrects it — so these are the only tests that can
 * cover the stored preference at all.
 */
describe('background motion preference', () => {
  const mountToggle = () => {
    document.body.innerHTML = `
      <button id="background-motion-toggle"
              data-state="playing"
              data-label-pause="Pause background video"
              data-label-play="Play background video"
              aria-label="Pause background video"></button>
    `;

    const el = document.getElementById('background-motion-toggle');
    const hook = Object.create(BackgroundMotionToggle);
    hook.el = el;
    hook.mounted();

    return { el, hook };
  };

  beforeEach(() => {
    window.localStorage.clear();
    document.body.innerHTML = '';
  });

  test('defaults to playing when nothing has been stored', () => {
    expect(backgroundMotionStopped()).toBe(false);
  });

  test('reports stopped when the visitor stopped the background before', () => {
    window.localStorage.setItem('tymeslot:background-motion', 'stopped');

    expect(backgroundMotionStopped()).toBe(true);
  });

  test('survives localStorage throwing rather than breaking the page', () => {
    // Safari in private mode and blocked-cookie setups throw on access.
    const getItem = vi
      .spyOn(Storage.prototype, 'getItem')
      .mockImplementation(() => {
        throw new Error('SecurityError');
      });

    expect(backgroundMotionStopped()).toBe(false);

    getItem.mockRestore();
  });

  test('clicking stops the background and relabels the control', () => {
    const { el } = mountToggle();

    el.click();

    expect(backgroundMotionStopped()).toBe(true);
    expect(el.dataset.state).toBe('stopped');
    // The accessible name has to describe what the next press does.
    expect(el.getAttribute('aria-label')).toBe('Play background video');
  });

  test('clicking again resumes it', () => {
    const { el } = mountToggle();

    el.click();
    el.click();

    expect(backgroundMotionStopped()).toBe(false);
    expect(el.dataset.state).toBe('playing');
    expect(el.getAttribute('aria-label')).toBe('Pause background video');
  });

  test('a click broadcasts the change so the video hooks can react', () => {
    const { el } = mountToggle();
    const listener = vi.fn();
    window.addEventListener('tymeslot:background-motion', listener);

    el.click();

    expect(listener).toHaveBeenCalledTimes(1);
    expect(listener.mock.calls[0][0].detail).toEqual({ stopped: true });

    window.removeEventListener('tymeslot:background-motion', listener);
  });

  test('renders the stored state on mount, not the server-rendered default', () => {
    window.localStorage.setItem('tymeslot:background-motion', 'stopped');

    const { el } = mountToggle();

    expect(el.dataset.state).toBe('stopped');
    expect(el.getAttribute('aria-label')).toBe('Play background video');
  });

  test('a LiveView patch cannot revert the control to the server default', () => {
    const { el, hook } = mountToggle();

    el.click();
    // What a step transition does: re-render the wrapper's markup.
    el.dataset.state = 'playing';
    el.setAttribute('aria-label', 'Pause background video');
    hook.updated();

    expect(el.dataset.state).toBe('stopped');
    expect(el.getAttribute('aria-label')).toBe('Play background video');
  });

  test('destroyed detaches the click handler', () => {
    const { el, hook } = mountToggle();

    hook.destroyed();
    el.click();

    expect(backgroundMotionStopped()).toBe(false);
  });
});

/**
 * The video hooks have to honour the stored preference on mount, not only when
 * the button is pressed: a visitor who stopped the background on the overview
 * step must not have it start again on the next step.
 */
describe('video hooks honour a stopped background', () => {
  // jsdom implements no media playback, so the elements are stubbed down to the
  // surface the hooks actually touch.
  const stubVideo = (el) => {
    el.play = vi.fn(() => Promise.resolve());
    el.pause = vi.fn();
    return el;
  };

  const mount = (hook, el) => {
    const instance = Object.create(hook);
    instance.el = el;
    instance.mounted();
    return instance;
  };

  const rhythmMarkup = `
    <div class="video-background-container" id="rhythm">
      <video id="rhythm-background-video-1"></video>
      <video id="rhythm-background-video-2"></video>
    </div>
  `;

  beforeEach(() => {
    window.localStorage.clear();
    document.body.innerHTML = '';
    document.documentElement.removeAttribute('data-embedded');
    window.matchMedia = vi.fn(() => ({
      matches: false,
      addEventListener() {},
      removeEventListener() {},
    }));
    // jsdom ships neither of these; Rhythm's visibility pause needs the first.
    window.IntersectionObserver = vi.fn(() => ({
      observe() {},
      disconnect() {},
    }));
  });

  test('Quill pauses the background when the visitor has stopped it', () => {
    window.localStorage.setItem('tymeslot:background-motion', 'stopped');
    document.body.innerHTML = '<div id="quill"><video></video></div>';

    const container = document.getElementById('quill');
    const video = stubVideo(container.querySelector('video'));
    video.setAttribute('autoplay', '');

    mount(QuillVideo, container);

    expect(video.pause).toHaveBeenCalled();
    // Left in place, the attribute restarts playback on the next source change.
    expect(video.hasAttribute('autoplay')).toBe(false);
  });

  test('Quill leaves the background running by default', () => {
    document.body.innerHTML = '<div id="quill"><video></video></div>';

    const container = document.getElementById('quill');
    const video = stubVideo(container.querySelector('video'));

    mount(QuillVideo, container);

    expect(video.pause).not.toHaveBeenCalled();
  });

  test('Rhythm never starts its crossfade when the visitor has stopped it', () => {
    window.localStorage.setItem('tymeslot:background-motion', 'stopped');
    document.body.innerHTML = rhythmMarkup;

    const video1 = stubVideo(document.getElementById('rhythm-background-video-1'));
    const video2 = stubVideo(document.getElementById('rhythm-background-video-2'));

    mount(RhythmVideo, document.getElementById('rhythm'));

    expect(video1.play).not.toHaveBeenCalled();
    expect(video2.play).not.toHaveBeenCalled();
  });

  test('Rhythm starts the first video by default', () => {
    document.body.innerHTML = rhythmMarkup;

    const video1 = stubVideo(document.getElementById('rhythm-background-video-1'));
    stubVideo(document.getElementById('rhythm-background-video-2'));

    mount(RhythmVideo, document.getElementById('rhythm'));

    expect(video1.play).toHaveBeenCalled();
  });

  const authMarkup = `
    <div class="video-background-container" id="auth-video-container">
      <video id="auth-background-video-1"></video>
      <video id="auth-background-video-2"></video>
    </div>
  `;

  test('Auth never starts its crossfade when the visitor has stopped it', () => {
    window.localStorage.setItem('tymeslot:background-motion', 'stopped');
    document.body.innerHTML = authMarkup;

    const video1 = stubVideo(document.getElementById('auth-background-video-1'));
    const video2 = stubVideo(document.getElementById('auth-background-video-2'));

    mount(AuthVideo, document.getElementById('auth-video-container'));

    expect(video1.play).not.toHaveBeenCalled();
    expect(video2.play).not.toHaveBeenCalled();
  });

  test('Auth pauses the running video when the preference flips mid-visit', () => {
    document.body.innerHTML = authMarkup;

    const video1 = stubVideo(document.getElementById('auth-background-video-1'));
    stubVideo(document.getElementById('auth-background-video-2'));

    mount(AuthVideo, document.getElementById('auth-video-container'));

    window.dispatchEvent(
      new CustomEvent('tymeslot:background-motion', { detail: { stopped: true } })
    );

    expect(video1.pause).toHaveBeenCalled();
  });

  test('reduced motion hides the control, which would otherwise pause nothing', () => {
    window.matchMedia = vi.fn(() => ({
      matches: true,
      addEventListener() {},
      removeEventListener() {},
    }));

    document.body.innerHTML = `
      <div id="quill"><video></video></div>
      <button id="background-motion-toggle"></button>
    `;

    const container = document.getElementById('quill');
    stubVideo(container.querySelector('video'));

    mount(QuillVideo, container);

    expect(document.getElementById('background-motion-toggle').hidden).toBe(true);
  });

  test('Auth hides the control when the page carries no video to pause', () => {
    document.body.innerHTML = `
      <div class="video-background-container" id="auth-video-container"></div>
      <button id="background-motion-toggle"></button>
    `;

    mount(AuthVideo, document.getElementById('auth-video-container'));

    expect(document.getElementById('background-motion-toggle').hidden).toBe(true);
  });

  test('Rhythm hides the control when its video pair is missing', () => {
    document.body.innerHTML = `
      <div class="video-background-container" id="rhythm"></div>
      <button id="background-motion-toggle"></button>
    `;

    mount(RhythmVideo, document.getElementById('rhythm'));

    expect(document.getElementById('background-motion-toggle').hidden).toBe(true);
  });

  // The verdict is module state, so a healthy page mounted after a broken one
  // must not inherit "no video here".
  test('a later healthy mount restores the control', () => {
    document.body.innerHTML = `
      <div class="video-background-container" id="rhythm"></div>
      <button id="background-motion-toggle"></button>
    `;

    mount(RhythmVideo, document.getElementById('rhythm'));
    expect(document.getElementById('background-motion-toggle').hidden).toBe(true);

    document.body.innerHTML = `
      <div id="quill"><video></video></div>
      <button id="background-motion-toggle"
              data-state="playing"
              data-label-pause="Pause background video"
              data-label-play="Play background video"></button>
    `;

    const container = document.getElementById('quill');
    stubVideo(container.querySelector('video'));
    mount(QuillVideo, container);

    const toggle = document.getElementById('background-motion-toggle');
    mount(BackgroundMotionToggle, toggle);

    expect(toggle.hidden).toBe(false);
  });

  // LiveView re-renders the wrapper on a step transition, and the server markup
  // carries no `hidden` — so the patch strips what the video hook set.
  test('the control stays hidden across a LiveView patch', () => {
    window.matchMedia = vi.fn(() => ({
      matches: true,
      addEventListener() {},
      removeEventListener() {},
    }));

    document.body.innerHTML = `
      <div id="quill"><video></video></div>
      <button id="background-motion-toggle"
              data-state="playing"
              data-label-pause="Pause background video"
              data-label-play="Play background video"></button>
    `;

    const container = document.getElementById('quill');
    stubVideo(container.querySelector('video'));
    mount(QuillVideo, container);

    const toggle = document.getElementById('background-motion-toggle');
    const hook = mount(BackgroundMotionToggle, toggle);

    // What morphdom does with an attribute the server never rendered.
    toggle.hidden = false;
    hook.updated();

    expect(toggle.hidden).toBe(true);
  });
});
