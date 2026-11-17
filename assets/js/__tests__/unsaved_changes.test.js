/**
 * Tests for the `UnsavedChanges` hook (hooks/unsaved_changes.js).
 *
 * An autosaving form sends a field when it loses focus, so the one way to
 * lose typed text is to close or reload the tab mid-edit. The hook asks
 * first, until the server confirms that what the form shows is stored.
 */

import { describe, expect, test, beforeEach, afterEach } from 'vitest';
import { UnsavedChanges } from '../hooks/unsaved_changes';

function mount(id = 'intro-form') {
  const form = document.createElement('form');
  form.id = id;
  const input = document.createElement('input');
  form.appendChild(input);
  document.body.appendChild(form);

  const handlers = {};
  const hook = Object.assign(Object.create(UnsavedChanges), {
    el: form,
    handleEvent: (name, fn) => {
      handlers[name] = fn;
    },
  });
  hook.mounted();

  return {
    hook,
    type: () => input.dispatchEvent(new Event('input', { bubbles: true })),
    leave: () => input.dispatchEvent(new FocusEvent('focusout', { bubbles: true })),
    clean: (formId = id) => handlers['autosave:clean']({ id: formId }),
  };
}

function unloadIsBlocked() {
  const event = new Event('beforeunload', { cancelable: true });
  window.dispatchEvent(event);
  return event.defaultPrevented;
}

describe('UnsavedChanges', () => {
  let mounted;

  beforeEach(() => {
    mounted = mount();
  });

  afterEach(() => {
    mounted.hook.destroyed();
    document.body.innerHTML = '';
  });

  test('lets the tab close when nothing was typed', () => {
    expect(unloadIsBlocked()).toBe(false);
  });

  test('asks before the tab closes while typed text is unsaved', () => {
    mounted.type();
    expect(unloadIsBlocked()).toBe(true);
  });

  test('stops asking once the server confirms the save', () => {
    mounted.type();
    mounted.leave();
    mounted.clean();
    expect(unloadIsBlocked()).toBe(false);
  });

  test('ignores a confirmation meant for another form', () => {
    mounted.type();
    mounted.leave();
    mounted.clean('legal-links-form');
    expect(unloadIsBlocked()).toBe(true);
  });

  test('keeps asking when more was typed after the field was sent', () => {
    mounted.type();
    mounted.leave();
    mounted.type();
    mounted.clean();
    expect(unloadIsBlocked()).toBe(true);
  });

  test('no longer asks once the form is gone', () => {
    mounted.type();
    mounted.hook.destroyed();
    expect(unloadIsBlocked()).toBe(false);
  });
});
