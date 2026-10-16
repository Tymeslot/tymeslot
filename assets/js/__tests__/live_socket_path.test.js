import { liveSocketPath, topLevelEmbedRedirect } from '../live_socket_path';
import { afterEach, describe, expect, test } from 'vitest';

// A stand-in window: `self`/`top` decide whether the page is framed, and the
// real jsdom document carries (or not) the server's embed marker.
function fakeWindow({ framed, href = 'http://localhost/sarah' }) {
  const win = { document, location: { href } };
  win.self = win;
  win.top = framed ? {} : win;
  return win;
}

describe('liveSocketPath', () => {
  afterEach(() => {
    document.documentElement.removeAttribute('data-embed-served');
  });

  test('a top-level page not served as an embed uses /live', () => {
    expect(liveSocketPath(fakeWindow({ framed: false }))).toBe('/live');
  });

  test('a framed page uses /embed-live', () => {
    expect(liveSocketPath(fakeWindow({ framed: true }))).toBe('/embed-live');
  });

  test('a page served as an embed uses /embed-live even when not framed', () => {
    document.documentElement.setAttribute('data-embed-served', '');
    expect(liveSocketPath(fakeWindow({ framed: false }))).toBe('/embed-live');
  });
});

describe('topLevelEmbedRedirect', () => {
  const embedUrl =
    'http://booking.test/sarah/30-min?embed=1&parent-origin=https%3A%2F%2Fsite.test&theme=2&layout=column#top';

  afterEach(() => {
    document.documentElement.removeAttribute('data-embed-served');
  });

  test('a page served as an embed but opened in its own tab drops the embed parameters', () => {
    document.documentElement.setAttribute('data-embed-served', '');

    expect(topLevelEmbedRedirect(fakeWindow({ framed: false, href: embedUrl }))).toBe(
      'http://booking.test/sarah/30-min?theme=2&layout=column#top'
    );
  });

  test('a framed embed stays where it is', () => {
    document.documentElement.setAttribute('data-embed-served', '');

    expect(topLevelEmbedRedirect(fakeWindow({ framed: true, href: embedUrl }))).toBeNull();
  });

  test('a page not served as an embed stays where it is', () => {
    expect(topLevelEmbedRedirect(fakeWindow({ framed: false, href: embedUrl }))).toBeNull();
  });
});
