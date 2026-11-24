/**
 * Tests for the `UnsavedChanges` hook (hooks/unsaved_changes.js).
 *
 * An autosaving form sends a field when it loses focus, so the one way to
 * lose typed text is to close or reload the tab mid-edit. The hook asks
 * first, until the server confirms that what the form shows is stored.
 *
 * An explicit-submit editor (`data-leave-event`) also holds a LiveView link
 * clicked elsewhere, asks the server, and follows the link once told to.
 */

import { describe, expect, test, beforeEach, afterEach, vi } from 'vitest';
import { UnsavedChanges } from '../hooks/unsaved_changes';

function mount(id = 'intro-form', dataset = {}) {
  const form = document.createElement('form');
  form.id = id;
  Object.assign(form.dataset, dataset);
  const input = document.createElement('input');
  form.appendChild(input);
  document.body.appendChild(form);

  const handlers = {};
  const pushed = [];
  const hook = Object.assign(Object.create(UnsavedChanges), {
    el: form,
    handleEvent: (name, fn) => {
      handlers[name] = fn;
    },
    pushEventTo: (target, event, payload) => pushed.push({ target, event, payload }),
  });
  hook.mounted();

  return {
    hook,
    form,
    pushed,
    submit: () => form.dispatchEvent(new Event('submit', { bubbles: true })),
    proceed: () => handlers['unsaved:proceed']({}),
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

// A LiveView link outside the editor, recording whether LiveView (listening
// on window, as it does) would have followed each click.
function sidebarLink() {
  const link = document.createElement('a');
  link.href = '/dashboard/meetings';
  link.dataset.phxLink = 'patch';
  document.body.appendChild(link);
  // LiveView prevents the browser's own navigation for the links it follows.
  const followed = vi.fn((event) => event.preventDefault());
  window.addEventListener('click', followed);
  return {
    link,
    followed,
    click: (init = {}) =>
      link.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, ...init })),
    remove: () => window.removeEventListener('click', followed),
  };
}

describe('UnsavedChanges on an explicit-submit editor', () => {
  let editor;
  let sidebar;

  beforeEach(() => {
    editor = mount('poll-editor-1', { leaveEvent: 'leave', leaveTarget: '7' });
    sidebar = sidebarLink();
  });

  afterEach(() => {
    editor.hook.destroyed();
    sidebar.remove();
    document.body.innerHTML = '';
  });

  test('lets a link go when nothing was typed', () => {
    sidebar.click();
    expect(sidebar.followed).toHaveBeenCalledTimes(1);
    expect(editor.pushed).toEqual([]);
  });

  test('holds a link clicked while typed text is unsaved, and asks the server', () => {
    editor.type();
    sidebar.click();
    expect(sidebar.followed).not.toHaveBeenCalled();
    expect(editor.pushed).toEqual([{ target: '7', event: 'leave', payload: {} }]);
  });

  test('follows the held link once the server says so, without holding it again', () => {
    editor.type();
    sidebar.click();
    editor.proceed();
    expect(sidebar.followed).toHaveBeenCalledTimes(1);
    expect(editor.pushed).toHaveLength(1);
  });

  test('does not take leaving the field as saving it', () => {
    editor.type();
    editor.leave();
    sidebar.click();
    expect(sidebar.followed).not.toHaveBeenCalled();
  });

  test('lets links go once a save the server started itself is confirmed', () => {
    editor.type();
    editor.leave();
    editor.clean();
    sidebar.click();
    expect(sidebar.followed).toHaveBeenCalledTimes(1);
    expect(unloadIsBlocked()).toBe(false);
  });

  test('keeps holding links when more was typed after the field was left', () => {
    editor.type();
    editor.leave();
    editor.type();
    editor.clean();
    sidebar.click();
    expect(sidebar.followed).not.toHaveBeenCalled();
  });

  test('lets links go once a submitted save is confirmed', () => {
    editor.type();
    editor.submit();
    editor.clean();
    sidebar.click();
    expect(sidebar.followed).toHaveBeenCalledTimes(1);
  });

  test('lets a link opened in a new tab go', () => {
    editor.type();
    sidebar.click({ ctrlKey: true });
    expect(sidebar.followed).toHaveBeenCalledTimes(1);
  });

  test('lets a link inside the editor go', () => {
    editor.type();
    const inner = document.createElement('a');
    inner.dataset.phxLink = 'patch';
    editor.form.appendChild(inner);
    inner.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
    expect(sidebar.followed).toHaveBeenCalledTimes(1);
  });

  test('a second dirty editor leaves the held link to the first', () => {
    const other = mount('poll-editor-2', { leaveEvent: 'leave' });
    editor.type();
    other.type();
    sidebar.click();
    expect(editor.pushed.length + other.pushed.length).toBe(1);
    other.hook.destroyed();
  });

  test('stops holding links once the editor is gone', () => {
    editor.type();
    editor.hook.destroyed();
    sidebar.click();
    expect(sidebar.followed).toHaveBeenCalledTimes(1);
  });
});

describe('UnsavedChanges on an autosaving form', () => {
  test('never holds a link, since following one saves the field first', () => {
    const form = mount();
    const sidebar = sidebarLink();
    form.type();
    sidebar.click();
    expect(sidebar.followed).toHaveBeenCalledTimes(1);
    form.hook.destroyed();
    sidebar.remove();
    document.body.innerHTML = '';
  });
});
