/**
 * The delegated copy button (docs code blocks): a click copies the text and
 * says so through the shared `tymeslot:clip-copy` toast, in the success and
 * the failure case alike, including a context with no clipboard at all.
 */

import { afterEach, beforeAll, beforeEach, describe, expect, test, vi } from 'vitest';
import { installClipboardCopy } from '../clipboard_copy';

function button(attrs = {}) {
  const el = document.createElement('button');
  el.textContent = 'Copy';
  el.setAttribute('data-clipboard-text', 'npm install');
  Object.entries(attrs).forEach(([k, v]) => el.setAttribute(k, v));
  document.body.appendChild(el);
  return el;
}

describe('clipboard copy button', () => {
  let toasts;
  const listener = (e) => toasts.push(e.detail);

  beforeAll(() => installClipboardCopy());

  beforeEach(() => {
    document.body.innerHTML = '';
    toasts = [];
    window.addEventListener('tymeslot:clip-copy', listener);
  });

  afterEach(() => {
    window.removeEventListener('tymeslot:clip-copy', listener);
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  test('a successful copy writes the text, toasts and swaps the label for a moment', async () => {
    vi.useFakeTimers();
    const writeText = vi.fn().mockResolvedValue();
    vi.stubGlobal('navigator', { clipboard: { writeText } });

    const el = button({
      'data-clipboard-copied': 'Copied',
      'data-clipboard-success': 'Copied to clipboard'
    });
    el.click();
    await vi.advanceTimersByTimeAsync(0);

    expect(writeText).toHaveBeenCalledWith('npm install');
    expect(toasts).toEqual([{ message: 'Copied to clipboard', kind: 'info' }]);
    expect(el.textContent).toBe('Copied');

    vi.advanceTimersByTime(2000);
    expect(el.textContent).toBe('Copy');
  });

  test('a second click while the label is swapped still restores the original label', async () => {
    vi.useFakeTimers();
    vi.stubGlobal('navigator', { clipboard: { writeText: vi.fn().mockResolvedValue() } });

    const el = button({ 'data-clipboard-copied': 'Copied' });
    el.click();
    await vi.advanceTimersByTimeAsync(0);
    el.click();
    await vi.advanceTimersByTimeAsync(0);
    vi.advanceTimersByTime(2000);

    expect(el.textContent).toBe('Copy');
  });

  test('a refused write toasts an error and leaves the label alone', async () => {
    const writeText = vi.fn().mockRejectedValue(new Error('denied'));
    vi.stubGlobal('navigator', { clipboard: { writeText } });

    const el = button({
      'data-clipboard-copied': 'Copied',
      'data-clipboard-failure': 'Could not copy'
    });
    el.click();
    await vi.waitFor(() => expect(toasts).toHaveLength(1));

    expect(toasts[0]).toEqual({ message: 'Could not copy', kind: 'error' });
    expect(el.textContent).toBe('Copy');
  });

  test('no clipboard at all (an insecure context) toasts an error instead of doing nothing', () => {
    vi.stubGlobal('navigator', {});

    button().click();

    expect(toasts).toHaveLength(1);
    expect(toasts[0].kind).toBe('error');
    expect(toasts[0].message).not.toBe('');
  });

  test('an element without the attribute is ignored', () => {
    const writeText = vi.fn().mockResolvedValue();
    vi.stubGlobal('navigator', { clipboard: { writeText } });

    const el = document.createElement('button');
    document.body.appendChild(el);
    el.click();

    expect(writeText).not.toHaveBeenCalled();
    expect(toasts).toEqual([]);
  });
});
